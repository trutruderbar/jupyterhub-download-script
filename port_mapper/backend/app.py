import json
import os
import re
import shlex
import subprocess
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.routing import APIRouter
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .utils import normalize_base_url

# === Paths & basic config ===
ROOT_DIR = Path(__file__).resolve().parent.parent
FRONTEND_DIR = ROOT_DIR / "frontend"
DEFAULT_DATA_DIR = ROOT_DIR / "data"
DEFAULT_STATE_FILE = DEFAULT_DATA_DIR / "mappings.json"


def _is_writable_dir(path: Path) -> bool:
    try:
        path.mkdir(parents=True, exist_ok=True)
    except Exception:
        return False
    return os.access(str(path), os.W_OK)


def _select_state_file() -> Path:
    env_file = os.environ.get("PORT_MAPPER_STATE_FILE")
    env_dir = os.environ.get("PORT_MAPPER_DATA_DIR")
    if env_file:
        candidate = Path(env_file).expanduser()
    elif env_dir:
        candidate = Path(env_dir).expanduser() / "mappings.json"
    else:
        candidate = DEFAULT_STATE_FILE

    # If candidate is writable (existing file or parent dir), use it.
    if candidate.exists():
        if os.access(str(candidate), os.W_OK):
            return candidate
    else:
        if _is_writable_dir(candidate.parent):
            return candidate

    # Fallback to a writable location
    tmp_root = Path(os.environ.get("TMPDIR", "/tmp")).expanduser()
    for alt_dir in (tmp_root / "port_mapper", Path.home() / ".port_mapper"):
        if _is_writable_dir(alt_dir):
            return alt_dir / "mappings.json"

    return candidate


STATE_FILE = _select_state_file()
DATA_DIR = STATE_FILE.parent

# Honor JupyterHub service prefix when proxied via /services/<name>/...
SERVICE_PREFIX = normalize_base_url(
    os.environ.get("PORT_MAPPER_ROOT_PATH") or os.environ.get("JUPYTERHUB_SERVICE_PREFIX")
)
if SERVICE_PREFIX and not SERVICE_PREFIX.startswith("/"):
    SERVICE_PREFIX = "/" + SERVICE_PREFIX
BASE_PATH = SERVICE_PREFIX if SERVICE_PREFIX.endswith("/") else (SERVICE_PREFIX + "/" if SERVICE_PREFIX else "")
APP_ROOT = (SERVICE_PREFIX or "") + "/app"

# Defaults can be overridden by env
AUTH_URL = os.environ.get("PORT_MAPPER_AUTH_URL", "http://10.2.240.1:8000/command")
AUTH_ME_URL = (
    os.environ.get("PORT_MAPPER_AUTH_ME_URL")
    or os.environ.get("UBILINK_AUTH_ME_URL")
    or "https://billing.ubilink.ai/api/auth/me"
)
KUBECTL_BIN = shlex.split(os.environ.get("KUBECTL_BIN", "microk8s kubectl"))
JHUB_NAMESPACE = os.environ.get("JHUB_NAMESPACE", "jhub")
PROXY_TIMEOUT = float(os.environ.get("PORT_MAPPER_PROXY_TIMEOUT", "30"))
PUBLIC_BASE_URL = normalize_base_url(
    os.environ.get("PORT_MAPPER_PUBLIC_BASE_URL") or SERVICE_PREFIX
)
HUB_API_URL = os.environ.get("PORT_MAPPER_HUB_API_URL") or os.environ.get("JUPYTERHUB_API_URL")
_disable_auth_raw = os.environ.get("PORT_MAPPER_DISABLE_AUTH")
# Default to disable auth when running as a JupyterHub service.
if _disable_auth_raw is None:
    DISABLE_AUTH = bool(SERVICE_PREFIX)
else:
    DISABLE_AUTH = _disable_auth_raw.lower() == "true"
TRUST_JHUB_HEADERS = os.environ.get("PORT_MAPPER_TRUST_JHUB_HEADERS", "true").lower() == "true"
JUPYTERHUB_USER_HEADERS = [
    h.strip()
    for h in os.environ.get(
        "PORT_MAPPER_JHUB_USER_HEADERS",
        "x-jupyterhub-user,x-forwarded-user,x-remote-user,x-auth-request-user",
    ).split(",")
    if h.strip()
]

