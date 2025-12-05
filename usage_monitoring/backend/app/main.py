import json
import os
import shlex
import subprocess
from pathlib import Path
from typing import List, Optional, Tuple

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session
import httpx
from . import crud, jhub, models, schemas
from .config import DEFAULT_CPU_LIMIT_CORES, DEFAULT_GPU_LIMIT, DEFAULT_MEMORY_LIMIT_GIB
from .auto_recorder import recorder_from_env
from .database import Base, engine, get_db, SessionLocal
from .mysql_sync import pod_report_sync_from_env


def _ensure_user_limit_columns() -> None:
    dialect = engine.dialect.name
    with engine.begin() as connection:
        if dialect == "sqlite":
            existing = {row[1] for row in connection.exec_driver_sql("PRAGMA table_info(users)").fetchall()}

            def _add(column: str, default: int) -> None:
                connection.exec_driver_sql(
                    f"ALTER TABLE users ADD COLUMN {column} INTEGER NOT NULL DEFAULT {default}"
                )

            if "cpu_limit_cores" not in existing:
                _add("cpu_limit_cores", DEFAULT_CPU_LIMIT_CORES)
            if "memory_limit_gib" not in existing:
                _add("memory_limit_gib", DEFAULT_MEMORY_LIMIT_GIB)
            if "gpu_limit" not in existing:
                _add("gpu_limit", DEFAULT_GPU_LIMIT)
        else:
            statements = [
                f"ALTER TABLE users ADD COLUMN IF NOT EXISTS cpu_limit_cores INTEGER NOT NULL DEFAULT {DEFAULT_CPU_LIMIT_CORES}",
                f"ALTER TABLE users ADD COLUMN IF NOT EXISTS memory_limit_gib INTEGER NOT NULL DEFAULT {DEFAULT_MEMORY_LIMIT_GIB}",
                f"ALTER TABLE users ADD COLUMN IF NOT EXISTS gpu_limit INTEGER NOT NULL DEFAULT {DEFAULT_GPU_LIMIT}",
            ]
            for stmt in statements:
                connection.exec_driver_sql(stmt)


Base.metadata.create_all(bind=engine)
_ensure_user_limit_columns()

LOGIN_API = os.getenv("PORTAL_LOGIN_API", "/iam/command")
LOGIN_PROXY_PATH = os.getenv("PORTAL_LOGIN_PROXY_PATH", "/iam/command")
LOGIN_PROXY_TARGET = os.getenv("PORTAL_LOGIN_PROXY_TARGET", "")
LOGIN_PROXY_TIMEOUT = float(os.getenv("PORTAL_LOGIN_PROXY_TIMEOUT", "10"))
ROOT_DIR = Path(__file__).resolve().parents[3]


