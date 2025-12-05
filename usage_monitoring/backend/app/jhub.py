"""Utility functions extracted from bin/jhub_usage_dashboard.py for FastAPI integration."""
import json
import os
import re
import shlex
import subprocess
from collections import defaultdict
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

from .timeutils import isoformat_local, LOCAL_TZ

DEFAULT_KUBECTL = "microk8s kubectl"
DEFAULT_NAMESPACE = "jhub"

KUBECTL_CMD = shlex.split(os.environ.get("KUBECTL_BIN", DEFAULT_KUBECTL))
JHUB_NAMESPACE = os.environ.get("JHUB_NAMESPACE", DEFAULT_NAMESPACE)
DASHBOARD_TOKEN = os.environ.get("DASHBOARD_TOKEN", "")

POD_NAME_RE = re.compile(r"^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$")
USERNAME_SANITIZE_RE = re.compile(r"[^a-z0-9]+")
CONTAINER_ID_RE = re.compile(r"([0-9a-f]{32,64})")
USERNAME_LABEL_KEYS = (
    "hub.jupyter.org/username",
    "hub.jupyter.org/escaped-username",
    "hub.jupyter.org/user",
)


class PodActionError(RuntimeError):
    """Raised when kubectl operations fail."""


def _run_command(cmd: List[str]) -> str:
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
    )
    stdout, stderr = proc.communicate()
    if proc.returncode != 0:
        msg = (stderr or stdout or f"Command failed: {' '.join(cmd)}").strip()
        raise PodActionError(msg)
    return stdout


def run_kubectl(args: List[str]) -> str:
    cmd = KUBECTL_CMD + args
    return _run_command(cmd)


def _normalize_username_for_key(value: str) -> str:
    normalized = USERNAME_SANITIZE_RE.sub("-", value.lower()).strip("-")
    return normalized or value


def _extract_username(metadata: Dict[str, dict], pod_name: str) -> Tuple[str, str]:
    labels = metadata.get("labels") or {}
    annotations = metadata.get("annotations") or {}
    for source in (annotations, labels):
        for key in USERNAME_LABEL_KEYS:
            value = source.get(key)
            if value:
                return _normalize_username_for_key(value), value
    if pod_name and pod_name.startswith("jupyter-"):
        remainder = pod_name[len("jupyter-") :]
        if remainder.startswith("-"):
            remainder = remainder[1:]
        if "---" in remainder:
            remainder = remainder.split("---", 1)[0]
        cleaned = remainder.replace("--", "-").strip("-")
        if cleaned:
            return cleaned, cleaned
    return "(unknown)", "(unknown)"


