from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from .config import DEFAULT_CPU_LIMIT_CORES, DEFAULT_GPU_LIMIT, DEFAULT_MEMORY_LIMIT_GIB


class UserBase(BaseModel):
    username: str = Field(..., max_length=64)
    full_name: str
    email: EmailStr
    department: Optional[str] = None
    cpu_limit_cores: int = Field(default=DEFAULT_CPU_LIMIT_CORES, ge=1)
    memory_limit_gib: int = Field(default=DEFAULT_MEMORY_LIMIT_GIB, ge=1)
    gpu_limit: int = Field(default=DEFAULT_GPU_LIMIT, ge=0)


class UserCreate(UserBase):
    pass


class UserUpdate(BaseModel):
    full_name: Optional[str] = None
    department: Optional[str] = None
    cpu_limit_cores: Optional[int] = Field(default=None, ge=1)
    memory_limit_gib: Optional[int] = Field(default=None, ge=1)
    gpu_limit: Optional[int] = Field(default=None, ge=0)


class UserRead(UserBase):
    id: int
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class ContainerSessionBase(BaseModel):
    container_name: str
    container_id: Optional[str] = None
    requested_cpu: float = Field(..., ge=0)
    requested_memory_mb: int = Field(..., ge=0)
    requested_gpu: int = Field(default=0, ge=0)
    cost_rate_per_hour: float = Field(default=0, ge=0)
    notes: Optional[str] = None


class ContainerSessionCreate(ContainerSessionBase):
    user_id: int
    start_time: Optional[datetime] = None


class ContainerSessionUpdate(BaseModel):
    status: Optional[str] = None
    end_time: Optional[datetime] = None
    actual_cpu_hours: Optional[float] = Field(default=None, ge=0)
    actual_memory_mb_hours: Optional[float] = Field(default=None, ge=0)
    notes: Optional[str] = None


class ContainerSessionRead(ContainerSessionBase):
    id: int
    user_id: int
    status: str
    start_time: datetime
    end_time: Optional[datetime] = None
    actual_cpu_hours: float
    actual_memory_mb_hours: float

    model_config = ConfigDict(from_attributes=True)


class UsageSummary(BaseModel):
    user_id: int
    username: str
    full_name: str
    total_sessions: int
    total_hours: float
    total_estimated_cost: float


class MachineInfo(BaseModel):
    name: str
    status: str
    ready: bool
    roles: str | None = None
    os_image: str | None = None
    kernel_version: str | None = None
    container_runtime: str | None = None
    capacity_cpu: float
    capacity_memory_gib: float
    capacity_gpu: float
    allocatable_cpu: float
    allocatable_memory_gib: float
    allocatable_gpu: float


class UserUsageStats(BaseModel):
    available: bool = True
    cpu_cores: float = 0
    memory_gib: float = 0
    gpu: float = 0


class UserLimitResponse(BaseModel):
    username: str
    full_name: str
    cpu_limit_cores: int
    memory_limit_gib: int
    gpu_limit: int
    usage: UserUsageStats


class MachineAddRequest(BaseModel):
    worker_ip: str
    ssh_username: str = "root"
    ssh_password: str
    ssh_port: int = Field(default=22, ge=1)


class MachineRemoteCleanup(BaseModel):
    worker_ip: str
    ssh_username: str = "root"
    ssh_password: str
    ssh_port: int = Field(default=22, ge=1)


class MachineDeleteRequest(BaseModel):
    node_name: str
    drain: bool = True
    force_remove: bool = False
    remote_cleanup: Optional[MachineRemoteCleanup] = None


class ScriptExecutionResult(BaseModel):
    ok: bool
    stdout: str
    stderr: str
    exit_code: int
    hint: str | None = None
