import json
import os
import re
import shlex
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
import httpx


ROOT_DIR = Path(__file__).resolve().parent.parent
FRONTEND_DIR = ROOT_DIR / "frontend"

# Reuse Usage Portal's pod collection (adds GPU usage via nvidia-smi).
try:
    from usage_monitoring.backend.app import jhub as usage_jhub  # type: ignore
except Exception:
    usage_jhub = None  # type: ignore


def _load_resource_formats() -> List[dict]:
    """Load resource formats from env.

    Expected JSON: [{"slug":"cpu-node","gpu":0,"label":"CPU Node"}, ...]
    Only gpu/slug are required for matching.
    """
    raw = os.environ.get("USER_RESOURCE_MONITOR_FORMATS_JSON") or os.environ.get("RESOURCE_FORMATS_JSON")
    if raw:
        try:
            data = json.loads(raw)
            if isinstance(data, list):
                cleaned = []
                for item in data:
                    if not isinstance(item, dict):
                        continue
                    slug = str(item.get("slug") or item.get("display_name") or "").strip()
                    gpu = item.get("gpu")
                    if slug and gpu is not None:
                        try:
                            gpu_val = int(float(gpu))
                        except Exception:
                            continue
                        cleaned.append({**item, "slug": slug, "gpu": gpu_val})
                if cleaned:
                    return cleaned
        except Exception:
            pass
    # Default formats match current profileList generator (lib/70-profiles.sh).
    return [
        {"slug": "cpu-node", "gpu": 0, "label": "CPU Node"},
        {"slug": "h100-1v", "gpu": 1, "label": "H100 1 GPU"},
        {"slug": "h100-2v", "gpu": 2, "label": "H100 2 GPUs"},
        {"slug": "h100-4v", "gpu": 4, "label": "H100 4 GPUs"},
        {"slug": "h100-8v", "gpu": 8, "label": "H100 8 GPUs"},
    ]


_RESOURCE_FORMATS = _load_resource_formats()
_RESOURCE_FORMATS_BY_GPU = {int(f.get("gpu", 0)): f for f in _RESOURCE_FORMATS if isinstance(f.get("gpu"), int)}


def _infer_resource_format(pod: dict) -> dict:
    req = pod.get("requests") or {}
    lim = pod.get("limits") or {}
    gpu_count = lim.get("gpuCount") or req.get("gpuCount") or 0
    try:
        gpu_count = int(float(gpu_count or 0) or 0)
    except Exception:
        gpu_count = 0
    fmt = _RESOURCE_FORMATS_BY_GPU.get(gpu_count)
    if fmt:
        slug = fmt.get("slug")
        label = fmt.get("label") or slug
    else:
        slug = "cpu-node" if gpu_count <= 0 else f"gpu-{gpu_count}"
        label = slug
    cpu_lim = lim.get("cpuMillicores") or req.get("cpuMillicores")
    mem_lim = lim.get("memoryMiB") or req.get("memoryMiB")
    try:
        cpu_cores = float(cpu_lim) / 1000.0 if cpu_lim is not None else None
    except Exception:
        cpu_cores = None
    try:
        mem_gib = float(mem_lim) / 1024.0 if mem_lim is not None else None
    except Exception:
        mem_gib = None
    return {
        "slug": slug,
        "label": label,
        "gpu": gpu_count,
        "cpuCores": cpu_cores,
        "memoryGiB": mem_gib,
    }


def normalize_base_url(value: Optional[str]) -> str:
    if not value:
        return ""
    return str(value).strip().rstrip("/")


SERVICE_PREFIX = normalize_base_url(
    os.environ.get("USER_RESOURCE_MONITOR_ROOT_PATH") or os.environ.get("JUPYTERHUB_SERVICE_PREFIX")
)
if SERVICE_PREFIX and not SERVICE_PREFIX.startswith("/"):
    SERVICE_PREFIX = "/" + SERVICE_PREFIX
BASE_PATH = SERVICE_PREFIX if SERVICE_PREFIX.endswith("/") else (SERVICE_PREFIX + "/" if SERVICE_PREFIX else "")
APP_ROOT = (SERVICE_PREFIX or "") + "/app"