def parse_cpu_to_millicores(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    value = value.strip()
    if value.endswith("m"):
        try:
            return float(value[:-1])
        except ValueError:
            return None
    try:
        return float(value) * 1000.0
    except ValueError:
        return None


_MEM_SUFFIX = {
    "Ki": 1.0 / 1024,
    "Mi": 1.0,
    "Gi": 1024.0,
    "Ti": 1024.0 * 1024,
    "Pi": 1024.0 * 1024 * 1024,
    "Ei": 1024.0 * 1024 * 1024 * 1024,
    "K": 1.0 / 1024,
    "M": 1.0,
    "G": 1024.0,
    "T": 1024.0 * 1024,
}


def parse_mem_to_mebibytes(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    value = value.strip()
    for suffix, ratio in _MEM_SUFFIX.items():
        if value.endswith(suffix):
            try:
                return float(value[: -len(suffix)]) * ratio
            except ValueError:
                return None
    try:
        return float(value) / (1024.0 * 1024.0)
    except ValueError:
        return None


def _normalize_container_id(container_id: Optional[str]) -> str:
    if not container_id:
        return ""
    cid = container_id
    if "://" in cid:
        cid = cid.split("://", 1)[1]
    return cid.strip()


def fetch_pod_metrics() -> Tuple[bool, Dict[str, Dict[str, Optional[float]]]]:
    args = [
        "top",
        "pod",
        "-n",
        JHUB_NAMESPACE,
        "-l",
        "component=singleuser-server",
        "--no-headers",
    ]
    try:
        output = run_kubectl(args)
    except PodActionError:
        return False, {}

    metrics: Dict[str, Dict[str, Optional[float]]] = {}
    for line in output.strip().splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        pod_name, cpu_raw, mem_raw = parts[:3]
        metrics[pod_name] = {
            "cpuRaw": cpu_raw,
            "memRaw": mem_raw,
            "cpuMillicores": parse_cpu_to_millicores(cpu_raw),
            "memMib": parse_mem_to_mebibytes(mem_raw),
        }
    return True, metrics


def collect_volume_mounts(pod_spec: dict, container_spec: dict) -> List[dict]:
    mounts = []
    volumes = {v.get("name"): v for v in pod_spec.get("volumes", [])}
    for vm in container_spec.get("volumeMounts", []):
        vol = volumes.get(vm.get("name"))
        if not vol:
            continue
        pvc = vol.get("persistentVolumeClaim")
        if not pvc:
            continue
        mounts.append(
            {
                "claimName": pvc.get("claimName"),
                "mountPath": vm.get("mountPath"),
                "readOnly": bool(vm.get("readOnly")),
            }
        )
    return mounts


def collect_usage_payload() -> dict:
    args = [
        "get",
        "pods",
        "-n",
        JHUB_NAMESPACE,
        "-l",
        "component=singleuser-server",
        "-o",
        "json",
    ]
    raw = run_kubectl(args)
    data = json.loads(raw)
    metrics_available, metrics_map = fetch_pod_metrics()

    pods: List[dict] = []
    container_index: Dict[str, dict] = {}
    pod_lookup: Dict[str, dict] = {}
    for item in data.get("items", []):
        metadata = item.get("metadata", {})
        status = item.get("status", {})
        spec = item.get("spec", {})
        containers = spec.get("containers", [])
        container = containers[0] if containers else {}
        resources = container.get("resources", {})
        requests = resources.get("requests", {})
        limits = resources.get("limits", {})
        labels = metadata.get("labels", {})
        pod_name = metadata.get("name", "")
        user, display_user = _extract_username(metadata, pod_name)
        server_name = labels.get("hub.jupyter.org/servername", "")
        metrics_entry = metrics_map.get(pod_name, {})
        start_time_raw = status.get("startTime")
        start_time_local = None
        age_seconds = None
        if start_time_raw:
            try:
                start_dt = datetime.fromisoformat(start_time_raw.replace("Z", "+00:00")).astimezone(LOCAL_TZ)
                start_time_local = start_dt
                age_seconds = (datetime.now(LOCAL_TZ) - start_dt).total_seconds()
            except Exception:
                age_seconds = None
        container_ids: List[str] = []
        for cs in status.get("containerStatuses", []):
            cid = _normalize_container_id(cs.get("containerID"))
            if cid:
                container_ids.append(cid)
        node_name = spec.get("nodeName") or status.get("nodeName")
        pod_info = {
            "podName": pod_name,
            "user": user,
            "displayUser": display_user,
            "serverName": server_name,
            "phase": status.get("phase"),
            "node": node_name,
            "ip": status.get("podIP"),
            "startTime": isoformat_local(start_time_local) if start_time_local else start_time_raw,
            "ageSeconds": age_seconds,
            "image": container.get("image"),
            "requests": {
                "cpu": requests.get("cpu"),
                "memory": requests.get("memory"),
                "gpu": requests.get("nvidia.com/gpu"),
                "cpuMillicores": parse_cpu_to_millicores(requests.get("cpu")),
                "memoryMiB": parse_mem_to_mebibytes(requests.get("memory")),
            },
            "limits": {
                "cpu": limits.get("cpu"),
                "memory": limits.get("memory"),
                "gpu": limits.get("nvidia.com/gpu"),
                "cpuMillicores": parse_cpu_to_millicores(limits.get("cpu")),
                "memoryMiB": parse_mem_to_mebibytes(limits.get("memory")),
            },
            "usage": {
                "cpu": metrics_entry.get("cpuRaw"),
                "memory": metrics_entry.get("memRaw"),
                "cpuMillicores": metrics_entry.get("cpuMillicores"),
                "memoryMiB": metrics_entry.get("memMib"),
            },
            "volumes": collect_volume_mounts(spec, container),
            "containerIds": container_ids,
            "gpuUsage": {
                "memoryUsedMiB": 0.0,
                "memoryTotalMiB": 0.0,
                "utilization": 0.0,
                "processCount": 0,
                "deviceCount": 0,
            },
        }
        pods.append(pod_info)
        pod_lookup[pod_name] = pod_info
        for cid in container_ids:
            container_index[cid] = pod_info
            if len(cid) >= 12:
                container_index[cid[:12]] = pod_info

    user_map: Dict[str, dict] = {}
    for pod in pods:
        key = pod["user"] or "(unknown)"
        display_label = pod["displayUser"] or key
        entry = user_map.setdefault(
            key,
            {
                "user": key,
                "displayUser": display_label,
                "podCount": 0,
                "totalCpuMillicores": 0.0,
                "totalMemoryMiB": 0.0,
                "totalRequestedCpuMillicores": 0.0,
                "totalRequestedMemoryMiB": 0.0,
                "gpuRequested": 0.0,
                "gpuMemoryUsedMiB": 0.0,
                "gpuMemoryTotalMiB": 0.0,
                "gpuUtilization": 0.0,
                "gpuDeviceCount": 0,
                "gpuProcessCount": 0,
            },
        )
        if display_label:
            entry["displayUser"] = display_label
        entry["podCount"] += 1
        entry["totalCpuMillicores"] += pod["usage"]["cpuMillicores"] or 0.0
        entry["totalMemoryMiB"] += pod["usage"]["memoryMiB"] or 0.0
        entry["totalRequestedCpuMillicores"] += pod["requests"]["cpuMillicores"] or 0.0
        entry["totalRequestedMemoryMiB"] += pod["requests"]["memoryMiB"] or 0.0
        gpu_req = pod["requests"].get("gpu")
        if gpu_req:
            try:
                entry["gpuRequested"] += float(gpu_req)
            except ValueError:
                pass

    _augment_with_gpu_metrics(pods, container_index, user_map, pod_lookup)

    users_list = list(user_map.values())
    users_list.sort(key=lambda x: (x.get("displayUser") or x["user"] or "").lower())
    return {
        "namespace": JHUB_NAMESPACE,
        "updatedAt": isoformat_local(datetime.now(LOCAL_TZ)),
        "metricsAvailable": metrics_available,
        "pods": pods,
        "users": users_list,
    }


def _augment_with_gpu_metrics(
    pods: List[dict],
    container_index: Dict[str, dict],
    user_map: Dict[str, dict],
    pod_lookup: Dict[str, dict],
) -> None:
    process_usage, device_to_pods = _collect_gpu_process_metrics(container_index)
    device_metrics = _collect_gpu_device_metrics()
    if not process_usage and not device_metrics:
        return
    for pod_name, usage in process_usage.items():
        pod = pod_lookup.get(pod_name)
        if not pod:
            continue
        gpu_usage = pod.setdefault(
            "gpuUsage",
            {
                "memoryUsedMiB": 0.0,
                "memoryTotalMiB": 0.0,
                "utilization": 0.0,
                "processCount": 0,
                "deviceCount": 0,
            },
        )
        gpu_usage["memoryUsedMiB"] += usage["memoryUsedMiB"]
        gpu_usage["processCount"] += usage["processCount"]
        gpu_usage["deviceCount"] = len(usage["devices"])
        user_entry = user_map.get(pod["user"])
        if user_entry:
            user_entry["gpuMemoryUsedMiB"] += usage["memoryUsedMiB"]
            user_entry["gpuProcessCount"] += usage["processCount"]
            user_entry["gpuDeviceCount"] += len(usage["devices"])
    for uuid, metrics in device_metrics.items():
        pods_for_device = list(device_to_pods.get(uuid, []))
        if not pods_for_device:
            continue
        util_share = metrics["utilization"] / len(pods_for_device)
        mem_total_share = metrics["memoryTotalMiB"] / len(pods_for_device)
        for pod_name in pods_for_device:
            pod = pod_lookup.get(pod_name)
            if not pod:
                continue
            gpu_usage = pod.setdefault(
                "gpuUsage",
                {
                    "memoryUsedMiB": 0.0,
                    "memoryTotalMiB": 0.0,
                    "utilization": 0.0,
                    "processCount": 0,
                    "deviceCount": 0,
                },
            )
            gpu_usage["memoryTotalMiB"] += mem_total_share
            gpu_usage["utilization"] += util_share
            user_entry = user_map.get(pod["user"])
            if user_entry:
                user_entry["gpuMemoryTotalMiB"] += mem_total_share
                user_entry["gpuUtilization"] += util_share


def _collect_gpu_process_metrics(container_index: Dict[str, dict]):
    cmd = [
        "nvidia-smi",
        "--query-compute-apps=gpu_uuid,pid,used_gpu_memory",
        "--format=csv,noheader,nounits",
    ]
    try:
        output = _run_command(cmd)
    except (FileNotFoundError, PodActionError):
        return {}, defaultdict(set)
    usage = {}
    device_to_pods: Dict[str, set] = defaultdict(set)
    for line in output.strip().splitlines():
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3:
            continue
        gpu_uuid, pid_str, mem_str = parts[:3]
        try:
            pid = int(pid_str)
            mem = float(mem_str)
        except ValueError:
            continue
        pod = _pod_for_pid(pid, container_index)
        if not pod:
            continue
        entry = usage.setdefault(
            pod["podName"], {"memoryUsedMiB": 0.0, "processCount": 0, "devices": set()}
        )
        entry["memoryUsedMiB"] += mem
        entry["processCount"] += 1
        entry["devices"].add(gpu_uuid)
        device_to_pods[gpu_uuid].add(pod["podName"])
    return usage, device_to_pods


def _collect_gpu_device_metrics():
    cmd = [
        "nvidia-smi",
        "--query-gpu=uuid,utilization.gpu,memory.total",
        "--format=csv,noheader,nounits",
    ]
    try:
        output = _run_command(cmd)
    except (FileNotFoundError, PodActionError):
        return {}
    metrics = {}
    for line in output.strip().splitlines():
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3:
            continue
        uuid, util_str, mem_total_str = parts[:3]
        try:
            util = float(util_str)
            mem_total = float(mem_total_str)
        except ValueError:
            continue
        metrics[uuid] = {"utilization": util, "memoryTotalMiB": mem_total}
    return metrics


def _pod_for_pid(pid: int, container_index: Dict[str, dict]):
    cgroup_path = f"/proc/{pid}/cgroup"
    try:
        with open(cgroup_path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                match = CONTAINER_ID_RE.search(line)
                if not match:
                    continue
                cid = match.group(1)
                if cid in container_index:
                    return container_index[cid]
                short = cid[:12]
                if short in container_index:
                    return container_index[short]
    except (FileNotFoundError, PermissionError):
        return None
    return None


def delete_pod(pod_name: str) -> None:
    if not POD_NAME_RE.match(pod_name):
        raise ValueError("Invalid pod name")
    run_kubectl(["delete", "pod", pod_name, "-n", JHUB_NAMESPACE])