# Keep lowercase for comparisons
HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length",
}

# username helpers (align with usage_monitoring/jhub.py)
USERNAME_SANITIZE_RE = re.compile(r"[^a-z0-9]+")
USERNAME_LABEL_KEYS = (
    "hub.jupyter.org/username",
    "hub.jupyter.org/escaped-username",
    "hub.jupyter.org/user",
)
POD_SUFFIX_RE = re.compile(r"([0-9a-f]{8})$")
POD_HEX_TOKEN_RE = re.compile(r"[0-9a-f]{8}")


def normalize_username(value: str) -> str:
    cleaned = USERNAME_SANITIZE_RE.sub("-", (value or "").lower()).strip("-")
    return cleaned or (value or "").lower()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _normalize_endpoint(path: str) -> str:
    path = (path or "").strip()
    if not path.startswith("/"):
        path = "/" + path
    # Collapse duplicate slashes and trim trailing slash (except root)
    parts = [p for p in path.split("/") if p != ""]
    normalized = "/" + "/".join(parts)
    if normalized != "/" and normalized.endswith("/"):
        normalized = normalized.rstrip("/")
    return normalized or "/"


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


def _pod_suffix(name: str) -> str:
    m = POD_SUFFIX_RE.search(name or "")
    if m:
        return m.group(1)
    return (name or "")[-8:]


def _container_id_prefix(status: dict) -> Optional[str]:
    """從 pod 的 containerID 取前 8 碼 hex（你說的 pod id 前 8 碼）。"""
    if not status:
        return None
    statuses = status.get("containerStatuses") or []
    preferred = []
    for c in statuses:
        cname = (c.get("name") or "").lower()
        if cname in ("notebook", "singleuser", "jupyterhub-singleuser"):
            preferred.append(c)
    for group in (preferred, statuses):
        for c in group:
            cid = (c.get("containerID") or "").strip()
            if not cid:
                continue
            raw = cid.split("://", 1)[1] if "://" in cid else cid
            raw = raw.strip().lower()
            m = re.match(r"[0-9a-f]+", raw)
            if not m:
                continue
            raw_hex = m.group(0)
            if len(raw_hex) >= 8:
                return raw_hex[:8]
    return None


def _pod_suffix_candidates(name: str, status: Optional[dict] = None) -> List[str]:
    """取得 pod 的 8 碼識別碼清單。

    優先使用 containerID（pod id）的前 8 碼作為主要 suffix，
    但仍保留舊的 pod name 8 碼 token 以相容既有 mapping。
    """
    name = name or ""
    candidates: List[str] = []

    pod_id_prefix = _container_id_prefix(status or {})
    if pod_id_prefix and pod_id_prefix not in candidates:
        candidates.append(pod_id_prefix)

    last8 = _pod_suffix(name)
    if last8 and last8 not in candidates:
        candidates.append(last8)
    for tok in POD_HEX_TOKEN_RE.findall(name):
        if tok not in candidates:
            candidates.append(tok)
    return candidates


class MappingRequest(BaseModel):
    pod_suffix: str = Field(..., min_length=4, max_length=64)
    endpoint: str = Field(..., min_length=1)
    port: int = Field(..., ge=1, le=65535)
    note: Optional[str] = Field(default=None, max_length=200)


def _extract_account(user_info: dict) -> str:
    return (
        user_info.get("account")
        or user_info.get("username")
        or user_info.get("user")
        or user_info.get("email")
        or ""
    )


def _user_from_jupyterhub_headers(request: Request) -> Optional[dict]:
    if not TRUST_JHUB_HEADERS:
        return None
    for header in JUPYTERHUB_USER_HEADERS:
        value = request.headers.get(header)
        if value:
            cleaned = value.strip()
            if cleaned:
                return {"account": cleaned, "username": cleaned, "source": "jupyterhub-header"}
    return None


async def _user_from_jupyterhub_token(request: Request) -> Optional[dict]:
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
    if not username:
        return None
    return {"account": username, "username": username, "source": "jupyterhub-oauth"}


state_lock = threading.Lock()