_disable_auth_raw = os.environ.get("USER_RESOURCE_MONITOR_DISABLE_AUTH")
# Default to disable auth when running as a JupyterHub service.
if _disable_auth_raw is None:
    DISABLE_AUTH = bool(SERVICE_PREFIX)
else:
    DISABLE_AUTH = _disable_auth_raw.lower() == "true"

KUBECTL_BIN = shlex.split(os.environ.get("KUBECTL_BIN", "microk8s kubectl"))
JHUB_NAMESPACE = os.environ.get("JHUB_NAMESPACE", "jhub")
USAGE_PORTAL_URL = os.environ.get("USAGE_PORTAL_URL", "")
USAGE_PORTAL_TIMEOUT = float(os.environ.get("USAGE_PORTAL_TIMEOUT", "5.0"))
HUB_API_URL = os.environ.get("USER_RESOURCE_MONITOR_HUB_API_URL") or os.environ.get("JUPYTERHUB_API_URL")

USERNAME_SANITIZE_RE = re.compile(r"[^a-z0-9]+")
USERNAME_LABEL_KEYS = (
    "hub.jupyter.org/username",
    "hub.jupyter.org/escaped-username",
    "hub.jupyter.org/user",
)


def normalize_username(value: str) -> str:
    cleaned = USERNAME_SANITIZE_RE.sub("-", (value or "").lower()).strip("-")
    return cleaned or (value or "").lower()


def _extract_username(metadata: Dict[str, dict], pod_name: str) -> Tuple[str, str]:
    labels = metadata.get("labels") or {}
    annotations = metadata.get("annotations") or {}
    for source in (annotations, labels):
        for key in USERNAME_LABEL_KEYS:
            value = source.get(key)
            if value:
                return normalize_username(value), value
    if pod_name and pod_name.startswith("jupyter-"):
        remainder = pod_name[len("jupyter-") :]
        if remainder.startswith("-"):
            remainder = remainder[1:]
        if "---" in remainder:
            remainder = remainder.split("---", 1)[0]
        cleaned = remainder.replace("--", "-").strip("-")
        if cleaned:
            return normalize_username(cleaned), cleaned
    return "(unknown)", "(unknown)"


