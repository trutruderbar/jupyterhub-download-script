# syntax=docker/dockerfile:1.4

# 基底：CUDA 12.4.1 + cuDNN（devel 版含本機 CUDA Toolkit / nvcc）
# 宿主機 driver=580.95.05（nvidia-smi 顯示 CUDA 13.0）對 CUDA 12.4 具備向下相容。
FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive

# ── Proxy（可選） ───────────────────────────────────────────────────────
ARG http_proxy
ARG https_proxy
ENV http_proxy=${http_proxy} \
    https_proxy=${https_proxy} \
    HTTP_PROXY=${http_proxy} \
    HTTPS_PROXY=${https_proxy} \
    NO_PROXY=localhost,127.0.0.1,*.svc,10.0.0.0/8,*.local

# ── Pip 基本參數 ───────────────────────────────────────────────────────
ENV PIP_INDEX_URL=https://pypi.org/simple \
    PIP_DEFAULT_TIMEOUT=60 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# ── Miniconda（取代較大的 Anaconda base；/opt/conda 與原流程相容） ────────
ARG MINICONDA_INSTALLER=Miniconda3-py311_25.5.1-0-Linux-x86_64.sh
ARG MINICONDA_SHA256=a921abd74e16f5dee8a4d79b124635fac9b939c465ba2e942ea61b3fcd1451d8
ENV CONDA_DIR=/opt/conda
ENV PATH=${CONDA_DIR}/bin:${PATH}