def _load_state() -> dict:
    if not STATE_FILE.exists():
        # If we fell back to a different writable location, try to seed from default file.
        if STATE_FILE != DEFAULT_STATE_FILE and DEFAULT_STATE_FILE.exists():
            try:
                with DEFAULT_STATE_FILE.open("r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict):
                    data.setdefault("entries", [])
                    DATA_DIR.mkdir(parents=True, exist_ok=True)
                    with STATE_FILE.open("w", encoding="utf-8") as out:
                        json.dump(data, out, ensure_ascii=False, indent=2)
                    return data
            except Exception:
                # If we can't seed (e.g., permissions), just continue with empty state.
                pass
        return {"version": 1, "entries": []}
    try:
        with STATE_FILE.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {"version": 1, "entries": []}
        data.setdefault("entries", [])
        return data
    except Exception:
        return {"version": 1, "entries": []}


def _save_state(data: dict) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    tmp.replace(STATE_FILE)


def _entries_for_user(account: str) -> List[dict]:
    state = _load_state()
    owner_key = normalize_username(account)
    entries = []
    for e in state.get("entries", []):
        if normalize_username(e.get("user", "")) == owner_key:
            # Backfill ownerKey for older records
            e.setdefault("ownerKey", owner_key)
            e["endpoint"] = _normalize_endpoint(e.get("endpoint", ""))
            entries.append(e)
    return entries


def upsert_mapping(account: str, pod_suffix: str, endpoint: str, port: int, note: Optional[str]) -> dict:
    owner_key = normalize_username(account)
    endpoint = _normalize_endpoint(endpoint)
    pod_suffix = pod_suffix.strip()
    now = _now_iso()
    with state_lock:
        state = _load_state()
        entries = state.setdefault("entries", [])
        found = None
        for e in entries:
            if (
                normalize_username(e.get("user", "")) == owner_key
                and e.get("podSuffix") == pod_suffix
                and _normalize_endpoint(e.get("endpoint", "")) == endpoint
            ):
                found = e
                break
        if found:
            found["port"] = int(port)
            found["note"] = note
            found["updatedAt"] = now
            entry = found
        else:
            entry = {
                "user": account,
                "ownerKey": owner_key,
                "podSuffix": pod_suffix,
                "endpoint": endpoint,
                "port": int(port),
                "note": note,
                "createdAt": now,
                "updatedAt": now,
            }
            entries.append(entry)
        _save_state(state)
        return entry


def delete_mapping(account: str, pod_suffix: str, endpoint: str) -> bool:
    owner_key = normalize_username(account)
    endpoint = _normalize_endpoint(endpoint)
    pod_suffix = pod_suffix.strip()
    changed = False
    with state_lock:
        state = _load_state()
        entries = state.get("entries", [])
        kept = []
        for e in entries:
            same_user = normalize_username(e.get("user", "")) == owner_key
            same_suffix = e.get("podSuffix") == pod_suffix
            same_endpoint = _normalize_endpoint(e.get("endpoint", "")) == endpoint
            if same_user and same_suffix and same_endpoint:
                changed = True
                continue
            kept.append(e)
        if changed:
            state["entries"] = kept
            _save_state(state)
    return changed


def list_entries_by_suffix(pod_suffix: str) -> List[dict]:
    state = _load_state()
    matches = []
    for e in state.get("entries", []):
        if str(e.get("podSuffix")) == str(pod_suffix):
            e.setdefault("ownerKey", normalize_username(e.get("user", "")))
            e.setdefault("endpoint", _normalize_endpoint(e.get("endpoint", "")))
            matches.append(e)
    return matches


def fetch_pods_raw() -> dict:
    cmd = KUBECTL_BIN + [
        "get",
        "pods",
        "-n",
        JHUB_NAMESPACE,
        "-l",
        "component=singleuser-server",
        "-o",
        "json",
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = proc.communicate()
    if proc.returncode != 0:
        msg = err.strip() or out.strip() or "kubectl command failed"
        raise RuntimeError(msg)
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"kubectl output decode failed: {exc}") from exc


def list_user_pods(account: str) -> List[dict]:
    owner_key = normalize_username(account)
    try:
        raw = fetch_pods_raw()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"無法取得 pods：{exc}")
    pods = []
    for item in raw.get("items", []):
        metadata = item.get("metadata") or {}
        status = item.get("status") or {}
        pod_name = metadata.get("name") or ""
        user_key, display_user = _extract_username(metadata, pod_name)
        if user_key != owner_key:
            continue
        labels = metadata.get("labels") or {}
        suffixes = _pod_suffix_candidates(pod_name, status)
        pods.append(
            {
                "name": pod_name,
                "displayUser": display_user,
                "suffix": suffixes[0] if suffixes else "",
                "suffixes": suffixes,
                "phase": status.get("phase"),
                "ip": status.get("podIP"),
                "node": status.get("nodeName"),
                "serverName": labels.get("hub.jupyter.org/servername", ""),
            }
        )
    return pods


