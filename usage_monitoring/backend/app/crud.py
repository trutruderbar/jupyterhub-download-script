from typing import List, Optional

from sqlalchemy import func, literal
from sqlalchemy.orm import Session

from . import models, schemas
from .timeutils import naive_now_local, ensure_naive_local


# User CRUD

def create_user(db: Session, payload: schemas.UserCreate) -> models.User:
    user = models.User(**payload.dict())
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def get_users(db: Session) -> List[models.User]:
    return db.query(models.User).order_by(models.User.created_at.desc()).all()


def get_user(db: Session, user_id: int) -> Optional[models.User]:
    return db.query(models.User).filter(models.User.id == user_id).first()


def get_user_by_username(db: Session, username: str) -> Optional[models.User]:
    return db.query(models.User).filter(models.User.username == username).first()


def update_user(db: Session, user_id: int, payload: schemas.UserUpdate) -> Optional[models.User]:
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        return None
    updates = payload.dict(exclude_unset=True)
    if not updates:
        return user
    for field, value in updates.items():
        setattr(user, field, value)
    db.commit()
    db.refresh(user)
    return user


def update_user_by_username(db: Session, username: str, payload: schemas.UserUpdate) -> Optional[models.User]:
    user = db.query(models.User).filter(models.User.username == username).first()
    if not user:
        return None
    updates = payload.dict(exclude_unset=True)
    if not updates:
        return user
    for field, value in updates.items():
        setattr(user, field, value)
    db.commit()
    db.refresh(user)
    return user


def update_user_by_full_name(db: Session, full_name: str, payload: schemas.UserUpdate) -> Optional[models.User]:
    user = db.query(models.User).filter(models.User.full_name == full_name).first()
    if not user:
        return None
    updates = payload.dict(exclude_unset=True)
    if not updates:
        return user
    for field, value in updates.items():
        setattr(user, field, value)
    db.commit()
    db.refresh(user)
    return user


# Session CRUD

def create_container_session(
    db: Session, payload: schemas.ContainerSessionCreate
) -> models.ContainerSession:
    session = models.ContainerSession(**payload.dict())
    if session.start_time is None:
        session.start_time = naive_now_local()
    else:
        session.start_time = ensure_naive_local(session.start_time)
    db.add(session)
    db.commit()
    db.refresh(session)
    return session


def update_container_session(
    db: Session, session_id: int, payload: schemas.ContainerSessionUpdate
) -> Optional[models.ContainerSession]:
    session_db = db.query(models.ContainerSession).filter(models.ContainerSession.id == session_id).first()
    if not session_db:
        return None
    updates = payload.dict(exclude_unset=True)
    if "start_time" in updates:
        updates["start_time"] = ensure_naive_local(updates["start_time"])
    if "end_time" in updates:
        updates["end_time"] = ensure_naive_local(updates["end_time"])
    for field, value in updates.items():
        setattr(session_db, field, value)
    if payload.end_time and payload.status is None:
        session_db.status = "completed"
    db.commit()
    db.refresh(session_db)
    return session_db


def get_sessions(db: Session, user_id: Optional[int] = None) -> List[models.ContainerSession]:
    query = db.query(models.ContainerSession).order_by(models.ContainerSession.start_time.desc())
    if user_id:
        query = query.filter(models.ContainerSession.user_id == user_id)
    return query.all()


def get_usage_summary(db: Session) -> List[schemas.UsageSummary]:
    current_local = naive_now_local()
    duration_hours = func.extract(
        'epoch',
        (
            func.coalesce(models.ContainerSession.end_time, literal(current_local))
            - models.ContainerSession.start_time
        ),
    ) / 3600.0

    rows = (
        db.query(
            models.User.id.label("user_id"),
            models.User.username,
            models.User.full_name,
            func.count(models.ContainerSession.id).label("total_sessions"),
            func.coalesce(func.sum(duration_hours), 0).label("total_hours"),
            func.coalesce(func.sum(duration_hours * models.ContainerSession.cost_rate_per_hour), 0).label(
                "total_estimated_cost"
            ),
        )
        .outerjoin(models.ContainerSession, models.User.id == models.ContainerSession.user_id)
        .group_by(models.User.id)
        .order_by(models.User.username)
        .all()
    )

    summaries: List[schemas.UsageSummary] = []
    for row in rows:
        summaries.append(
            schemas.UsageSummary(
                user_id=row.user_id,
                username=row.username,
                full_name=row.full_name,
                total_sessions=row.total_sessions,
                total_hours=float(row.total_hours or 0),
                total_estimated_cost=float(row.total_estimated_cost or 0),
            )
        )
    return summaries
