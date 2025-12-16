"""Background auto-recorder that maps live pods into container session records."""
import os
import threading
import time
from datetime import datetime
from typing import Dict, Optional, Set

from sqlalchemy.orm import Session

from . import jhub, models
from .config import DEFAULT_CPU_LIMIT_CORES, DEFAULT_GPU_LIMIT, DEFAULT_MEMORY_LIMIT_GIB
from .database import SessionLocal
from .timeutils import ensure_naive_local, naive_now_local, LOCAL_TZ


GPU_RATE_PER_HOUR = float(os.getenv("GPU_RATE_PER_HOUR", "4"))
PVC_LAST_USED_TOUCH_INTERVAL_SECONDS = int(os.getenv("PVC_LAST_USED_TOUCH_INTERVAL_SECONDS", "3600"))


def _parse_time(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value).astimezone(LOCAL_TZ)
    except Exception:
        return None


def _memory_mb(mebibytes: Optional[float]) -> int:
    if mebibytes is None:
        return 0
    return int(mebibytes * 1.048576)


class UsageAutoRecorder:
    """Polls JupyterHub pods and mirrors them into container_sessions rows."""

    def __init__(self, interval_seconds: int = 30):
        self.interval_seconds = max(5, interval_seconds)
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._pvc_last_used_cache: Dict[str, float] = {}

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run_loop, name="usage-auto-recorder", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=5)

    def _run_loop(self) -> None:
        while not self._stop_event.is_set():
            start_ts = time.time()
            try:
                self._sync_once()
            except Exception as exc:  # pragma: no cover - defensive logging
                print(f"[usage-auto] sync failed: {exc}")
            elapsed = time.time() - start_ts
            wait_for = max(1.0, self.interval_seconds - elapsed)
            self._stop_event.wait(wait_for)

    def _sync_once(self) -> None:
        payload = jhub.collect_usage_payload()
        pods = payload.get("pods", [])
        self._touch_active_pvcs(pods)
        active_names = {pod.get("podName") for pod in pods if pod.get("podName")}
        db: Session = SessionLocal()
        try:
            for pod in pods:
                self._ensure_session(db, pod)
            self._close_finished_sessions(db, active_names)
            db.commit()
        finally:
            db.close()

    def _touch_active_pvcs(self, pods: list) -> None:
        if PVC_LAST_USED_TOUCH_INTERVAL_SECONDS <= 0:
            return
        now_mono = time.monotonic()
        claim_names = set()
        for pod in pods:
            for vol in (pod.get("volumes") or []):
                claim = vol.get("claimName")
                if claim and claim.startswith(jhub.SINGLEUSER_PVC_PREFIX):
                    claim_names.add(claim)

        for claim in claim_names:
            last_touched = self._pvc_last_used_cache.get(claim)
            if last_touched is not None and (now_mono - last_touched) < PVC_LAST_USED_TOUCH_INTERVAL_SECONDS:
                continue
            try:
                jhub.touch_pvc_last_used(claim)
                self._pvc_last_used_cache[claim] = now_mono
            except Exception as exc:  # pragma: no cover - best effort
                print(f"[usage-auto] touch pvc last-used failed: {claim}: {exc}", flush=True)

    def _ensure_session(self, db: Session, pod: Dict) -> None:
        pod_name = pod.get("podName")
        if not pod_name:
            return
        requests = pod.get("requests", {}) or {}
        container_ids = pod.get("containerIds") or []
        first_container_id = container_ids[0] if container_ids else None
        phase = str(pod.get("phase") or "running").lower()

        existing = (
            db.query(models.ContainerSession)
            .filter(models.ContainerSession.container_name == pod_name)
            .filter(models.ContainerSession.end_time.is_(None))
            .first()
        )
        if existing:
            updated = False
            if phase and existing.status != phase:
                existing.status = phase
                updated = True
            if first_container_id and existing.container_id != first_container_id:
                existing.container_id = first_container_id
                updated = True
            requested_cpu = (requests.get("cpuMillicores") or 0) / 1000.0
            requested_memory = _memory_mb(requests.get("memoryMiB"))
            requested_gpu = int(float(requests.get("gpu") or 0) or 0)
            if requested_cpu and existing.requested_cpu != requested_cpu:
                existing.requested_cpu = requested_cpu
                updated = True
            if requested_memory and existing.requested_memory_mb != requested_memory:
                existing.requested_memory_mb = requested_memory
                updated = True
            if requested_gpu and existing.requested_gpu != requested_gpu:
                existing.requested_gpu = requested_gpu
                updated = True
            if updated:
                db.add(existing)
            return
        user_obj = self._get_or_create_user(db, pod)
        start_time = _parse_time(pod.get("startTime")) or datetime.now(LOCAL_TZ)
        gpu_count = int(float(requests.get("gpu") or 0) or 0)
        cost_rate = GPU_RATE_PER_HOUR * max(gpu_count, 1) if gpu_count else 0

        session = models.ContainerSession(
            user_id=user_obj.id,
            container_name=pod_name,
            container_id=first_container_id,
            requested_cpu=(requests.get("cpuMillicores") or 0) / 1000.0,
            requested_memory_mb=_memory_mb(requests.get("memoryMiB")),
            requested_gpu=gpu_count,
            cost_rate_per_hour=cost_rate,
            status=phase,
            start_time=ensure_naive_local(start_time),
            notes="auto-recorded from JupyterHub pod monitor",
        )
        db.add(session)

    def _close_finished_sessions(self, db: Session, active_pod_names: Set[str]) -> None:
        if not active_pod_names:
            active_pod_names = set()
        open_sessions = db.query(models.ContainerSession).filter(models.ContainerSession.end_time.is_(None)).all()
        now = naive_now_local()
        for session in open_sessions:
            if session.container_name not in active_pod_names:
                session.end_time = now
                session.status = "completed"

    def _get_or_create_user(self, db: Session, pod: Dict) -> models.User:
        username = pod.get("user") or "(unknown)"
        display = pod.get("displayUser") or username
        existing = db.query(models.User).filter(models.User.username == username).first()
        if existing:
            return existing
        email = f"{username}+auto@example.com"
        suffix = 1
        while db.query(models.User).filter(models.User.email == email).first():
            suffix += 1
            email = f"{username}+auto{suffix}@example.com"
        user = models.User(
            username=username,
            full_name=display,
            email=email,
            department="auto",
            cpu_limit_cores=DEFAULT_CPU_LIMIT_CORES,
            memory_limit_gib=DEFAULT_MEMORY_LIMIT_GIB,
            gpu_limit=DEFAULT_GPU_LIMIT,
        )
        db.add(user)
        db.flush()
        return user


def recorder_from_env() -> Optional[UsageAutoRecorder]:
    enabled = os.getenv("AUTO_RECORD_ENABLED", "true").lower() in {"1", "true", "yes", "on"}
    if not enabled:
        return None
    interval = int(os.getenv("AUTO_RECORD_INTERVAL", "30"))
    return UsageAutoRecorder(interval_seconds=interval)