def find_pod_for_user(account: str, pod_suffix: str) -> Optional[dict]:
    pods = list_user_pods(account)
    target = str(pod_suffix or "")
    for pod in pods:
        suffixes = pod.get("suffixes") or []
        if target in suffixes:
            return pod
    return None


async def fetch_user_from_cookie(request: Request) -> dict:
    header_user = _user_from_jupyterhub_headers(request)
    if header_user:
        return header_user

    token_user = await _user_from_jupyterhub_token(request)
    if token_user:
        return token_user

    cookie = request.headers.get("cookie") or ""
    if not cookie:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="未登入")
    try:
        async with httpx.AsyncClient(timeout=8.0, follow_redirects=False) as client:
            resp = await client.get(AUTH_ME_URL, headers={"Cookie": cookie})
    except Exception as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=f"驗證服務連線失敗：{exc}")
    try:
        data = resp.json()
    except Exception:
        data = {}
    if resp.status_code == 401:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="未授權，請先登入")
    if not resp.is_success or not isinstance(data, dict):
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"驗證服務失敗（HTTP {resp.status_code}）",
        )
    return data


async def require_user(request: Request) -> dict:
    if DISABLE_AUTH:
        user = _user_from_jupyterhub_headers(request) or {}
        if not user:
            q_user = request.query_params.get("user") or request.query_params.get("username") or ""
            if q_user:
                user = {"account": q_user, "username": q_user, "source": "query"}
        account = _extract_account(user)
        user["account"] = account
        return user

    user = await fetch_user_from_cookie(request)
    account = _extract_account(user)
    if not account:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="未授權：缺少使用者資訊")
    user["account"] = account
    return user


api = APIRouter(prefix="/api")


@api.get("/me")
async def me(user: dict = Depends(require_user)):
    return {"account": user.get("account"), "raw": user}


@api.get("/pods")
async def pods(user: dict = Depends(require_user)):
    return {"items": list_user_pods(user.get("account"))}


def _enrich_entry(entry: dict, pod_lookup: Dict[str, dict], base_url: str) -> dict:
    suffix = entry.get("podSuffix")
    endpoint = _normalize_endpoint(entry.get("endpoint", ""))
    pod_info = pod_lookup.get(suffix, {})
    enriched = {
        **entry,
        "endpoint": endpoint,
        "podName": pod_info.get("name"),
        "podIp": pod_info.get("ip"),
        "podPhase": pod_info.get("phase"),
        "serverName": pod_info.get("serverName"),
    }
    enriched["url"] = f"{base_url}/{suffix}{endpoint}"
    return enriched


@api.get("/mappings")
async def mappings(request: Request, user: dict = Depends(require_user)):
    pods = list_user_pods(user.get("account"))
    pod_lookup = {p["suffix"]: p for p in pods}
    base = PUBLIC_BASE_URL or str(request.base_url).rstrip("/")
    entries = [_enrich_entry(e, pod_lookup, base) for e in _entries_for_user(user.get("account"))]
    return {"items": entries, "pods": pods}


@api.post("/mappings")
async def add_mapping(body: MappingRequest, request: Request, user: dict = Depends(require_user)):
    pod = find_pod_for_user(user.get("account"), body.pod_suffix)
    if not pod:
        raise HTTPException(status_code=404, detail="找不到指定的 pod 或不屬於此帳號")
    entry = upsert_mapping(user.get("account"), body.pod_suffix, body.endpoint, body.port, body.note)
    base = PUBLIC_BASE_URL or str(request.base_url).rstrip("/")
    return _enrich_entry(entry, {pod["suffix"]: pod}, base)


