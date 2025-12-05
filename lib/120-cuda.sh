# ---------- CUDA 冒煙測試（可略過） ----------
deploy_cuda_smoketest(){
  if ! CTR images ls | awk '{print $1}' | grep -q 'nvidia/cuda:12.4.1-base-ubuntu22.04'; then
    warn "[cuda] 未發現已側載的 nvidia/cuda:12.4.1-base-ubuntu22.04，略過冒煙測試"
    return 0
  fi
  cat <<'YAML' | KCTL apply -f -
apiVersion: v1
kind: Pod
metadata: { name: cuda-test }
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  containers:
  - name: cuda
    image: nvidia/cuda:12.4.1-base-ubuntu22.04
    command: ["bash","-lc","nvidia-smi && sleep 1"]
    resources: { limits: { nvidia.com/gpu: 1 } }
YAML
  for _ in {1..40}; do KCTL logs pod/cuda-test >/dev/null 2>&1 && break || true; sleep 3; done
  KCTL logs pod/cuda-test || true
  KCTL delete pod cuda-test --ignore-not-found
}

