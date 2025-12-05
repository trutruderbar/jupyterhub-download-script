from datetime import datetime, timedelta, timezone
from typing import Optional

LOCAL_TZ = timezone(timedelta(hours=8))


def naive_now_local() -> datetime:
    """Return timezone-naive datetime representing current time in UTC+8."""
    return datetime.now(LOCAL_TZ).replace(tzinfo=None)


def ensure_naive_local(dt: Optional[datetime]) -> Optional[datetime]:
    """Convert aware datetime to UTC+8 and drop tzinfo."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        return dt
    return dt.astimezone(LOCAL_TZ).replace(tzinfo=None)


def isoformat_local(dt: datetime) -> str:
    """Serialize datetime with explicit +08:00 offset."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=LOCAL_TZ)
    else:
        dt = dt.astimezone(LOCAL_TZ)
    return dt.isoformat(timespec="seconds")