@api.delete("/mappings/{pod_suffix}/{endpoint:path}")
async def remove_mapping(pod_suffix: str, endpoint: str, user: dict = Depends(require_user)):
    ok = delete_mapping(user.get("account"), pod_suffix, endpoint)
    if not ok:
        raise HTTPException(status_code=404, detail="沒有找到對應的 mapping")
    return {"ok": True}


app = FastAPI(title="Port Mapper", version="0.1.0")

# When proxied by JupyterHub at /services/<name>, set root_path so Starlette
# strips the prefix for routing and static file mounts.
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
# Allow same-origin + simple cross origin access (e.g. preview via port-forward)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(api)


# === Static pages ===
if FRONTEND_DIR.exists():
    # Allow relative asset paths when served behind a prefix (/services/.../app/static)
    app.mount("/app/static", StaticFiles(directory=str(ROOT_DIR), html=False), name="app-static")

# Expose logo and other assets already under port_mapper/
app.mount("/static", StaticFiles(directory=str(ROOT_DIR), html=False), name="static")


@app.get("/")
async def root():
    if FRONTEND_DIR.exists():
        return RedirectResponse(url=f"{APP_ROOT}/")
    return {"ok": True, "message": "Port Mapper backend ready"}


@app.get("/app")
async def app_entry():
    return RedirectResponse(url=f"{APP_ROOT}/")

@app.get("/app/{rest:path}")
async def app_spa(rest: str = ""):
    index_file = FRONTEND_DIR / "index.html"
    if index_file.exists():
        return FileResponse(index_file)
    raise HTTPException(status_code=404, detail="frontend missing")


# === Reverse proxy for mapped endpoints ===
@app.api_route(
    "/{pod_suffix}/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"],
    include_in_schema=False,
)
async def proxy_request(pod_suffix: str, path: str, request: Request):
    entries = list_entries_by_suffix(pod_suffix)
    if not entries:
        raise HTTPException(status_code=404, detail=f"沒有找到 suffix={pod_suffix} 的設定")

    # pick longest-matching endpoint
    full_path = "/" + (path or "")
    matched = None
    rest_path = "/"
    for e in sorted(entries, key=lambda x: len(x.get("endpoint", "")), reverse=True):
        ep = _normalize_endpoint(e.get("endpoint", ""))
        if full_path == ep or full_path.startswith(ep + "/"):
            matched = e
            remain = full_path[len(ep) :]
            rest_path = remain or "/"
            break
    if not matched:
        raise HTTPException(
            status_code=404,
            detail=f"suffix={pod_suffix} 未找到對應 endpoint（path={full_path}）",
        )

    pod = find_pod_for_user(matched.get("user", ""), pod_suffix)
    if not pod or not pod.get("ip"):
        raise HTTPException(
            status_code=503,
            detail=f"目標 pod 未就緒或不存在：suffix={pod_suffix}",
        )

    target_url = f"http://{pod['ip']}:{matched['port']}{rest_path}"
    params = request.query_params

    headers = {}
    for k, v in request.headers.items():
        lk = k.lower()
        if lk in HOP_HEADERS or lk == "host":
            continue
        headers[k] = v

    body = await request.body()
    try:
        async with httpx.AsyncClient(timeout=PROXY_TIMEOUT) as client:
            upstream = await client.request(
                request.method,
                target_url,
                content=body,
                headers=headers,
                params=params,
            )
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="後端服務逾時")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"轉送失敗：{exc}")

    resp_headers = {}
    for k, v in upstream.headers.items():
        lk = k.lower()
        if lk in HOP_HEADERS:
            continue
        resp_headers[k] = v
    return Response(content=upstream.content, status_code=upstream.status_code, headers=resp_headers)


@app.exception_handler(Exception)
async def generic_error_handler(request: Request, exc: Exception):
    if isinstance(exc, HTTPException):
        return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
    return JSONResponse(status_code=500, content={"detail": "internal error", "message": str(exc)})


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "port_mapper.backend.app:app",
        host=os.environ.get("PORT_MAPPER_BIND", "0.0.0.0"),
        port=int(os.environ.get("PORT_MAPPER_PORT", "32000")),
        reload=False,
    )
