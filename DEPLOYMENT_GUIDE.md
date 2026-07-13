# ComfyUI Kubernetes Deployment Guide

This guide documents the working deployment of ComfyUI on a MicroK8s single-node cluster with NVIDIA GPU support. All steps reflect the actual configuration used in production.

## Table of Contents

1. [System Overview](#system-overview)
2. [Prerequisites](#prerequisites)
3. [Storage Setup](#storage-setup)
4. [Building and Pushing the Docker Image](#building-and-pushing-the-docker-image)
5. [Deploying to Kubernetes](#deploying-to-kubernetes)
6. [Verifying the Deployment](#verifying-the-deployment)
7. [Model Management](#model-management)
8. [Updating ComfyUI](#updating-comfyui)
9. [Troubleshooting](#troubleshooting)

---

## System Overview

**Hardware**
- CPU: Multi-core (8 CPUs allocated to pod)
- RAM: 192GB system RAM (96Gi memory limit per pod)
- GPU: NVIDIA GPU with 48GB VRAM — 1 GPU assigned to ComfyUI
- Storage: NVMe drive at `/mnt/data` (~938GB) for Docker and PVC data

**Software Stack**
- OS: Ubuntu 24.04
- Kubernetes: MicroK8s (single node)
- Container Runtime: Docker with NVIDIA container runtime
- Local Registry: `localhost:32000` (MicroK8s built-in)
- Namespace: `comfyui`
- ComfyUI: v0.7.0

**Manifest Files**

| File | Purpose |
|------|---------|
| `k8s/deployment-gpu.yaml` | Active GPU deployment (use this one) |
| `k8s/service.yaml` | LoadBalancer service on port 8188 |
| `k8s/pvc.yaml` | Four PersistentVolumeClaims for storage |
| `k8s/hpa.yaml` | HorizontalPodAutoscaler (capped at 1 replica) |

> **Note:** `k8s/deployment.yaml` exists but is not applied. The active deployment is `comfyui-gpu` from `deployment-gpu.yaml`.

---

## Prerequisites

### MicroK8s Add-ons

The following MicroK8s add-ons must be enabled:

```bash
microk8s enable dns
microk8s enable registry        # local registry at localhost:32000
microk8s enable storage         # microk8s-hostpath storage class
microk8s enable gpu             # NVIDIA GPU operator
```

Verify GPU operator is running:

```bash
microk8s kubectl get pods -n gpu-operator-resources
```

### Docker with NVIDIA Runtime

`/etc/docker/daemon.json` must configure the NVIDIA runtime and point Docker's data-root to the NVMe drive:

```json
{
  "data-root": "/mnt/data/docker",
  "runtimes": {
    "nvidia": {
      "args": [],
      "path": "nvidia-container-runtime"
    }
  }
}
```

After editing, restart Docker:

```bash
sudo systemctl restart docker
```

### Verify GPU Access

```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi
```

---

## Storage Setup

### NVMe Drive for Docker and PVC Data

Docker images and MicroK8s PVC data are stored on `/dev/nvme1n1` mounted at `/mnt/data`. To set this up from scratch:

```bash
# Format the drive
sudo mkfs.ext4 -L data /dev/nvme1n1

# Create mount point and mount
sudo mkdir -p /mnt/data
sudo mount /dev/nvme1n1 /mnt/data

# Add to /etc/fstab for persistence
echo "LABEL=data /mnt/data ext4 defaults 0 2" | sudo tee -a /etc/fstab
```

Redirect MicroK8s PVC storage to the NVMe drive:

```bash
sudo mkdir -p /mnt/data/microk8s-storage
sudo ln -s /mnt/data/microk8s-storage /var/snap/microk8s/common/default-storage
```

### PersistentVolumeClaims

The four PVCs are defined in `k8s/pvc.yaml`:

| PVC Name | Mount Path in Pod | Size | Purpose |
|----------|------------------|------|---------|
| `comfyui-models-pvc` | `/app/models` | 200Gi | Model checkpoints |
| `comfyui-web-pvc` | `/app/comfyui/web` | 10Gi | Web assets |
| `comfyui-temp-pvc` | `/app/temp` | 20Gi | Temporary files |
| `comfyui-extra-model-paths-pvc` | `/app/comfyui/extra_model_paths` | 300Gi | Additional model paths |

> **Critical:** The models PVC must mount at `/app/models` — this is ComfyUI's default `models_dir`. Mounting at `/app/comfyui/models` will result in models not being found.

Apply the PVCs:

```bash
microk8s kubectl apply -f k8s/pvc.yaml
microk8s kubectl get pvc -n comfyui
```

All PVCs should show `Bound` status.

---

## Building and Pushing the Docker Image

### Prerequisites

The ComfyUI source lives at the repo root (this is a fork of ComfyUI). The `.dockerignore` excludes large runtime directories so models are not baked into the image:

```
models/
input/
output/
temp/
```

`custom_nodes/` is intentionally **not** excluded — it must be baked into the image.

### Build

```bash
docker build -t localhost:32000/comfyui:latest .
```

The image is built on `nvidia/cuda:12.8.0-cudnn-runtime-ubuntu22.04` with PyTorch installed for CUDA 12.8:

```bash
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
```

Expected image size: ~12-13GB (without models).

### Push to Local Registry

```bash
docker push localhost:32000/comfyui:latest
```

If the push fails with a 500 error after storage migration, restart the registry pod:

```bash
microk8s kubectl rollout restart deployment/registry -n container-registry
```

---

## Deploying to Kubernetes

### Create the Namespace

```bash
microk8s kubectl create namespace comfyui
```

### Apply All Manifests

```bash
microk8s kubectl apply -f k8s/pvc.yaml
microk8s kubectl apply -f k8s/deployment-gpu.yaml
microk8s kubectl apply -f k8s/service.yaml
microk8s kubectl apply -f k8s/hpa.yaml
```

### Key Deployment Configuration

**Node selector** — must match the label your GPU node actually has:

```yaml
nodeSelector:
  nvidia.com/gpu.present: "true"
```

Verify your node's GPU label:

```bash
microk8s kubectl get nodes --show-labels | grep nvidia
```

**Resource limits** — sized for large models (e.g., 42GB Qwen models load through system RAM):

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
    memory: "96Gi"
    cpu: "8"
  requests:
    nvidia.com/gpu: 1
    memory: "32Gi"
    cpu: "2"
```

**HPA** — capped at `maxReplicas: 1` because only one GPU is available for ComfyUI. Setting it higher causes phantom pending pods that can never be scheduled.

---

## Verifying the Deployment

```bash
# Check pod is running
microk8s kubectl get pods -n comfyui

# Check service and get external IP
microk8s kubectl get svc -n comfyui

# Check endpoints (must be non-empty)
microk8s kubectl get endpoints comfyui -n comfyui

# Tail logs
microk8s kubectl logs -f -n comfyui -l app=comfyui-gpu
```

ComfyUI is accessible at `http://<LoadBalancer-IP>:8188` (currently `http://192.168.86.15:8188`).

The health check hits `/system_stats`. Wait ~60 seconds after pod start before the health check passes.

---

## Model Management

### Where Models Live on the Host

MicroK8s PVC data lives under:

```
/mnt/data/microk8s-storage/comfyui-comfyui-models-pvc-pvc-<uuid>/
```

This directory maps to `/app/models` inside the pod. Files placed here are immediately visible to the running pod — no restart required.

### Downloading a Model Directly to the PVC

Find the PVC host path:

```bash
sudo ls /mnt/data/microk8s-storage/ | grep models
```

Then download directly into the appropriate subdirectory:

```bash
PVC_PATH="/mnt/data/microk8s-storage/comfyui-comfyui-models-pvc-pvc-<uuid>"

# Example: download a ControlNet model
sudo wget -P "$PVC_PATH/model_patches/" \
  https://huggingface.co/alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union/resolve/main/Z-Image-Turbo-Fun-Controlnet-Union.safetensors
```

### Copying Models from Another Location

```bash
PVC_PATH="/mnt/data/microk8s-storage/comfyui-comfyui-models-pvc-pvc-<uuid>"

sudo rsync -av --progress /path/to/local/models/ "$PVC_PATH/"
```

### Standard Model Subdirectories

ComfyUI expects models organized under `/app/models/`:

```
checkpoints/         - Main diffusion model checkpoints (.safetensors, .ckpt)
clip/                - CLIP text encoders
vae/                 - VAE models
loras/               - LoRA weights
controlnet/          - ControlNet models
model_patches/       - Model patches (e.g., ControlNet Union)
unet/                - UNet-only models
upscale_models/      - Upscaler models
frame_interpolation/ - RIFE/FILM checkpoints for the core FrameInterpolate node (ComfyUI >= 0.20.0)
```

### Frame Interpolation (RIFE) Models

The core `FrameInterpolationModelLoader`/`FrameInterpolate` nodes (added in ComfyUI 0.20.0) load
checkpoints from `frame_interpolation/`. **Only the RIFE 4.25/4.26 architecture is supported**
(feature-encode head + 5 refinement blocks): `rife426.pth` works; `rife47.pth`/`rife49.pth` fail
with `KeyError: encode.cnn3.weight` and `rife417.pth` with "expected 5 blocks, found 4".
Working download source: `https://github.com/Fannovel16/ComfyUI-Frame-Interpolation/releases/download/models/rife426.pth`
(the styler00dollar release URLs referenced elsewhere now 404).

Copy into the PVC through the running pod — `folder_paths` picks it up live, no restart needed:

```bash
POD=$(microk8s kubectl get pods -n comfyui --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}')
microk8s kubectl exec -n comfyui $POD -- mkdir -p /app/models/frame_interpolation
microk8s kubectl cp rife426.pth comfyui/$POD:/app/models/frame_interpolation/rife426.pth
```

---

## Updating ComfyUI

### Version Upgrade from the Fork (proven 0.18.1 → 0.27.0, 2026-07-12)

This repo is a fork clone carrying three local commits (Dockerfile, `k8s/` manifests, this guide)
on top of upstream. To move to a new upstream version: sync the fork on GitHub first, then:

```bash
# Make sure nothing is generating
curl -s http://<comfyui-ip>:8188/queue   # queue_running/queue_pending should be empty

# Rebase local deployment commits onto the synced fork (purely additive files — rebases clean)
git fetch origin
git rebase origin/master

# Preserve a rollback tag for the currently-running image
docker tag localhost:32000/comfyui:latest localhost:32000/comfyui:v<old-version>
docker push localhost:32000/comfyui:v<old-version>
```

### Rebuild and Redeploy

```bash
# Build new image (version tag + latest)
docker build -t localhost:32000/comfyui:v<new-version> -t localhost:32000/comfyui:latest .

# Push to registry
docker push localhost:32000/comfyui:v<new-version>
docker push localhost:32000/comfyui:latest

# Trigger rolling update
microk8s kubectl rollout restart deployment/comfyui-gpu -n comfyui

# Watch progress
microk8s kubectl rollout status deployment/comfyui-gpu -n comfyui
```

### Verify After Upgrade

```bash
# Version actually running
curl -s http://<comfyui-ip>:8188/system_stats | jq .system.comfyui_version

# Node classes your workflows depend on still exist (spot-check /object_info)
curl -s http://<comfyui-ip>:8188/object_info | jq 'keys | length'
```

Then run a real generation through whatever client normally drives this instance —
node classes existing is necessary but not sufficient.

### GPU Contention During Rolling Updates

A pod in `CrashLoopBackOff` continues to hold its GPU reservation. During rolling updates, the new pod may stay `Pending` because the crashing old pod won't release the GPU.

**Fix:** Manually delete the old pod to free the GPU:

```bash
microk8s kubectl delete pod -n comfyui <old-pod-name>
```

The deployment will automatically create a replacement once the GPU is free.

---

## Troubleshooting

### Dead Pods Accumulating (`ContainerStatusUnknown`)

The NVIDIA device plugin on this node cycles periodically (display/compute contention XIDs on
the display GPU); each cycle can kill the running ComfyUI pod, and Kubernetes never
garbage-collects dead Deployment pods — they pile up at roughly one per day. Cleanup:

```bash
microk8s kubectl delete pods -n comfyui --field-selector status.phase=Failed
```

The field selector cannot match the Running pod, so this is always safe. The long-term fix is
DRA (GPU selection by UUID, pinning workloads to the non-display GPU); `FAIL_ON_INIT_ERROR=false`
on the device plugin (already applied via ClusterPolicy) reduces but does not eliminate the churn.

### Pod Stuck in Pending

```bash
microk8s kubectl describe pod -n comfyui <pod-name>
```

Common causes:
- **No GPU available**: Another pod (or a CrashLoopBackOff pod) holds the GPU. Delete it.
- **PVC not bound**: Check `microk8s kubectl get pvc -n comfyui`. If `Pending`, check storage class.
- **Wrong node selector**: Run `microk8s kubectl get nodes --show-labels` and confirm `nvidia.com/gpu.present=true` is present.

### OOMKilled (Exit Code 137)

The pod ran out of memory. Large models (e.g., 42GB Qwen) load through system RAM before being transferred to VRAM. Increase the memory limit in `deployment-gpu.yaml`:

```yaml
limits:
  memory: "96Gi"   # raise as needed
```

### Models Not Found in ComfyUI

Verify the models PVC is mounted at `/app/models` (not `/app/comfyui/models`):

```bash
microk8s kubectl exec -n comfyui <pod-name> -- python -c \
  "import folder_paths; print(folder_paths.models_dir)"
# Should print: /app/models
```

If wrong, fix the `volumeMounts` in `deployment-gpu.yaml` and redeploy.

### Service Has No Endpoints

```bash
microk8s kubectl get endpoints comfyui -n comfyui
```

If `<none>`, the service selector doesn't match the pod labels. The service selector must be `app: comfyui-gpu` to match pods from `deployment-gpu.yaml`.

### Registry Push Fails (500 Error)

The registry pod may have stale state after storage path changes:

```bash
microk8s kubectl rollout restart deployment/registry -n container-registry
```

### GPU Not Detected in Container

```bash
microk8s kubectl exec -n comfyui <pod-name> -- nvidia-smi
```

If this fails, verify the GPU operator pods are running:

```bash
microk8s kubectl get pods -n gpu-operator-resources
```

And confirm the Docker daemon uses the nvidia runtime (`/etc/docker/daemon.json`).

### Check Logs

```bash
# Current logs
microk8s kubectl logs -n comfyui -l app=comfyui-gpu --tail=100

# Logs from previous crashed container
microk8s kubectl logs -n comfyui <pod-name> --previous
```

---

## Cleanup

```bash
# Remove all ComfyUI resources (preserves PVC data)
microk8s kubectl delete deployment comfyui-gpu -n comfyui
microk8s kubectl delete svc comfyui -n comfyui
microk8s kubectl delete hpa comfyui-hpa -n comfyui

# Remove PVCs (destructive — deletes all model data)
microk8s kubectl delete pvc -n comfyui --all

# Remove namespace entirely
microk8s kubectl delete namespace comfyui
```

---

**Last Updated**: March 2026
**ComfyUI Version**: v0.7.0
**CUDA Version**: 12.8
**PyTorch**: cu128 wheels