app = FastAPI(title="Usage Portal", version="2.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

BASE_DIR = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
static_dir = BASE_DIR / "static"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

recorder = recorder_from_env()
pod_report_sync = pod_report_sync_from_env(SessionLocal)


def _empty_usage() -> dict:
    return {"cpu_cores": 0.0, "memory_gib": 0.0, "gpu": 0.0}


def _require_root_privileges() -> None:
    if hasattr(os, "geteuid"):
        if os.geteuid() != 0:
            raise HTTPException(status_code=500, detail="Portal backend 必須以 root 身分執行 add_node.sh / del_node.sh")


def _run_portal_script(script_name: str, answers: List[str]) -> schemas.ScriptExecutionResult:
    script_path = ROOT_DIR / script_name
    if not script_path.exists():
        raise HTTPException(status_code=500, detail=f"找不到腳本 {script_path}")
    _require_root_privileges()
    cleaned = [(value or "").replace("\n", "").strip() for value in answers]
    input_data = "\n".join(cleaned) + "\n"
    try:
        proc = subprocess.run(
            ["bash", str(script_path)],
            input=input_data,
            text=True,
            capture_output=True,
            cwd=str(ROOT_DIR),
            env=os.environ.copy(),
        )
    except OSError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    hint = None
    if proc.returncode != 0:
        hint = _script_failure_hint(script_name, proc.stdout or "", proc.stderr or "")
    return schemas.ScriptExecutionResult(
        ok=proc.returncode == 0,
        stdout=proc.stdout or "",
        stderr=proc.stderr or "",
        exit_code=proc.returncode,
        hint=hint,
    )


def _script_failure_hint(script_name: str, stdout: str, stderr: str) -> Optional[str]:
    combined = f"{stdout}\n{stderr}".lower()
    if "registered with dqlite" in combined:
        return (
            "MicroK8s 回報該節點仍註冊在 dqlite。"
            "請先登入該節點執行 'sudo microk8s leave' 並清理 MicroK8s，"
            "之後再重新刪除；若節點已無法登入，可勾選「強制移除」使用 --force"
        )
    if script_name == "del_node.sh" and "FailedMount" in stdout:
        return (
            "刪除前請確認節點上的 Pod/PVC 已清除；必要時可手動 cordon/drain 後再嘗試。"
        )
    return None

def _canonical_username(raw: str) -> str:
    return (raw or "").strip().replace(".", "-")


def _usage_for_user(username: str) -> Tuple[bool, dict]:
    normalized = (username or "").strip().lower()
    if not normalized:
        return True, _empty_usage()
    try:
        payload = jhub.collect_usage_payload()
    except jhub.PodActionError:
        return False, _empty_usage()
    for entry in payload.get("users", []) or []:
        entry_name = (entry.get("user") or "").lower()
        if entry_name != normalized:
            continue
        cpu_millicores = entry.get("totalRequestedCpuMillicores") or 0.0
        mem_mib = entry.get("totalRequestedMemoryMiB") or 0.0
        gpu_requested = entry.get("gpuRequested") or 0.0
        try:
            cpu_val = float(cpu_millicores) / 1000.0
        except (TypeError, ValueError):
            cpu_val = 0.0
        try:
            mem_val = float(mem_mib) / 1024.0
        except (TypeError, ValueError):
            mem_val = 0.0
        try:
            gpu_val = float(gpu_requested)
        except (TypeError, ValueError):
            gpu_val = 0.0
        return True, {"cpu_cores": cpu_val, "memory_gib": mem_val, "gpu": gpu_val}
    return True, _empty_usage()


def _generate_placeholder_email(db: Session, username: str) -> str:
    safe_username = username.replace("@", ".")
    base = f"{safe_username}+portal@example.com"
    candidate = base
    suffix = 1
    while db.query(models.User).filter(models.User.email == candidate).first():
        suffix += 1
        candidate = f"{safe_username}+portal{suffix}@example.com"
    return candidate


def _ensure_portal_user(db: Session, username: str) -> models.User:
    original = (username or "").strip()
    if not original:
        raise HTTPException(status_code=400, detail="Username is required")
    canonical = _canonical_username(original)
    existing = crud.get_user_by_username(db, canonical)
    if existing:
        return existing
    placeholder_email = _generate_placeholder_email(db, canonical)
    placeholder = schemas.UserCreate(
        username=canonical,
        full_name=original,
        email=placeholder_email,
        department="auto-generated",
    )
    return crud.create_user(db, placeholder)


def require_dashboard_token(
    authorization: str = Header(default=""),
    x_dashboard_token: str = Header(default=""),
):
    token = jhub.DASHBOARD_TOKEN
    if not token:
        return
    scheme, _, value = authorization.partition(" ")
    if scheme.lower() == "bearer" and value.strip() == token:
        return
    if x_dashboard_token and x_dashboard_token.strip() == token:
        return
    raise HTTPException(status_code=401, detail="Invalid or missing dashboard token")


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "dashboard_namespace": jhub.JHUB_NAMESPACE,
            "token_protected": bool(jhub.DASHBOARD_TOKEN),
            "api_token": jhub.DASHBOARD_TOKEN,
            "login_api": LOGIN_API,
        },
    )


@app.post(LOGIN_PROXY_PATH)
async def proxy_login(request: Request):
    if not LOGIN_PROXY_TARGET:
        raise HTTPException(status_code=503, detail="登入服務尚未設定")
    query_string = request.url.query
    target_url = LOGIN_PROXY_TARGET
    if query_string:
        separator = '&' if '?' in target_url else '?'
        target_url = f"{target_url}{separator}{query_string}"
    headers = dict(request.headers)
    headers.pop("host", None)
    body = await request.body()
    async with httpx.AsyncClient(timeout=LOGIN_PROXY_TIMEOUT) as client:
        upstream = await client.post(target_url, content=body, headers=headers)
    excluded = {"content-length", "content-encoding", "transfer-encoding", "connection"}
    response_headers = {k: v for k, v in upstream.headers.items() if k.lower() not in excluded}
    return Response(content=upstream.content, status_code=upstream.status_code, headers=response_headers)


def _parse_cpu_quantity(value: Optional[str]) -> float:
    if value is None:
        return 0.0
    text = str(value).strip()
    if not text:
        return 0.0
    if text.endswith("m"):
        try:
            return float(text[:-1]) / 1000.0
        except ValueError:
            return 0.0
    try:
        return float(text)
    except ValueError:
        return 0.0


