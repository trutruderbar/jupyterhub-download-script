# ---------- Containerd runtime 調整（確保 nvidia runtime 註冊） ----------
_ensure_containerd_nvidia_runtime(){
  local snap_current="/var/snap/microk8s/current"
  local args_dir="${snap_current}/args"
  local template="${args_dir}/containerd-template.toml"
  local config="${args_dir}/containerd.toml"
  local dropin="/etc/containerd/conf.d/99-nvidia.toml"

  mkdir -p /etc/containerd/conf.d

  if [[ -f "${template}" ]] && ! grep -Fq '/etc/containerd/conf.d/*.toml' "${template}"; then
    local tmp; tmp="$(mktemp)"
    printf 'imports = ["/etc/containerd/conf.d/*.toml"]\n' >"${tmp}"
    cat "${template}" >>"${tmp}"
    mv "${tmp}" "${template}"
  fi
  if [[ -f "${config}" ]] && ! grep -Fq '/etc/containerd/conf.d/*.toml' "${config}"; then
    local tmp; tmp="$(mktemp)"
    printf 'imports = ["/etc/containerd/conf.d/*.toml"]\n' >"${tmp}"
    cat "${config}" >>"${tmp}"
    mv "${tmp}" "${config}"
  fi

  cat <<'TOML' >"${dropin}"
version = 2

[plugins]

  [plugins."io.containerd.grpc.v1.cri"]
    enable_cdi = true
    enable_selinux = false
    enable_tls_streaming = false
    max_container_log_line_size = 16384
    sandbox_image = "registry.k8s.io/pause:3.7"
    stats_collect_period = 10
    stream_server_address = "127.0.0.1"
    stream_server_port = "0"

    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/var/snap/microk8s/current/opt/cni/bin"
      conf_dir = "/var/snap/microk8s/current/args/cni-network"

    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      no_pivot = false
      snapshotter = "overlayfs"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
          runtime_type = "io.containerd.kata.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
            BinaryName = "kata-runtime"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
            BinaryName = "/usr/local/nvidia/toolkit/nvidia-container-runtime"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-cdi]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-cdi.options]
            BinaryName = "/usr/local/nvidia/toolkit/nvidia-container-runtime.cdi"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-container-runtime]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-container-runtime.options]
            BinaryName = "nvidia-container-runtime"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-legacy]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-legacy.options]
            BinaryName = "/usr/local/nvidia/toolkit/nvidia-container-runtime.legacy"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"

    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/var/snap/microk8s/current/args/certs.d"
TOML

  systemctl restart snap.microk8s.daemon-containerd
  sleep 3
}

