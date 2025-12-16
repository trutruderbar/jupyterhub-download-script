import json
import os
import re
import shlex
import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles


ROOT_DIR = Path(__file__).resolve().parent.parent
FRONTEND_DIR = ROOT_DIR / "frontend"


def normalize_base_url(value: Optional[str]) -> str:
    if not value:
        return ""
    return str(value).strip().rstrip("/")


SERVICE_PREFIX = normalize_base_url(
    os.environ.get("USER_LOGS_MONITOR_ROOT_PATH") or os.environ.get("JUPYTERHUB_SERVICE_PREFIX")
)
if SERVICE_PREFIX and not SERVICE_PREFIX.startswith("/"):
    SERVICE_PREFIX = "/" + SERVICE_PREFIX
BASE_PATH = SERVICE_PREFIX if SERVICE_PREFIX.endswith("/") else (SERVICE_PREFIX + "/" if SERVICE_PREFIX else "")
APP_ROOT = (SERVICE_PREFIX or "") + "/app"

KUBECTL_BIN = shlex.split(os.environ.get("KUBECTL_BIN", "microk8s kubectl"))
JHUB_NAMESPACE = os.environ.get("JHUB_NAMESPACE", "jhub")

USERNAME_SANITIZE_RE = re.compile(r"[^a-z0-9]+")
USERNAME_LABEL_KEYS = (
    "hub.jupyter.org/username",
    "hub.jupyter.org/escaped-username",
    "hub.jupyter.org/user",
)

LOG_STORE_DIR = Path(os.environ.get("USER_LOGS_STORE_DIR", "/tmp/user_logs_monitor"))
LOG_RETENTION_SECONDS = int(os.environ.get("USER_LOGS_RETENTION_SECONDS", str(3 * 24 * 3600)))


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


def _run_kubectl_text(args: List[str]) -> str:
    cmd = KUBECTL_BIN + args
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = proc.communicate()
    if proc.returncode != 0:
        msg = (err or out or "kubectl failed").strip()
        raise RuntimeError(msg)
    return out


def _run_kubectl_json(args: List[str]) -> dict:
    return json.loads(_run_kubectl_text(args))


def list_user_pods(account: str) -> List[dict]:
    owner_key = normalize_username(account)
    raw = _run_kubectl_json(
        ["get", "pods", "-n", JHUB_NAMESPACE, "-l", "component=singleuser-server", "-o", "json"]
    )
    pods: List[dict] = []
    for item in raw.get("items", []):
        metadata = item.get("metadata") or {}
        status = item.get("status") or {}
        spec = item.get("spec") or {}
        pod_name = metadata.get("name") or ""
        user_key, display_user = _extract_username(metadata, pod_name)
        if user_key != owner_key:
            continue
        labels = metadata.get("labels") or {}
        cs_list = status.get("containerStatuses") or []
        containers = []
        for cs in cs_list:
            state = cs.get("state") or {}
            last_state = cs.get("lastState") or {}
            containers.append(
                {
                    "name": cs.get("name"),
                    "ready": bool(cs.get("ready")),
                    "restartCount": int(cs.get("restartCount") or 0),
                    "state": state,
                    "lastState": last_state,
                    "image": cs.get("image"),
                    "imageID": cs.get("imageID"),
                    "containerID": cs.get("containerID"),
                }
            )
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
                "reason": status.get("reason"),
                "message": status.get("message"),
                "node": spec.get("nodeName") or status.get("nodeName"),
                "ip": status.get("podIP"),
                "startTime": start_time_raw,
                "ageSeconds": age_seconds,
                "containers": containers,
            }
        )
    return pods


def _user_from_jupyterhub_headers(request: Request) -> Optional[str]:
    for header in ("x-jupyterhub-user", "x-forwarded-user", "x-remote-user", "x-auth-request-user"):
        value = request.headers.get(header)
        if value:
            return value.strip()
    q_user = request.query_params.get("user") or request.query_params.get("username")
    if q_user:
        return q_user.strip()
    return None


async def require_user(request: Request) -> str:
    user = _user_from_jupyterhub_headers(request)
    if not user:
        raise HTTPException(status_code=401, detail="Missing user")
    return user


def _purge_old_files():
    try:
        LOG_STORE_DIR.mkdir(parents=True, exist_ok=True)
        now = datetime.now(timezone.utc).timestamp()
        for p in LOG_STORE_DIR.glob("*.log"):
            try:
                if now - p.stat().st_mtime > LOG_RETENTION_SECONDS:
                    p.unlink(missing_ok=True)
            except Exception:
                continue
    except Exception:
        pass


def _start_purger():
    def loop():
        while True:
            _purge_old_files()
            # purge hourly
            threading.Event().wait(3600)

    t = threading.Thread(target=loop, daemon=True)
    t.start()


app = FastAPI(title="User Logs Monitor", version="0.1.0")

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

_start_purger()


@app.get("/api/me")
async def me(user: str = Depends(require_user)):
    return {"account": user}


@app.get("/api/pods")
async def pods(user: str = Depends(require_user)):
    return {"items": list_user_pods(user)}


@app.get("/api/logs")
async def logs(
    pod: str = Query(..., min_length=1),
    container: Optional[str] = Query(default=None),
    tail: int = Query(default=200, ge=1, le=5000),
    user: str = Depends(require_user),
):
    pods = {p["name"]: p for p in list_user_pods(user)}
    if pod not in pods:
        raise HTTPException(status_code=404, detail="Pod not found for this user")
    args = ["logs", pod, "-n", JHUB_NAMESPACE, f"--tail={tail}"]
    if container:
        args += ["-c", container]
    try:
        text = _run_kubectl_text(args)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc))

    try:
        LOG_STORE_DIR.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
        ctag = (container or "default").replace("/", "_")
        fname = f"{pod}__{ctag}__{ts}.log"
        (LOG_STORE_DIR / fname).write_text(text, encoding="utf-8")
    except Exception:
        pass

    return {"pod": pod, "container": container, "text": text}


# Static assets must be mounted before the catch-all SPA route.
app.mount("/app/static", StaticFiles(directory=str(FRONTEND_DIR)), name="static")


@app.get("/app/")
@app.get("/app/{rest:path}")
async def spa(rest: str = ""):
    index = FRONTEND_DIR / "index.html"
    if not index.exists():
        raise HTTPException(status_code=404, detail="Frontend not found")
    return FileResponse(index)