_MEMORY_SUFFIX = {
    "Ki": 1024,
    "Mi": 1024 ** 2,
    "Gi": 1024 ** 3,
    "Ti": 1024 ** 4,
    "Pi": 1024 ** 5,
    "Ei": 1024 ** 6,
    "k": 1000,
    "M": 1000 ** 2,
    "G": 1000 ** 3,
    "T": 1000 ** 4,
}


def _parse_memory_gib(value: Optional[str]) -> float:
    if value is None:
        return 0.0
    text = str(value).strip()
    if not text:
        return 0.0
    for suffix, multiplier in _MEMORY_SUFFIX.items():
        if text.endswith(suffix):
            try:
                number = float(text[: -len(suffix)])
            except ValueError:
                return 0.0
            bytes_value = number * multiplier
            return bytes_value / (1024 ** 3)
    try:
        return float(text)
    except ValueError:
        return 0.0


def _parse_gpu_quantity(value: Optional[str]) -> float:
    if not value:
        return 0.0
    try:
        return float(value)
    except ValueError:
        return 0.0


def _collect_machine_status() -> List[schemas.MachineInfo]:
    try:
        raw = jhub.run_kubectl(["get", "nodes", "-o", "json"])
    except jhub.PodActionError as exc:
        raise HTTPException(status_code=500, detail=f"無法取得節點資訊：{exc}")
    data = json.loads(raw)
    machines: List[schemas.MachineInfo] = []
    for item in data.get("items", []):
        metadata = item.get("metadata") or {}
        status = item.get("status") or {}
        node_info = status.get("nodeInfo") or {}
        conditions = status.get("conditions") or []
        ready = False
        node_status = "Unknown"
        for cond in conditions:
            if cond.get("type") == "Ready":
                ready = cond.get("status") == "True"
                node_status = "Ready" if ready else "NotReady"
                break
        roles = metadata.get("labels", {}).get("kubernetes.io/role") or metadata.get("labels", {}).get("node-role.kubernetes.io/master")
        capacity = status.get("capacity") or {}
        allocatable = status.get("allocatable") or {}
        machines.append(
            schemas.MachineInfo(
                name=metadata.get("name", "unknown"),
                status=node_status,
                ready=ready,
                roles=roles,
                os_image=node_info.get("osImage"),
                kernel_version=node_info.get("kernelVersion"),
                container_runtime=node_info.get("containerRuntimeVersion"),
                capacity_cpu=_parse_cpu_quantity(capacity.get("cpu")),
                capacity_memory_gib=_parse_memory_gib(capacity.get("memory")),
                capacity_gpu=_parse_gpu_quantity(capacity.get("nvidia.com/gpu")),
                allocatable_cpu=_parse_cpu_quantity(allocatable.get("cpu")),
                allocatable_memory_gib=_parse_memory_gib(allocatable.get("memory")),
                allocatable_gpu=_parse_gpu_quantity(allocatable.get("nvidia.com/gpu")),
            )
        )
    return machines


@app.post("/users", response_model=schemas.UserRead)
def create_user(user: schemas.UserCreate, db: Session = Depends(get_db)):
    existing = db.query(models.User).filter(models.User.username == user.username).first()
    if existing:
        raise HTTPException(status_code=400, detail="Username already exists")
    existing_email = db.query(models.User).filter(models.User.email == user.email).first()
    if existing_email:
        raise HTTPException(status_code=400, detail="Email already exists")
    return crud.create_user(db, user)


@app.get("/users", response_model=List[schemas.UserRead])
def list_users(db: Session = Depends(get_db)):
    return crud.get_users(db)


@app.get("/users/{username}/limits", response_model=schemas.UserLimitResponse)
def user_limits(username: str, db: Session = Depends(get_db)):
    user = _ensure_portal_user(db, username)
    usage_available, usage_stats = _usage_for_user(user.username)
    usage = schemas.UserUsageStats(
        available=usage_available,
        cpu_cores=usage_stats["cpu_cores"],
        memory_gib=usage_stats["memory_gib"],
        gpu=usage_stats["gpu"],
    )
    return schemas.UserLimitResponse(
        username=user.username,
        full_name=user.full_name,
        cpu_limit_cores=user.cpu_limit_cores,
        memory_limit_gib=user.memory_limit_gib,
        gpu_limit=user.gpu_limit,
        usage=usage,
    )


@app.get("/machines", response_model=List[schemas.MachineInfo])
def list_machines(_: None = Depends(require_dashboard_token)):
    return _collect_machine_status()


