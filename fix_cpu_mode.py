#!/usr/bin/env python3
"""
Script to detect GPU availability and set appropriate environment variables
for PyTorch applications to run correctly in both CPU and GPU modes.
"""

import os
import subprocess
import sys

def detect_gpus():
    """Detect available GPUs using nvidia-smi."""
    try:
        # Try to run nvidia-smi to check for GPUs
        result = subprocess.run(['nvidia-smi', '--query-gpu=count', '--format=csv,noheader'], 
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=10)
        if result.returncode == 0 and result.stdout.strip():
            gpu_count = int(result.stdout.strip())
            return gpu_count
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, ValueError, FileNotFoundError):
        pass
    return 0

def set_pytorch_env_vars(gpu_count):
    """Set environment variables based on GPU availability."""
    if gpu_count > 0:
        print(f"Detected {gpu_count} GPU(s). Setting up for GPU mode.")
        # Enable CUDA
        os.environ['CUDA_VISIBLE_DEVICES'] = ','.join(str(i) for i in range(gpu_count))
        os.environ['PYTORCH_CUDA_ALLOC_CONF'] = 'expandable_segments:True'
    else:
        print("No GPUs detected. Setting up for CPU mode.")
        # Disable CUDA for PyTorch
        os.environ['CUDA_VISIBLE_DEVICES'] = '-1'
        # Force PyTorch to use CPU
        os.environ['PYTORCH_ENABLE_MPS_FALLBACK'] = '1'
        
def main():
    gpu_count = detect_gpus()
    set_pytorch_env_vars(gpu_count)
    
    # Print environment variables for verification
    print("\nEnvironment variables set:")
    print(f"CUDA_VISIBLE_DEVICES: {os.environ.get('CUDA_VISIBLE_DEVICES', 'Not set')}")
    if gpu_count > 0:
        print(f"PYTORCH_CUDA_ALLOC_CONF: {os.environ.get('PYTORCH_CUDA_ALLOC_CONF', 'Not set')}")

if __name__ == "__main__":
    main()
