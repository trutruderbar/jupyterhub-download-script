from typing import Optional


def normalize_base_url(value: Optional[str]) -> str:
    if not value:
        return ""
    return str(value).strip().rstrip("/")