@app.post("/machines/add", response_model=schemas.ScriptExecutionResult)
def add_machine(payload: schemas.MachineAddRequest):
    worker_ip = (payload.worker_ip or "").strip()
    if not worker_ip:
        raise HTTPException(status_code=400, detail="worker_ip 必填")
    ssh_user = (payload.ssh_username or "root").strip() or "root"
    ssh_password = payload.ssh_password or ""
    if not ssh_password:
        raise HTTPException(status_code=400, detail="SSH 密碼不可為空白")
    ssh_port = payload.ssh_port or 22
    answers = [
        worker_ip,
        ssh_user,
        ssh_password,
        str(ssh_port),
    ]
    return _run_portal_script("add_node.sh", answers)


@app.post("/machines/delete", response_model=schemas.ScriptExecutionResult)
def delete_machine(payload: schemas.MachineDeleteRequest):
    node_name = (payload.node_name or "").strip()
    if not node_name:
        raise HTTPException(status_code=400, detail="node_name 必填")
    answers = [
        node_name,
        "y" if payload.drain else "n",
        "y" if payload.force_remove else "n",
    ]
    remote_cleanup = payload.remote_cleanup
    remote_enabled = remote_cleanup is not None
    answers.append("y" if remote_enabled else "n")
    if remote_enabled and remote_cleanup:
        worker_ip = (remote_cleanup.worker_ip or "").strip()
        if not worker_ip:
            raise HTTPException(status_code=400, detail="remote_cleanup.worker_ip 必填")
        ssh_user = (remote_cleanup.ssh_username or "root").strip() or "root"
        ssh_password = remote_cleanup.ssh_password or ""
        if not ssh_password:
            raise HTTPException(status_code=400, detail="remote_cleanup.ssh_password 必填")
        ssh_port = remote_cleanup.ssh_port or 22
        answers.extend(
            [
                worker_ip,
                ssh_user,
                ssh_password,
                str(ssh_port),
            ]
        )
    return _run_portal_script("del_node.sh", answers)


@app.patch("/users/{full_name}", response_model=schemas.UserRead)
def update_user(full_name: str, payload: schemas.UserUpdate, db: Session = Depends(get_db)):
    user = crud.update_user_by_full_name(db, full_name, payload)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@app.get("/sessions", response_model=List[schemas.ContainerSessionRead])
def list_sessions(user_id: Optional[int] = Query(default=None), db: Session = Depends(get_db)):
    return crud.get_sessions(db, user_id=user_id)


@app.post("/sessions", response_model=schemas.ContainerSessionRead)
def create_session(payload: schemas.ContainerSessionCreate, db: Session = Depends(get_db)):
    user = crud.get_user(db, payload.user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return crud.create_container_session(db, payload)


@app.patch("/sessions/{session_id}", response_model=schemas.ContainerSessionRead)
def update_session(session_id: int, payload: schemas.ContainerSessionUpdate, db: Session = Depends(get_db)):
    session = crud.update_container_session(db, session_id, payload)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    return session


@app.get("/billing/summary", response_model=List[schemas.UsageSummary])
def billing_summary(db: Session = Depends(get_db)):
    return crud.get_usage_summary(db)


@app.get("/api/usage")
def jhub_usage(_: None = Depends(require_dashboard_token)):
    try:
        return jhub.collect_usage_payload()
    except jhub.PodActionError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.post("/api/pods/{pod_name}/action")
def pod_action(pod_name: str, payload: dict, _: None = Depends(require_dashboard_token)):
    action = payload.get("action")
    if action != "delete":
        raise HTTPException(status_code=400, detail="Unsupported action")
    try:
        jhub.delete_pod(pod_name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except jhub.PodActionError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"message": f"Pod {pod_name} 已刪除"}


@app.post("/api/pod-report-sync")
def trigger_pod_report_sync(_: None = Depends(require_dashboard_token)):
    if not pod_report_sync:
        raise HTTPException(status_code=503, detail="pod_report 同步尚未啟用")
    try:
        result = pod_report_sync.sync_now()
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"status": "ok", **result}


@app.get("/health")
def healthcheck():
    return {"status": "ok"}


@app.on_event("startup")
def on_startup():
    if recorder:
        recorder.start()
    if pod_report_sync:
        pod_report_sync.start()


@app.on_event("shutdown")
def on_shutdown():
    if recorder:
        recorder.stop()
    if pod_report_sync:
        pod_report_sync.stop()


if __name__ == "__main__":
    import uvicorn

    host = os.environ.get("APP_HOST", "0.0.0.0")
    port = int(os.environ.get("APP_PORT", "29781"))
    uvicorn.run("app.main:app", host=host, port=port, reload=False)
