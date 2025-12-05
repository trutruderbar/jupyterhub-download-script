"""Background job that mirrors local container session records into MySQL jupyterhub.pod_report."""

import os
import threading
import time
from datetime import datetime
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from sqlalchemy.orm import Session

from . import models
from .timeutils import ensure_naive_local, naive_now_local

try:  # pragma: no cover - optional dependency when sync is disabled
    import mysql.connector
    from mysql.connector import MySQLConnection
except Exception:  # pragma: no cover - handled gracefully at runtime
    mysql = None  # type: ignore[assignment]
    MySQLConnection = None  # type: ignore[misc,assignment]

SessionFactory = Callable[[], Session]


class PodReportSync:
    """Periodically replaces jupyterhub.pod_report using local container session records."""

    def __init__(
        self,
        conn_kwargs: Dict[str, object],
        table_name: str,
        namespace: str,
        session_factory: SessionFactory,
        interval_seconds: int = 1800,
    ):
        if mysql is None:  # pragma: no cover - defensive guard
            raise RuntimeError("mysql-connector 不存在，無法啟用 PodReportSync")
        if not callable(session_factory):
            raise ValueError("session_factory 必須可呼叫")
        self.conn_kwargs = conn_kwargs
        self.table_name = table_name
        self.namespace = namespace
        self.interval_seconds = max(60, int(interval_seconds))
        self._session_factory = session_factory
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._run_loop,
            name="pod-report-sync",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=5)

    def _run_loop(self) -> None:
        while not self._stop_event.is_set():
            started = time.time()
            try:
                self._locked_sync()
            except Exception as exc:  # pragma: no cover - defensive logging
                print(f"[pod-report-sync] sync failed: {exc}")
            elapsed = time.time() - started
            wait_for = max(1.0, self.interval_seconds - elapsed)
            self._stop_event.wait(wait_for)

    def _locked_sync(self) -> Dict[str, int]:
        with self._lock:
            return self._sync_once()

    def sync_now(self, block: bool = True) -> Dict[str, int]:
        if block:
            return self._locked_sync()
        acquired = self._lock.acquire(blocking=False)
        if not acquired:
            raise RuntimeError("同步程序執行中")
        try:
            return self._sync_once()
        finally:
            self._lock.release()

    def _sync_once(self) -> Dict[str, int]:
        rows = self._session_rows()
        self._replace_table(rows)
        return {"records": len(rows), "written": len(rows)}

    def _session_rows(self) -> List[Tuple]:
        db: Session = self._session_factory()
        rows_map: Dict[Tuple[str, str], Tuple[Tuple, datetime]] = {}
        try:
            query = (
                db.query(models.ContainerSession, models.User)
                .join(models.User, models.User.id == models.ContainerSession.user_id)
            )
            for session_obj, user_obj in query.all():
                result = self._session_to_row(session_obj, user_obj)
                if not result:
                    continue
                row, start_time = result
                key = (row[0], row[3])
                current = rows_map.get(key)
                if not current or start_time > current[1]:
                    rows_map[key] = (row, start_time)
        finally:
            db.close()
        return [entry[0] for entry in rows_map.values()]

    def _session_to_row(
        self, session_obj: models.ContainerSession, user_obj: models.User
    ) -> Optional[Tuple[Tuple, datetime]]:
        pod_name = (session_obj.container_id or session_obj.container_name or "").strip()
        if not pod_name:
            return None
        username = (user_obj.username or "").strip() or str(user_obj.id)
        display_name = (user_obj.full_name or username).strip() or username
        start_time = ensure_naive_local(session_obj.start_time) if session_obj.start_time else naive_now_local()
        end_time = ensure_naive_local(session_obj.end_time) if session_obj.end_time else naive_now_local()
        if end_time < start_time:
            end_time = start_time
        live_seconds = int((end_time - start_time).total_seconds())
        cpu_usage = "0" if session_obj.requested_cpu is None else f"{session_obj.requested_cpu:g}"
        memory_usage = "0" if session_obj.requested_memory_mb is None else str(session_obj.requested_memory_mb)
        gpu_count = session_obj.requested_gpu or 0
        updated_at = naive_now_local()

        row = (
            username,
            display_name,
            self.namespace,
            pod_name,
            cpu_usage,
            memory_usage,
            gpu_count,
            "0",  # storage_request
            live_seconds,
            start_time,
            updated_at,
        )
        return row, start_time

    def _replace_table(self, rows: Sequence[Tuple]) -> None:
        conn: MySQLConnection = mysql.connector.connect(**self.conn_kwargs)
        try:
            cursor = conn.cursor()
            try:
                cursor.execute(f"DELETE FROM {self.table_name}")
                if rows:
                    cursor.executemany(
                        f"""
                        INSERT INTO {self.table_name}
                        (user_id, user_name, namespace, pod_name, cpu_usage, memory_usage,
                         gpu_count, storage_request, live_time, created_at, updated_at)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                        """,
                        rows,
                    )
                conn.commit()
            finally:
                cursor.close()
        finally:
            conn.close()


def _clean_identifier(identifier: str) -> str:
    parts = [part for part in identifier.split(".") if part]
    if not parts:
        raise ValueError("無效的表格名稱")
    safe_parts = []
    for part in parts:
        cleaned = part.replace("`", "").strip()
        if not cleaned:
            raise ValueError("無效的表格名稱片段")
        safe_parts.append(f"`{cleaned}`")
    return ".".join(safe_parts)


def pod_report_sync_from_env(session_factory: Optional[SessionFactory] = None) -> Optional[PodReportSync]:
    enabled = os.getenv("POD_REPORT_SYNC_ENABLED", "false").lower() in {"1", "true", "yes", "on"}
    if not enabled:
        return None
    if mysql is None:
        print("[pod-report-sync] mysql-connector-python 未安裝，無法啟用")
        return None
    if session_factory is None:
        from .database import SessionLocal

        session_factory = SessionLocal

    host = os.getenv("POD_REPORT_SYNC_DB_HOST")
    user = os.getenv("POD_REPORT_SYNC_DB_USER")
    password = os.getenv("POD_REPORT_SYNC_DB_PASSWORD")
    database = os.getenv("POD_REPORT_SYNC_DB_NAME", "jupyterhub")
    if not host or not user or not password:
        print("[pod-report-sync] DB 連線設定不完整，請提供 POD_REPORT_SYNC_DB_HOST/USER/PASSWORD")
        return None
    port = int(os.getenv("POD_REPORT_SYNC_DB_PORT", "3306"))
    namespace = os.getenv("POD_REPORT_SYNC_NAMESPACE") or os.getenv("JHUB_NAMESPACE", "jhub")
    interval = int(os.getenv("POD_REPORT_SYNC_INTERVAL_SECONDS", "1800"))
    table = _clean_identifier(os.getenv("POD_REPORT_SYNC_TABLE", "pod_report"))

    conn_kwargs = {
        "host": host,
        "port": port,
        "user": user,
        "password": password,
        "database": database,
        "autocommit": False,
    }
    return PodReportSync(
        conn_kwargs=conn_kwargs,
        table_name=table,
        namespace=namespace,
        session_factory=session_factory,
        interval_seconds=interval,
    )
