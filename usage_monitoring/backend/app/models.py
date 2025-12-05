from sqlalchemy import Column, DateTime, Float, ForeignKey, Integer, Numeric, String, Text
from sqlalchemy.orm import relationship

from .config import DEFAULT_CPU_LIMIT_CORES, DEFAULT_GPU_LIMIT, DEFAULT_MEMORY_LIMIT_GIB
from .database import Base
from .timeutils import naive_now_local


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String(64), nullable=False, unique=True, index=True)
    full_name = Column(String(128), nullable=False)
    email = Column(String(256), nullable=False, unique=True)
    department = Column(String(128), nullable=True)
    created_at = Column(DateTime, default=naive_now_local, nullable=False)
    cpu_limit_cores = Column(
        Integer,
        nullable=False,
        default=DEFAULT_CPU_LIMIT_CORES,
        server_default=str(DEFAULT_CPU_LIMIT_CORES),
    )
    memory_limit_gib = Column(
        Integer,
        nullable=False,
        default=DEFAULT_MEMORY_LIMIT_GIB,
        server_default=str(DEFAULT_MEMORY_LIMIT_GIB),
    )
    gpu_limit = Column(
        Integer,
        nullable=False,
        default=DEFAULT_GPU_LIMIT,
        server_default=str(DEFAULT_GPU_LIMIT),
    )

    sessions = relationship("ContainerSession", back_populates="user", cascade="all, delete-orphan")


class ContainerSession(Base):
    __tablename__ = "container_sessions"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    container_name = Column(String(128), nullable=False)
    container_id = Column(String(128), nullable=True)
    requested_cpu = Column(Float, nullable=False)
    requested_memory_mb = Column(Integer, nullable=False)
    requested_gpu = Column(Integer, default=0, nullable=False)
    cost_rate_per_hour = Column(Numeric(10, 2), default=0)
    status = Column(String(32), default="running", nullable=False)
    start_time = Column(DateTime, default=naive_now_local, nullable=False)
    end_time = Column(DateTime, nullable=True)
    actual_cpu_hours = Column(Float, default=0)
    actual_memory_mb_hours = Column(Float, default=0)
    notes = Column(Text, nullable=True)

    user = relationship("User", back_populates="sessions")

    @property
    def usage_seconds(self) -> float:
        end = self.end_time or naive_now_local()
        return (end - self.start_time).total_seconds()