def parse_cpu_to_millicores(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    value = str(value).strip()
    if value.endswith("m"):
        try:
            return float(value[:-1])
        except ValueError:
            return None
    try:
        return float(value) * 1000.0
    except ValueError:
        return None


_MEM_SUFFIX = {
    "Ki": 1.0 / 1024,
    "Mi": 1.0,
    "Gi": 1024.0,
    "Ti": 1024.0 * 1024,
    "Pi": 1024.0 * 1024 * 1024,
    "Ei": 1024.0 * 1024 * 1024 * 1024,
    "K": 1.0 / 1024,
    "M": 1.0,
    "G": 1024.0,
    "T": 1024.0 * 1024,
}


def parse_mem_to_mebibytes(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    value = str(value).strip()
    for suffix, ratio in _MEM_SUFFIX.items():
        if value.endswith(suffix):
            try:
                return float(value[: -len(suffix)]) * ratio
            except ValueError:
                return None
    try:
        return float(value) / (1024.0 * 1024.0)
    except ValueError:
        return None


def _collect_cluster_capacity() -> Dict[str, float]:
    """Return allocatable cluster totals for JupyterHub namespace.

    Values are derived from node allocatable resources, not live usage.
    """
    try:
        raw = _run_kubectl(["get", "nodes", "-o", "json"])
    except Exception:
        return {}
    total_cpu = 0.0
    total_mem = 0.0
    total_gpu = 0.0
    for item in raw.get("items", []):
        status = item.get("status") or {}
        alloc = status.get("allocatable") or status.get("capacity") or {}
        total_cpu += parse_cpu_to_millicores(alloc.get("cpu")) or 0.0
        total_mem += parse_mem_to_mebibytes(alloc.get("memory")) or 0.0
        gpu_raw = alloc.get("nvidia.com/gpu") or 0
        try:
            total_gpu += float(gpu_raw)
        except Exception:
            continue
    return {"cpuMillicores": total_cpu, "memoryMiB": total_mem, "gpu": total_gpu}


async def _fetch_user_quota(username: str) -> Optional[Dict[str, float]]:
    """Fetch user quota limits from Usage Portal.

    Returns dict with cpuMillicores, memoryMiB, gpu keys, or None if unavailable.
    """
    if not USAGE_PORTAL_URL:
        return None

    canonical = normalize_username(username)
    if not canonical:
        return None

    url = f"{USAGE_PORTAL_URL.rstrip('/')}/users/{canonical}/limits"

    try:
        async with httpx.AsyncClient(timeout=USAGE_PORTAL_TIMEOUT) as client:
            response = await client.get(url)
            if response.status_code != 200:
                return None

            data = response.json()
            cpu_limit = data.get("cpu_limit_cores", 0)
            mem_limit = data.get("memory_limit_gib", 0)
            gpu_limit = data.get("gpu_limit", 0)

            return {
                "cpuMillicores": float(cpu_limit) * 1000.0,  # cores to millicores
                "memoryMiB": float(mem_limit) * 1024.0,       # GiB to MiB
                "gpu": float(gpu_limit),
            }
    except Exception:
        return None


def _run_kubectl(args: List[str]) -> dict:
    cmd = KUBECTL_BIN + args
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = proc.communicate()
    if proc.returncode != 0:
        msg = (err or out or "kubectl failed").strip()
        raise RuntimeError(msg)
    return json.loads(out)


def _fetch_pod_metrics() -> Tuple[bool, Dict[str, Dict[str, Optional[float]]]]:
    args = [
        "top",
        "pod",
        "-n",
        JHUB_NAMESPACE,
        "-l",
        "component=singleuser-server",
        "--no-headers",
    ]
    cmd = KUBECTL_BIN + args
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = proc.communicate()
    if proc.returncode != 0:
        return False, {}
    metrics: Dict[str, Dict[str, Optional[float]]] = {}
    for line in out.strip().splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        pod_name, cpu_raw, mem_raw = parts[:3]
        metrics[pod_name] = {
            "cpuRaw": cpu_raw,
            "memRaw": mem_raw,
            "cpuMillicores": parse_cpu_to_millicores(cpu_raw),
            "memoryMiB": parse_mem_to_mebibytes(mem_raw),
        }
    return True, metrics


def list_user_pods(account: str) -> Tuple[List[dict], bool]:
    owner_key = normalize_username(account)
    # Preferred path: use Usage Portal collector to get GPU usage too.
    if usage_jhub is not None:
        try:
            payload = usage_jhub.collect_usage_payload()
            metrics_available = bool(payload.get("metricsAvailable"))
            raw_pods = payload.get("pods") or []

            def to_int(value) -> int:
                try:
                    return int(float(value or 0) or 0)
                except Exception:
                    return 0

            pods: List[dict] = []
            for pod in raw_pods:
                user_key = normalize_username(pod.get("user") or pod.get("displayUser") or "")
                if user_key != owner_key:
                    continue
                req = pod.get("requests") or {}
                lim = pod.get("limits") or {}
                usage = pod.get("usage") or {}
                pods.append(
                    {
                        "name": pod.get("podName") or pod.get("name") or "",
                        "displayUser": pod.get("displayUser") or pod.get("user") or "",
                        "serverName": pod.get("serverName") or "",
                        "phase": pod.get("phase"),
                        "node": pod.get("node"),
                        "ip": pod.get("ip"),
                        "startTime": pod.get("startTime"),
                        "ageSeconds": pod.get("ageSeconds"),
                        "image": pod.get("image"),
                        "requests": {
                            "cpu": req.get("cpu"),
                            "memory": req.get("memory"),
                            "gpu": req.get("gpu"),
                            "cpuMillicores": req.get("cpuMillicores") or parse_cpu_to_millicores(req.get("cpu")),
                            "memoryMiB": req.get("memoryMiB") or parse_mem_to_mebibytes(req.get("memory")),
                            "gpuCount": to_int(req.get("gpu")),
                        },
                        "limits": {
                            "cpu": lim.get("cpu"),
                            "memory": lim.get("memory"),
                            "gpu": lim.get("gpu"),
                            "cpuMillicores": lim.get("cpuMillicores") or parse_cpu_to_millicores(lim.get("cpu")),
                            "memoryMiB": lim.get("memoryMiB") or parse_mem_to_mebibytes(lim.get("memory")),
                            "gpuCount": to_int(lim.get("gpu")),
                        },
                        "usage": {
                            "cpu": usage.get("cpu"),
                            "memory": usage.get("memory"),
                            "cpuMillicores": usage.get("cpuMillicores"),
                            "memoryMiB": usage.get("memoryMiB"),
                        },
                        "gpuUsage": pod.get("gpuUsage") or {},
                    }
                )
            for p in pods:
                p["resourceFormat"] = _infer_resource_format(p)
            return pods, metrics_available
        except Exception:
            # Fall back to direct kubectl parsing if Usage Portal code fails.
            pass

    raw = _run_kubectl(
        ["get", "pods", "-n", JHUB_NAMESPACE, "-l", "component=singleuser-server", "-o", "json"]
    )
    metrics_available, metrics_map = _fetch_pod_metrics()
    pods: List[dict] = []
    for item in raw.get("items", []):
        metadata = item.get("metadata") or {}
        status = item.get("status") or {}
        spec = item.get("spec") or {}
        pod_name = metadata.get("name") or ""
        user_key, display_user = _extract_username(metadata, pod_name)
        if user_key != owner_key:
            continue
        containers = spec.get("containers") or []
        container = containers[0] if containers else {}
        resources = container.get("resources") or {}
        requests = resources.get("requests") or {}
        limits = resources.get("limits") or {}
        labels = metadata.get("labels") or {}
        metrics_entry = metrics_map.get(pod_name, {})
        start_time_raw = status.get("startTime")
        age_seconds = None
        if start_time_raw:
            try:
                start_dt = datetime.fromisoformat(start_time_raw.replace("Z", "+00:00"))
                age_seconds = (datetime.now(timezone.utc) - start_dt).total_seconds()
            except Exception:
                age_seconds = None
        pods.append(
            {
                "name": pod_name,
                "displayUser": display_user,
                "serverName": labels.get("hub.jupyter.org/servername", ""),
                "phase": status.get("phase"),
                "node": spec.get("nodeName") or status.get("nodeName"),
                "ip": status.get("podIP"),
                "startTime": start_time_raw,
                "ageSeconds": age_seconds,
                "image": container.get("image"),
                "requests": {
                    "cpu": requests.get("cpu"),
                    "memory": requests.get("memory"),
                    "gpu": requests.get("nvidia.com/gpu"),
                    "cpuMillicores": parse_cpu_to_millicores(requests.get("cpu")),
                    "memoryMiB": parse_mem_to_mebibytes(requests.get("memory")),
                    "gpuCount": int(float(requests.get("nvidia.com/gpu") or 0) or 0),
                },
                "limits": {
                    "cpu": limits.get("cpu"),
                    "memory": limits.get("memory"),
                    "gpu": limits.get("nvidia.com/gpu"),
                    "cpuMillicores": parse_cpu_to_millicores(limits.get("cpu")),
                    "memoryMiB": parse_mem_to_mebibytes(limits.get("memory")),
                    "gpuCount": int(float(limits.get("nvidia.com/gpu") or 0) or 0),
                },
                "usage": {
                    "cpu": metrics_entry.get("cpuRaw"),
                    "memory": metrics_entry.get("memRaw"),
                    "cpuMillicores": metrics_entry.get("cpuMillicores"),
                    "memoryMiB": metrics_entry.get("memoryMiB"),
                },
            }
        )
    for p in pods:
        p["resourceFormat"] = _infer_resource_format(p)
    return pods, metrics_available


def _user_from_jupyterhub_headers(request: Request) -> Optional[str]:
    for header in ("x-jupyterhub-user", "x-forwarded-user", "x-remote-user", "x-auth-request-user"):
        value = request.headers.get(header)
        if value:
            return value.strip()
    return None


async def _user_from_jupyterhub_token(request: Request) -> Optional[str]:
    if not HUB_API_URL:
        return None
    authz = request.headers.get("authorization") or ""
    if not authz.lower().startswith("bearer ") and not authz.lower().startswith("token "):
        return None
    token = authz.split(None, 1)[1].strip()
    if not token:
        return None
    base_api = HUB_API_URL.rstrip("/")
    if not base_api:
        base_api = f"{request.url.scheme}://{request.url.netloc}/hub/api"
    url = f"{base_api}/user"
    try:
        async with httpx.AsyncClient(timeout=5.0, verify=False) as client:
            resp = await client.get(url, headers={"Authorization": f"Bearer {token}"})
    except Exception:
        return None
    if resp.status_code != 200:
        return None
    try:
        data = resp.json()
    except Exception:
        return None
    username = data.get("name") or data.get("username")
    return username or None


async def require_user(request: Request) -> str:
    user = _user_from_jupyterhub_headers(request) or await _user_from_jupyterhub_token(request)
    if not user:
        # Even when auth is disabled, we still need to know which user to filter pods for.
        raise HTTPException(status_code=401, detail="Missing user")
    return user


app = FastAPI(title="User Resource Monitor", version="0.1.0")

if SERVICE_PREFIX:
    @app.middleware("http")
    async def strip_service_prefix(request: Request, call_next):
        path = request.scope.get("path", "") or ""
        prefix = BASE_PATH.rstrip("/") or SERVICE_PREFIX
        if prefix and path.startswith(prefix):
            request.scope["root_path"] = prefix
            stripped = path[len(prefix) :] or "/"
            if not stripped.startswith("/"):
                stripped = "/" + stripped
            request.scope["path"] = stripped
        return await call_next(request)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/me")
async def me(user: str = Depends(require_user)):
    return {"account": user}


@app.get("/api/resources")
async def resources(user: str = Depends(require_user)):
    pods, metrics_available = list_user_pods(user)
    total_usage_cpu = sum((p["usage"]["cpuMillicores"] or 0.0) for p in pods)
    total_usage_mem = sum((p["usage"]["memoryMiB"] or 0.0) for p in pods)
    total_req_cpu = sum((p["requests"]["cpuMillicores"] or 0.0) for p in pods)
    total_req_mem = sum((p["requests"]["memoryMiB"] or 0.0) for p in pods)
    total_lim_cpu = sum((p["limits"]["cpuMillicores"] or p["requests"]["cpuMillicores"] or 0.0) for p in pods)
    total_lim_mem = sum((p["limits"]["memoryMiB"] or p["requests"]["memoryMiB"] or 0.0) for p in pods)
    total_req_gpu = sum((p["requests"]["gpuCount"] or 0) for p in pods)
    total_lim_gpu = sum((p["limits"]["gpuCount"] or p["requests"]["gpuCount"] or 0) for p in pods)

    # Try to get user quota from Usage Portal first, fallback to cluster capacity
    user_quota = await _fetch_user_quota(user)
    cluster_capacity = user_quota if user_quota else _collect_cluster_capacity()

    formats_summary: Dict[str, dict] = {}
    for pod in pods:
        fmt = pod.get("resourceFormat") or {}
        slug = fmt.get("slug") or "unknown"
        entry = formats_summary.setdefault(
            slug,
            {
                "slug": slug,
                "label": fmt.get("label") or slug,
                "count": 0,
                "gpu": 0,
                "cpuCores": 0.0,
                "memoryGiB": 0.0,
            },
        )
        entry["count"] += 1
        entry["gpu"] += int(fmt.get("gpu") or 0)
        entry["cpuCores"] += float(fmt.get("cpuCores") or 0.0)
        entry["memoryGiB"] += float(fmt.get("memoryGiB") or 0.0)

    return {
        "user": user,
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        "metricsAvailable": metrics_available,
        "usage": {"cpuMillicores": total_usage_cpu, "memoryMiB": total_usage_mem},
        "requests": {"cpuMillicores": total_req_cpu, "memoryMiB": total_req_mem, "gpu": total_req_gpu},
        "limits": {"cpuMillicores": total_lim_cpu, "memoryMiB": total_lim_mem, "gpu": total_lim_gpu},
        "clusterCapacity": cluster_capacity,
        "formats": list(formats_summary.values()),
        "pods": pods,
    }


# Static assets must be mounted before the catch-all SPA route.
app.mount("/app/static", StaticFiles(directory=str(FRONTEND_DIR)), name="static")


# SPA routes
@app.get("/app/")
@app.get("/app/{rest:path}")
async def spa(rest: str = ""):
    index = FRONTEND_DIR / "index.html"
    if not index.exists():
        raise HTTPException(status_code=404, detail="Frontend not found")
    return FileResponse(index)