# ── 系統工具 + 桌面/語言依賴（含 Desktop 必備依賴） ──────────────────────
RUN ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime \
  && echo "Etc/UTC" > /etc/timezone \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates gnupg tzdata unzip xz-utils \
      bzip2 \
      build-essential pkg-config cmake \
      pciutils iproute2 rdma-core ibverbs-providers ibverbs-utils perftest infiniband-diags tini \
      sudo tmux htop less vim nano locales \
      # GUI / Remote Desktop 依賴
      xfce4 xfce4-terminal tigervnc-standalone-server novnc websockify \
      falkon xdg-utils \
      dbus-x11 xauth x11-xserver-utils xfonts-base procps net-tools \
      nfs-common dnsutils \
      # 語言/Kernel 依賴
      r-base r-base-dev \
      nodejs npm \
      openjdk-17-jdk \
      golang-go \
      octave gnuplot \
      graphviz \
      libzmq3-dev \
      pandoc \
  && update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/falkon 100 \
  && update-alternatives --set x-www-browser /usr/bin/falkon \
  && update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/falkon 100 \
  && update-alternatives --set gnome-www-browser /usr/bin/falkon \
  && locale-gen en_US.UTF-8 zh_TW.UTF-8 \
  && update-locale LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8 \
  && dpkg-reconfigure -f noninteractive tzdata \
  && rm -rf /var/lib/apt/lists/*

# ── 安裝 Miniconda ──────────────────────────────────────────────────────
RUN set -eux; \
    wget -qO /tmp/miniconda.sh "https://repo.anaconda.com/miniconda/${MINICONDA_INSTALLER}"; \
    echo "${MINICONDA_SHA256}  /tmp/miniconda.sh" | sha256sum -c -; \
    bash /tmp/miniconda.sh -b -p "${CONDA_DIR}"; \
    rm -f /tmp/miniconda.sh; \
    "${CONDA_DIR}/bin/conda" config --system --set auto_update_conda false; \
    "${CONDA_DIR}/bin/conda" config --system --set show_channel_urls true; \
    "${CONDA_DIR}/bin/conda" clean -afy

# ── CUDA Toolkit / nvcc（由 nvidia/cuda:*cudnn-devel 提供；建置時檢查） ───
RUN nvcc --version

# ── NCCL（官方套件庫；固定選 CUDA 12.4 版本） ────────────────────────────
ARG NCCL_VERSION=2.27.7-1+cuda12.4
RUN set -eux; \
    : "nvidia/cuda base images 通常已內建 CUDA APT repo + keyring（cuda-archive-keyring.gpg）。"; \
    : "若再次新增同一個 repo 但 signed-by 不同，apt 會報錯：Conflicting values set for option Signed-By。"; \
    cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/"; \
    if ! grep -Rqs "${cuda_repo}" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then \
      mkdir -p /usr/share/keyrings; \
      if [ ! -f /usr/share/keyrings/cuda-archive-keyring.gpg ]; then \
        curl -fsSL "${cuda_repo}3bf863cc.pub" | gpg --dearmor -o /usr/share/keyrings/cuda-archive-keyring.gpg; \
      fi; \
      echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] ${cuda_repo} /" > /etc/apt/sources.list.d/cuda-ubuntu2204.list; \
    fi; \
    apt-get update; \
    # nvidia/cuda images 可能會把部分 CUDA/NCCL 套件設為 hold；這裡允許變更 held packages 以固定版本安裝。 \
    apt-mark unhold libnccl2 libnccl-dev >/dev/null 2>&1 || true; \
    apt-get install -y --no-install-recommends --allow-change-held-packages \
      "libnccl2=${NCCL_VERSION}" \
      "libnccl-dev=${NCCL_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

# noVNC 靜態檔路徑（jupyter-remote-desktop-proxy 會使用）
ENV NOVNC_PATH=/usr/share/novnc \
    BROWSER=/usr/bin/falkon

# （更穩）安裝較新的 websockify，避免舊版相容性問題
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir --prefer-binary "websockify==0.11.*"

# ── PyTorch（對齊 CUDA 12.4；避免 runtime/toolkit/NCCL 版本混搭） ─────────
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir --prefer-binary --retries 10 --timeout 60 \
      --index-url https://download.pytorch.org/whl/cu124 \
      "torch==2.4.0+cu124" "torchvision==0.19.0+cu124" "torchaudio==2.4.0+cu124" \
    && python -c "import torch; print('torch', torch.__version__, 'cuda', torch.version.cuda)"

# ── 建立/對齊非 root 使用者（與 JupyterHub 預設對齊） ───────────────────
ENV NB_USER=jovyan \
    NB_UID=1000 \
    NB_GID=100 \
    NB_GROUP=users \
    HOME=/home/jovyan
RUN set -eux; \
    if ! getent group ${NB_GID} >/dev/null; then groupadd -g ${NB_GID} ${NB_GROUP}; fi; \
    if getent passwd ${NB_UID} >/dev/null; then \
        EXISTING_USER="$(getent passwd ${NB_UID} | cut -d: -f1)"; \
        echo "UID ${NB_UID} already exists as '${EXISTING_USER}', reusing it."; \
        mkdir -p "${HOME}/.local" "${HOME}/work"; \
        chown -R ${NB_UID}:${NB_GID} "${HOME}"; \
    else \
        useradd -m -s /bin/bash -N -u ${NB_UID} -g ${NB_GID} ${NB_USER}; \
        mkdir -p "${HOME}/.local" "${HOME}/work"; \
        chown -R ${NB_UID}:${NB_GID} "${HOME}"; \
    fi; \
    chgrp -R ${NB_GID} "${CONDA_DIR}" || true; \
    chmod -R g+rwX "${CONDA_DIR}" || true; \
    find "${CONDA_DIR}" -type d -exec chmod g+s {} \; || true; \
    if getent group sudo >/dev/null 2>&1; then usermod -aG sudo ${NB_USER}; else groupadd -r sudo && usermod -aG sudo ${NB_USER}; fi; \
    mkdir -p /etc/sudoers.d; \
    echo "${NB_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${NB_USER}; \
    chmod 0440 /etc/sudoers.d/${NB_USER}; \
    mkdir -p /workspace /workspace/storage; \
    chown -R ${NB_UID}:${NB_GID} /workspace; \
    chmod -R g+rwX /workspace

# ── Python 基礎 + Jupyter 三件套（穩定組合） ─────────────────────────────
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir --prefer-binary --retries 10 --timeout 60 \
      "jupyterhub~=5.2" "notebook~=7.2" "jupyterlab~=4.2" && \
    jupyterhub --version && jupyter lab --version && \
    python -c "import jupyterhub,notebook,jupyterlab"

# ── 常見 Lab 擴充（Launcher 會多很多入口） ───────────────────────────────
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir --prefer-binary --retries 10 --timeout 60 \
      jupyterlab-link-share jupyter-collaboration jupyter-server-ydoc \
      jupyterlab-git nbdime nbgitpuller \
      jupyterlab-lsp "python-lsp-server[all]" jupyterlab-code-formatter black isort ruff \
      jupyterlab-system-monitor pynvml \
      lckr-jupyterlab-variableinspector jupyterlab_execute_time \
      ipywidgets "plotly==5.*" jupyterlab-drawio \
      jupyterlab_vim jupyterlab_myst \
      dask[complete] dask-labextension \
      voila panel altair vega_datasets \
      jupysql duckdb duckdb-engine sqlalchemy psycopg2-binary pymysql \
      graphviz \
      octave_kernel \
      bash_kernel \
      kubernetes \
      jupyterlab-geojson jupyterlab-spreadsheet-editor \
      jupyterlab-voila jupyterlab-resource-usage \
      "bokeh<3" jupyterlab-nvdashboard \
      transformers datasets scikit-learn \
    && python -m bash_kernel.install \
    && python -m octave_kernel.install || true

# ── Elyra 套件（需先確保 PyYAML wheel） ───────────────────────────────────
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --no-cache-dir --only-binary=:all: "PyYAML>=6.0" && \
    python -m pip install --no-cache-dir --prefer-binary elyra

# ── Lab 擴充：資源用量（狀態列顯示） ───────────────────────────────────────
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir --prefer-binary --retries 10 --timeout 60 \
      jupyter-resource-usage && \
    jupyter server extension enable jupyter_resource_usage && \
    mkdir -p /etc/jupyter/jupyter_server_config.d && \
    cat > /etc/jupyter/jupyter_server_config.d/resource-usage.json <<'JSON'
{
  "ResourceUseDisplay": {
    "track_cpu_percent": true,
    "track_disk_usage": true,
    "disk_path": "/",
    "disk_warning_threshold": 0.1
  }
}
JSON


# ── GPU/通訊（可選，失敗不擋） ───────────────────────────────────────────
RUN --mount=type=cache,target=/root/.cache/pip \
    (pip install --no-cache-dir --prefer-binary --retries 5 --timeout 60 cupy-cuda12x \
      && echo '[OK] cupy-cuda12x installed' \
      || echo '[WARN] cupy-cuda12x skipped') ; \
    (pip install --no-cache-dir --prefer-binary --retries 5 --timeout 60 ucx-py \
      && echo '[OK] ucx-py installed' \
      || echo '[WARN] ucx-py skipped') ; \
    (pip install --no-cache-dir --prefer-binary --retries 5 --timeout 60 jupyterlab-nvdashboard \
      && echo '[OK] jupyterlab-nvdashboard installed' \
      || echo '[WARN] jupyterlab-nvdashboard skipped')

# ── Remote Desktop（Jupyter Launcher 會出現 “Desktop”） ──────────────────
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir --prefer-binary jupyter-remote-desktop-proxy

# ── VS Code（瀏覽器版：code-server + jupyter-server-proxy） ──────────────
RUN (curl -fsSL https://code-server.dev/install.sh | sh && \
     command -v code-server && echo '[OK] code-server installed') || echo '[WARN] code-server skipped'
#
# Fix: code-server 的 webview pre/index.html CSP 缺少 worker-src/child-src，
# 會導致 webview 無法註冊 service worker（Error loading webview / CSP violation）。
RUN set -eux; \
    pre_index="/usr/lib/code-server/lib/vscode/out/vs/workbench/contrib/webview/browser/pre/index.html"; \
    if [ -f "${pre_index}" ]; then \
      if ! grep -q "worker-src" "${pre_index}"; then \
        sed -i "s/default-src 'none';/default-src 'none'; worker-src 'self' blob:; child-src 'self' blob:;/" "${pre_index}"; \
      fi; \
    else \
      echo "[WARN] code-server pre/index.html not found, skipping CSP patch (${pre_index})"; \
    fi
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir --prefer-binary --retries 10 --timeout 60 \
      "jupyter-server-proxy==4.4.0" \
      "jupyter-codeserver-proxy==0.1.0" \
      jupyter-tensorboard-proxy tensorboard \
    && python -c "import jupyter_server_proxy, jupyter_codeserver_proxy" \
    && jupyter server extension enable --sys-prefix jupyter_server_proxy

# 避免全域設定把 Launcher 鎖掉（會看不到 proxy launcher entry）
RUN rm -f "${CONDA_DIR}/etc/jupyter/labconfig/page_config.json" || true

# ── R Kernel（IRkernel + 常用套件） ──────────────────────────────────────
RUN R -q -e "install.packages(c('IRkernel','tidyverse','data.table','arrow','DBI','duckdb','Rcpp'), repos='https://cloud.r-project.org')" \
 && R -q -e "IRkernel::installspec(user = FALSE)" || echo '[WARN] IRkernel skipped'

# ── Julia Kernel（IJulia；確保安裝 kernelspec） ──────────────────────────
ENV JULIA_VERSION=1.11.1
RUN set -eux; \
    mkdir -p /opt/julia && cd /opt/julia; \
    curl -fsSLo julia.txz https://julialang-s3.julialang.org/bin/linux/x64/1.11/julia-1.11.1-linux-x86_64.tar.xz || exit 0; \
    if [ -f julia.txz ]; then \
      tar -xJf julia.txz --strip-components=1; \
      ln -s /opt/julia/bin/julia /usr/local/bin/julia; \
      julia -e 'using Pkg; Pkg.add(["IJulia","DataFrames","Plots"]); using IJulia; IJulia.install()'; \
    else echo '[WARN] Julia download failed, skipping'; fi

# ── JavaScript Kernel（IJavascript） ─────────────────────────────────────
RUN npm install -g ijavascript && ijsinstall --install=global || echo '[WARN] IJavascript skipped'

# ── Go Kernel（gophernotes） ────────────────────────────────────────────
RUN set -eux; \
    export GOPATH=/root/go; export GOBIN=/usr/local/bin; \
    (go install github.com/gopherdata/gophernotes@latest && \
     mkdir -p /usr/local/share/jupyter/kernels/gophernotes && \
     cp -r $GOPATH/pkg/mod/github.com/gopherdata/gophernotes@*/assets/* /usr/local/share/jupyter/kernels/gophernotes/ && \
     sed -i 's|/gophernotes|/usr/local/bin/gophernotes|g' /usr/local/share/jupyter/kernels/gophernotes/kernel.json && \
     echo '[OK] gophernotes installed') || echo '[WARN] gophernotes skipped'

# ── Rust Kernel（evcxr_jupyter） ─────────────────────────────────────────
ENV RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo PATH=/opt/rust/cargo/bin:$PATH
RUN (curl -fsSL https://sh.rustup.rs | sh -s -- -y && \
     chmod -R a+rx /opt/rust && \
     cargo install evcxr_jupyter && \
     evcxr_jupyter --install --sys-prefix && \
     echo '[OK] evcxr_jupyter installed') || echo '[WARN] evcxr_jupyter skipped'

# ── .NET Interactive（C# / F# / PowerShell） ─────────────────────────────
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
RUN (wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/msprod.deb && \
     dpkg -i /tmp/msprod.deb && rm /tmp/msprod.deb && \
     apt-get update && apt-get install -y --no-install-recommends dotnet-sdk-8.0 && \
     dotnet tool install Microsoft.dotnet-interactive --tool-path /usr/local/bin && \
     /usr/local/bin/dotnet-interactive jupyter install --path /usr/local/share/jupyter/kernels && \
     echo '[OK] dotnet-interactive installed') || echo '[WARN] dotnet-interactive skipped'

# ── Scala Kernel（Almond；需 Java） ──────────────────────────────────────
RUN (curl -fsSL https://git.io/coursier-cli -o /usr/local/bin/cs && chmod +x /usr/local/bin/cs && \
     cs launch --fork almond --scala 2.13.14 -- --install --global && \
     echo '[OK] almond installed') || echo '[WARN] almond (Scala) skipped'

# ── 預設環境變數 ────────────────────────────────────────────────────────
ENV JUPYTER_ENABLE_LAB=1 \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    SHELL=/bin/bash \
    TERM=xterm-256color \
    NCCL_DEBUG=INFO \
    UCX_TLS=tcp,sm,self,cuda_copy,cuda_ipc

# ── Add our GPU detection script ────────────────────────────────────────
COPY fix_cpu_mode.py /usr/local/bin/fix_cpu_mode.py
RUN chmod +x /usr/local/bin/fix_cpu_mode.py

# ── Custom startup script to handle CPU/GPU mode ────────────────────────
RUN cat <<'EOF' >/usr/local/bin/start-singleuser.sh
#!/bin/bash
set -euo pipefail

is_path_mounted() {
  local path="$1"
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$path" >/dev/null 2>&1 && return 0
    return 1
  fi
  grep -qs " $path " /proc/self/mountinfo && return 0
  return 1
}

dir_has_content() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local contents
  contents="$(ls -A "$dir" 2>/dev/null || true)"
  [[ -n "$contents" ]]
}

setup_workspace_links() {
  local mount_path="/workspace/storage"
  mkdir -p "${mount_path}"
  echo "[startup] Storage mount path: ${mount_path}"
}

setup_workspace_links

echo "[startup] Detecting GPU availability和調整 CUDA 環境..."

# Initialize NVIDIA environment properly
if [[ -f /usr/local/bin/nvidia_entrypoint.sh ]]; then
  echo "[startup] Initializing NVIDIA environment..."
  source /usr/local/bin/nvidia_entrypoint.sh || true
fi

# Check if we're in a GPU-enabled container
if [[ "${NVIDIA_VISIBLE_DEVICES:-}" != "" && "${NVIDIA_VISIBLE_DEVICES:-}" != "void" && "${NVIDIA_VISIBLE_DEVICES:-}" != "none" ]]; then
  echo "[startup] GPU-enabled container detected with NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-}"
  
  # Ensure CUDA libraries are properly linked
  cuda_root="${CUDA_HOME:-/usr/local/cuda}"
  declare -a path_candidates=(
    "/usr/local/nvidia/lib64"
    "/usr/local/nvidia/lib"
    "/usr/lib/wsl/lib"
    "${CUDA_COMPAT_PATH:-}"
    "${cuda_root}/compat/lib.real"
    "${cuda_root}/compat"
  )

  declare -a cuda_paths=()
  for candidate in "${path_candidates[@]}"; do
    [[ -z "${candidate}" ]] && continue
    if [[ -d "${candidate}" ]] && compgen -G "${candidate}/libcuda.so*" >/dev/null; then
      cuda_paths+=("${candidate}")
    fi
  done

  if (( ${#cuda_paths[@]} )); then
    unique_paths=()
    declare -A seen=()
    for p in "${cuda_paths[@]}"; do
      [[ -n "${seen[$p]:-}" ]] && continue
      unique_paths+=("$p")
      seen["$p"]=1
    done
    joined=$(IFS=:; echo "${unique_paths[*]}")
    first_path="${unique_paths[0]}"
    extra_cuda="/usr/local/cuda/lib64:/usr/local/cuda/lib:/usr/local/cuda/compat/lib"
    base_libs="${joined}:${extra_cuda}:/usr/local/lib/python3.10/dist-packages/torch/lib:/usr/local/nvidia/lib:/usr/local/nvidia/lib64"
    existing="${LD_LIBRARY_PATH:-}"
    cleaned=$(printf '%s\n' "${existing}" | tr ':' '\n' | grep -v '^/opt/hpcx' | grep -v '^$' | paste -sd:)
    if [[ -n "${cleaned}" ]]; then
      export LD_LIBRARY_PATH="${base_libs}:${cleaned}"
    else
      export LD_LIBRARY_PATH="${base_libs}"
    fi
    export CUDA_COMPAT_PATH="${first_path}"
    echo "[startup] 已設定 CUDA library 路徑：${joined}"
  else
    echo "[startup] 未額外調整 CUDA library 路徑。"
  fi
  
  # Set PyTorch CUDA allocation config
  export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
  unset PYTORCH_ENABLE_MPS_FALLBACK || true
  
  echo "[startup] GPU environment configured successfully."
else
  echo "[startup] CPU-only container detected."
  # Disable CUDA for CPU mode
  export CUDA_VISIBLE_DEVICES="-1"
  export NVIDIA_VISIBLE_DEVICES="void"
  export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"
  unset PYTORCH_CUDA_ALLOC_CONF || true
  echo "[startup] Disabled GPU access for CPU mode."
fi

echo "[startup] Environment variables:"
echo "  CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-unset}"
echo "  NVIDIA_VISIBLE_DEVICES: ${NVIDIA_VISIBLE_DEVICES:-unset}"
echo "  LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-unset}"

echo "[startup] Starting JupyterHub singleuser server..."
exec jupyterhub-singleuser --ip=0.0.0.0 --port=8888 "$@"
EOF
RUN chmod +x /usr/local/bin/start-singleuser.sh

# ── 修正 HOME 權限（建置期間以 root 執行 jupyter/npm/go 等可能寫入 $HOME，導致 /home/jovyan 內出現 root-owned 目錄，進而讓單人伺服器無法建立 runtime dir 而 CrashLoopBackOff） ──
RUN set -eux; \
    mkdir -p "${HOME}/.local/share/jupyter/runtime"; \
    chown -R "${NB_UID}:${NB_GID}" "${HOME}"; \
    chmod -R g+rwX "${HOME}" || true; \
    find "${HOME}" -type d -exec chmod g+s {} \; || true

EXPOSE 8888

# ── 以非 root 身分執行，並用 tini 作為 ENTRYPOINT ─────────────────────
USER ${NB_UID}
ENTRYPOINT ["tini","-g","--"]
CMD ["/usr/local/bin/start-singleuser.sh"]

WORKDIR /workspace
