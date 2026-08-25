# GPU node on K3s — bare metal to a CI/CD-deployed GPU app

Adds a GPU worker to a K3s cluster, makes the GPU schedulable, and ships a GPU
workload onto it through Jenkins → registry → GitOps → Argo CD.

**Covers NVIDIA, AMD and Intel in one linear pass.** The six layers are identical
for all three; only six of the twenty-two steps differ, and at each of those you
will find one block per vendor — read only yours.
[§0.4](#04-where-the-vendor-paths-diverge) maps exactly where that happens.

Pick **one** vendor per node. Budget ~45 minutes and one reboot for Parts 1–4.

### Related docs

| Doc | Covers |
|---|---|
| **this doc** | K3s: GPU node end to end, including CI/CD |
| [abc_local_setup/gpu-node-setup.md](../abc_local_setup/gpu-node-setup.md) | The same host prep for **kubeadm** (own containerd, CNI, swap, sysctl) |
| [abc_local_setup/local-kind-setup.md](../abc_local_setup/local-kind-setup.md) | Cluster-side platform: Argo CD, Rollouts, Kyverno, ingress |

K3s bundles containerd, CNI and a scheduler, so this doc skips the `SystemdCgroup`,
`br_netfilter` and CNI work the kubeadm doc needs.

---

# Part 0 — The model

## 0.1 Six layers, each invisible until the one below works

Almost every "the GPU doesn't show up" is someone debugging layer 5 with layer 2
broken. Never skip a proof — a layer-1 failure resurfaces three steps later
wearing a completely different error.

| # | Layer | Lives | Proof it works | Step |
|---|---|---|---|---|
| 1 | GPU kernel driver | host | vendor CLI works on the host | [3](#3-verify-the-driver-and-harden--layer-1) |
| 2 | Runtime wiring | host | device files reach containers | [4](#4-wire-the-gpu-into-the-container-runtime--layer-2) |
| 3 | Container runtime | host | vendor CLI works **inside a pod** | [11](#11-smoke-test-the-gpu--layer-3) |
| 4 | K3s agent joined | host | `kubectl get nodes` → `Ready` | [7](#7-verify-the-node--layer-4) |
| 5 | Device plugin | cluster | GPU resource in node allocatable | [10](#10-verify-the-gpu-resource--layer-5) |
| 6 | Workload requests one | cluster | pod `Running`, not `Pending` | [12](#12-what-a-gpu-pod-needs) |

The line that ties it together: **the driver makes the GPU work on the host, the
runtime wiring makes it visible to containers, the device plugin makes it visible
to the scheduler.** Three different problems that all look like "the GPU doesn't
work".

## 0.2 Where each piece lives

```text
  ┌─────────────────────── K3s control plane ───────────────────────┐
  │  kubectl · helm · Jenkins · Argo CD                             │
  └────────────────────────────┬────────────────────────────────────┘
                               │ Kubernetes API
  ┌────────────────────────────┴────────────────────────────────────┐
  │                    GPU worker · Ubuntu 22.04/24.04              │
  │                                                                 │
  │  L6  AI pod      PyTorch / vLLM / CUDA·ROCm·oneAPI    ← container│
  │      ▲                                                          │
  │  L5  device plugin   advertises <vendor>/gpu          ← DaemonSet│
  │      ▲                                                          │
  │  L4  k3s-agent       kubelet + bundled containerd     ← host     │
  │      ▲                                                          │
  │  L3  runtime         injects device files + libs      ← host     │
  │      ▲                                                          │
  │  L2  toolkit / device files                           ← host     │
  │      ▲                                                          │
  │  L1  GPU kernel driver   nvidia · amdgpu · i915/xe     ← host     │
  │      ▲                                                          │
  │  L0  Physical GPU                                               │
  └─────────────────────────────────────────────────────────────────┘
```

**Keep the host minimal.** Host gets: kernel, GPU driver, runtime wiring,
k3s-agent. Everything else — CUDA, ROCm, oneAPI, PyTorch, TensorFlow, vLLM,
Transformers, ONNX Runtime — ships **inside the image**.

The host driver supplies the kernel interface; the container supplies the
userspace. That is why one node runs a CUDA 12.4 pod and a CUDA 12.8 pod side by
side, and why installing PyTorch on the host buys nothing.

## 0.3 The naming contract

Fixed for the rest of this doc. These exact names are what
[`helm/values.yaml`](../helm/values.yaml) already ships, so
guide and chart agree.

| | NVIDIA | AMD | Intel |
|---|---|---|---|
| Kernel driver | `nvidia` (out-of-tree) | `amdgpu` (in-tree) | `i915` / `xe` (in-tree) |
| Host CLI | `nvidia-smi` | `rocm-smi`, `rocminfo` | `intel_gpu_top`, `clinfo` |
| Device files | `/dev/nvidia*` | `/dev/kfd`, `/dev/dri` | `/dev/dri` |
| Resource in `limits` | `nvidia.com/gpu` | `amd.com/gpu` | `gpu.intel.com/i915` or `/xe` |
| Auto label (GFD / NFD) | `nvidia.com/gpu.present=true` | `feature.node.kubernetes.io/amd-gpu=true` | `gpu.intel.com/i915=true` |
| Manual label (always safe) | `gpu.vendor=nvidia` | `gpu.vendor=amd` | `gpu.vendor=intel` |
| Taint | `nvidia.com/gpu=present:NoSchedule` | `amd.com/gpu=present:NoSchedule` | `gpu.intel.com/i915=present:NoSchedule` |
| Toleration key | `nvidia.com/gpu` | `amd.com/gpu` | `gpu.intel.com/i915` |
| `runtimeClassName` needed? | **yes** on K3s | no | no |

> **Use the vendor-prefixed taint key, not a custom one like `accelerator`.**
> This is the highest-value line in the doc. The NVIDIA GPU Operator's own
> DaemonSets — device plugin, DCGM exporter, GPU Feature Discovery, validator —
> ship exactly one default toleration:
>
> ```yaml
> tolerations:
>   - key: nvidia.com/gpu
>     operator: Exists
>     effect: NoSchedule
> ```
>
> Taint the node `accelerator=nvidia:NoSchedule` and **none of them schedule**.
> The Operator installs "successfully", its pods sit `Pending`, `nvidia.com/gpu`
> never appears, and every symptom points at layer 5 while the actual cause is a
> string mismatch in a taint. Matching the convention makes it work with zero
> extra flags. If you must use a custom key, you have to pass
> `--set-json 'daemonsets.tolerations=[…]'` to every chart involved.

## 0.4 Where the vendor paths diverge

Read this table once and you know the shape of the whole doc. **Six steps have
per-vendor blocks; the other sixteen are the same for everyone.**

| Step | | Why |
|---|---|---|
| [1](#1-detect-the-gpu-and-check-secure-boot) Detect GPU | shared | one `lspci`, different grep |
| [2](#2-install-the-gpu-driver--layer-1) **Install driver** | **per vendor** | three unrelated install paths |
| [3](#3-verify-the-driver-and-harden--layer-1) **Verify driver** | **per vendor** | different CLI, different device files |
| [4](#4-wire-the-gpu-into-the-container-runtime--layer-2) **Runtime wiring** | **per vendor** | only NVIDIA needs a toolkit at all |
| [5](#5-install-the-k3s-agent--layer-4) Join K3s | shared | K3s does not care which GPU |
| [6](#6-verify-the-runtime-registration--layer-23) Verify runtime | NVIDIA only | others have no runtime to register |
| [7](#7-verify-the-node--layer-4) Node `Ready` | shared | |
| [8](#8-label-and-taint-the-node) Label + taint | shared | same commands, strings from [§0.3](#03-the-naming-contract) |
| [9](#9-install-the-device-plugin--layer-5) **Device plugin** | **per vendor** | three different projects |
| [10](#10-verify-the-gpu-resource--layer-5) Verify resource | shared | same command, resource name varies |
| [11](#11-smoke-test-the-gpu--layer-3) **Smoke test** | **per vendor** | different image and CLI |
| [12](#12-what-a-gpu-pod-needs) Pod requirements | shared | identical mechanics |
| [13](#13-the-container-image-contract) **Image contract** | **per vendor** | CUDA / ROCm / oneAPI |
| [14](#14-sharing-one-gpu) Sharing a GPU | per vendor | NVIDIA has the most options |
| [15](#15-the-flow)–[20](#20-verify-the-deploy-landed-on-the-gpu) CI/CD | shared | pipeline never touches a GPU |
| [21](#21-monitoring) Monitoring | shared | different exporter per vendor |
| [22](#22-day-2) Day-2 | shared | |

**Shortest correct path if your GPU is NVIDIA:** steps 1→2→3→4→5→6→7→8→9→10→11,
then Part 5. AMD and Intel skip step 6 and have less to do in step 4.

---

# Part 1 — Host: make the GPU work on the node

Run everything in Part 1 **on the GPU worker**, over SSH.

## 1. Detect the GPU and check Secure Boot

```sh
lspci -nn | grep -Ei 'vga|3d|display'
. /etc/os-release && echo "$PRETTY_NAME"; uname -r
mokutil --sb-state 2>/dev/null || echo "no mokutil (BIOS/legacy boot)"
```

No output from `lspci` means the card is not seated, not powered, or disabled in
the BIOS. No amount of `apt install` fixes that.

Install the build prerequisites now — all three vendors need headers for the
running kernel:

```sh
sudo apt-get update
sudo apt-get install -y build-essential dkms "linux-headers-$(uname -r)" \
                        curl ca-certificates gnupg pciutils
```

`$(uname -r)` pins headers to the **running** kernel. If apt upgraded the kernel
and you have not rebooted, that is the wrong version and any DKMS build fails with
*"Your kernel headers cannot be found"* — reboot first.

> **`SecureBoot enabled` is the ambush — NVIDIA and AMD only.** Both build an
> out-of-tree module via DKMS, and it will not load unsigned. The install looks
> clean, then after the reboot the vendor CLI reports *"couldn't communicate with
> the driver"*. Intel's `i915`/`xe` are in-tree and already signed, so Intel is
> unaffected.
>
> Decide **now**, not after the reboot:
> - **Disable Secure Boot in the BIOS** — simplest.
> - **Enroll a MOK key** — the driver install prompts for a one-time password and
>   the next boot stops at a blue *Enroll MOK* screen. That screen is **pre-OS, so
>   it is invisible over SSH**; a headless box hangs there until someone reaches it
>   with IPMI or a KVM.

## 2. Install the GPU driver — layer 1

> **Do only your vendor's block.**

### NVIDIA

```sh
sudo apt-get install -y ubuntu-drivers-common
ubuntu-drivers devices          # note the line marked `recommended`
sudo ubuntu-drivers install --gpgpu
```

`--gpgpu` is the headless/compute install: no X11, no desktop packages.

Now the step everyone misses. `--gpgpu` does **not** install `nvidia-smi`, so you
end up with a working driver and no way to look at it:

```sh
BRANCH=$(ubuntu-drivers devices | awk '/recommended/{print $3}' | grep -oE '[0-9]+' | head -1)
sudo apt-get install -y "nvidia-utils-${BRANCH}-server"
```

<details>
<summary>Need a newer driver than Ubuntu ships? Use NVIDIA's repo instead</summary>

Do **not** mix this with the commands above — the two package the same driver
under different names and apt cannot resolve the conflict.

```sh
. /etc/os-release
distro="ubuntu$(echo "$VERSION_ID" | tr -d '.')"   # ubuntu2404 / ubuntu2204
arch=$(uname -m)                                    # x86_64 / sbsa

curl -fsSLO "https://developer.download.nvidia.com/compute/cuda/repos/${distro}/${arch}/cuda-keyring_1.1-1_all.deb"
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get install -y nvidia-open      # Turing and newer
# pre-Turing: sudo apt-get install -y cuda-drivers
```

The CUDA **toolkit** on the host is not needed for Kubernetes and costs several
GB. Containers ship their own CUDA userspace; the host only supplies the driver.

</details>

### AMD

`amdgpu` ships in-tree, but the in-tree module alone gives you display, **not
compute**. ROCm compute needs `amdgpu-dkms` plus the ROCm userspace, and the
`amdgpu-install` package is what registers AMD's repos.

Check [AMD's compatibility matrix](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/reference/system-requirements.html)
for your card and kernel **before** installing — ROCm's supported-hardware list is
much narrower than NVIDIA's, and consumer Radeon cards often need
`HSA_OVERRIDE_GFX_VERSION` set in the container to work at all.

```sh
ROCM_VER=7.2.4                                   # check repo.radeon.com for current
ROCM_PKG=7.2.4.70204-1
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")   # noble | jammy

wget "https://repo.radeon.com/amdgpu-install/${ROCM_VER}/ubuntu/${CODENAME}/amdgpu-install_${ROCM_PKG}_all.deb"
sudo apt-get install -y "./amdgpu-install_${ROCM_PKG}_all.deb"
sudo apt-get update

# kernel driver
sudo apt-get install -y "linux-modules-extra-$(uname -r)"
sudo apt-get install -y amdgpu-dkms

# ROCm userspace + device access
sudo apt-get install -y python3-setuptools python3-wheel rocm
sudo usermod -aG render,video "$LOGNAME"
```

Remove any previously installed AMD driver first — a leftover install and
`amdgpu-dkms` conflict, and the DKMS build fails in a way that reads like a kernel
problem.

`render` and `video` group membership is what grants access to `/dev/kfd` and
`/dev/dri`. It applies to the invoking user only and takes effect on next login.

### Intel

**Nothing to install for the driver.** `i915` and `xe` are in-tree, signed, and
already loaded. Install the diagnostics instead, and note **which** driver claimed
the card — that choice propagates all the way to the resource name in your pod
spec:

```sh
sudo apt-get install -y intel-gpu-tools clinfo
sudo usermod -aG render "$LOGNAME"

for f in /sys/class/drm/card*/device/uevent; do grep -H '^DRIVER=' "$f"; done
```

| Output | Cards | Resource name later |
|---|---|---|
| `DRIVER=i915` | integrated, older discrete | `gpu.intel.com/i915` |
| `DRIVER=xe` | Arc, Battlemage, newer | `gpu.intel.com/xe` |

Getting this wrong means a pod that stays `Pending` forever against a GPU that is
sitting right there, because it asks for a resource nothing advertises.

For compute you also want the OpenCL / Level Zero runtime:

```sh
sudo apt-get install -y intel-opencl-icd
```

## 3. Verify the driver and harden — layer 1

Reboot first — this is what loads the new module (and, for NVIDIA, unloads
nouveau):

```sh
sudo reboot
```

> **Do only your vendor's block. Do not continue until it passes.** Every layer
> above reads through this one.

### NVIDIA

```sh
nvidia-smi
```

Must print a table with your GPU, a driver version and a CUDA version. That CUDA
version is the **ceiling** for container images — note it for
[step 13](#13-the-container-image-contract).

```sh
lsmod | grep nouveau && echo "PROBLEM: nouveau still loaded"
```

Expect no output. Nouveau is the in-kernel open driver; it grabs the card at boot
and the NVIDIA module then cannot. The packages blacklist it automatically, so a
hit means the blacklist never reached initramfs — fix with
`sudo update-initramfs -u && sudo reboot`.

Two settings worth having on any server:

```sh
sudo nvidia-smi -pm 1                                   # persistence mode
sudo systemctl enable --now nvidia-persistenced
```

Without persistence mode every container start pays a multi-second driver init,
which surfaces in Kubernetes as random slow pod starts.

### AMD

```sh
rocminfo | head -30
rocm-smi
ls -l /dev/kfd /dev/dri/
```

`/dev/kfd` is the whole game — that is the compute interface. Missing, and ROCm
cannot see the card no matter what `lspci` or `rocm-smi` say. `rocminfo` must list
an `Agent` with your `gfx` target (e.g. `gfx1100`); note that string, since it is
what ROCm images check against.

```sh
groups | grep -E 'render|video' || echo "re-login needed for group membership"
```

### Intel

```sh
clinfo | grep -iE 'device name|driver version'
ls -l /dev/dri/
intel_gpu_top          # q to quit
```

`/dev/dri/renderD128` (and `card0`) must exist. `clinfo` reporting zero platforms
usually means `intel-opencl-icd` is missing or the user is not in `render`.

### All vendors — pin the driver

```sh
# NVIDIA
sudo apt-mark hold "$(dpkg -l | grep -oE 'nvidia-(open|driver-[0-9]+-server)' | head -1)"
# AMD
sudo apt-mark hold amdgpu-dkms rocm
```

An unattended driver upgrade with no reboot breaks every GPU container on the box
— NVIDIA reports *"Driver/library version mismatch"*, ROCm fails in `hipInit`.
Intel needs no hold; the driver moves with the kernel.

## 4. Wire the GPU into the container runtime — layer 2

The driver exposes device files to the **host**. A container is namespaced away
from them. This step is what closes that gap, and the amount of work differs
sharply by vendor.

### NVIDIA

The layer people skip, and skipping it is exactly why `nvidia-smi` works on the
host but a container sees nothing. NVIDIA needs a real runtime shim — the toolkit
injects device nodes *and* the matching driver libraries at container creation.

```sh
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

nvidia-container-runtime --version
```

> **Do this BEFORE installing k3s-agent ([step 5](#5-install-the-k3s-agent--layer-4)).**
> K3s scans `PATH` for alternative runtimes **at startup** and writes the
> containerd config from what it finds. Install the toolkit afterwards and the
> config has no `nvidia` block until K3s restarts. Either order works — the wrong
> one just costs you a `systemctl restart k3s-agent` and, if you skip that, an
> afternoon.
>
> Unlike the kubeadm path, **do not run `nvidia-ctk runtime configure`.** K3s owns
> its containerd config, regenerates it on every start, and would overwrite the
> edit.

### AMD

**Nothing to install.** ROCm needs no runtime shim: the device plugin mounts
`/dev/kfd` and `/dev/dri` into the pod, and the ROCm userspace lives in the image.
That is why AMD has no `runtimeClassName` and no equivalent of the container
toolkit.

Confirm the device files a container will receive:

```sh
ls -l /dev/kfd /dev/dri/renderD*
```

### Intel

**Nothing to install.** Same reason as AMD — the plugin mounts `/dev/dri`, and
oneAPI / Level Zero ship in the image.

```sh
ls -l /dev/dri/renderD*
```

---

# Part 2 — Join the node to K3s

## 5. Install the K3s agent — layer 4

Vendor-independent. On the **control plane**, read the node token:

```sh
sudo cat /var/lib/rancher/k3s/server/node-token
```

On the **GPU worker**:

```sh
export K3S_URL="https://<CONTROL_PLANE_IP>:6443"
export K3S_TOKEN="<NODE_TOKEN>"

curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -
```

The installer enables and starts `k3s-agent` itself. **NVIDIA only:** if the
toolkit went on after this, restart now so K3s re-scans for runtimes.

```sh
sudo systemctl restart k3s-agent
systemctl is-active k3s-agent
```

## 6. Verify the runtime registration — layer 2/3

**NVIDIA only.** AMD and Intel register no runtime — skip to
[step 7](#7-verify-the-node--layer-4).

```sh
sudo grep -A3 nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
kubectl get runtimeclass
```

The `grep` must print an `nvidia` runtime block. Empty output means K3s started
before the toolkit was installed — restart `k3s-agent` and re-check.

`kubectl get runtimeclass` should list `nvidia`. **K3s ships RuntimeClass objects
for every runtime it supports, so you do not create one** — this is the main
difference from the kubeadm path, where you either run
`nvidia-ctk runtime configure --set-as-default` or apply the RuntimeClass by hand.

> **K3s registers the NVIDIA runtime but does not make it the default.** Every GPU
> pod therefore needs `runtimeClassName: nvidia` in its spec. That is what the
> `runtimeClassName` value in [`helm/values.yaml`](../helm/values.yaml)
> is for — set it to `nvidia` on this cluster.
>
> To avoid it, start the agent with `--default-runtime nvidia` (in
> `/etc/systemd/system/k3s-agent.service.env` as
> `K3S_AGENT_ARGS="--default-runtime nvidia"`). Fine on a dedicated GPU node,
> since every container there wants the GPU runtime anyway.

## 7. Verify the node — layer 4

From the control plane:

```sh
kubectl get nodes -o wide
```

```text
NAME            STATUS   ROLES                  VERSION
k3s-master-01   Ready    control-plane,master   v1.33.x+k3s1
gpu-worker-01   Ready    <none>                 v1.33.x+k3s1
```

**Do not continue until the GPU worker is `Ready`.** K3s bundles flannel, so
unlike kubeadm there is no missing-CNI stall here; a `NotReady` node is almost
always the agent failing to reach `:6443` —
`sudo journalctl -u k3s-agent -n 100 --no-pager`.

## 8. Label and taint the node

Same two commands for every vendor; only the strings change, straight from
[§0.3](#03-the-naming-contract).

```sh
NODE=gpu-worker-01
VENDOR=nvidia                                  # nvidia | amd | intel
TAINT_KEY=nvidia.com/gpu                       # amd.com/gpu | gpu.intel.com/i915

kubectl label node "$NODE" "gpu.vendor=${VENDOR}" --overwrite
kubectl taint node  "$NODE" "${TAINT_KEY}=present:NoSchedule" --overwrite

kubectl describe node "$NODE" | grep -A3 Taints
```

- The **label** is how GPU work finds the node. `gpu.vendor` is yours and always
  present; the vendor's own feature-discovery adds richer ones later
  (`nvidia.com/gpu.product`, `.memory`, `.count`) which are better for pinning a
  model in a mixed fleet.
- The **taint** is how ordinary work stays off expensive hardware. Note the key is
  vendor-prefixed, per [§0.3](#03-the-naming-contract) — this is what lets the
  device plugin DaemonSets land here with no extra flags.

A useful side effect: your Jenkins agent pods carry no GPU toleration, so the
taint keeps CI builds off the GPU node automatically.

---

# Part 3 — Make the GPU visible to Kubernetes

The node is `Ready` and the driver works, but the scheduler still sees no GPU. A
**device plugin** is what advertises the resource into node capacity.

## 9. Install the device plugin — layer 5

> **Do only your vendor's block.** Run these from the control plane.

### NVIDIA

Two options. **The standalone plugin is the recommended K3s path** and the rest of
this doc assumes it.

| | Device plugin | GPU Operator |
|---|---|---|
| Installs | one DaemonSet | plugin + GFD + NFD + DCGM + validator + MIG manager |
| Weight | ~15 MB | several pods per node |
| K3s friction | none | needs `toolkit.enabled=false`, or containerd path overrides |
| Gives you | the resource | the resource + metrics + rich labels + MIG |
| Use when | K3s lab, single node, you want to see the moving parts | fleet, mixed GPUs, you want DCGM and MIG managed |

```sh
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

helm upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --create-namespace \
  --version 0.17.1 \
  --set runtimeClassName=nvidia \
  --set gfd.enabled=true \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

Three flags, three reasons:

- **`runtimeClassName=nvidia`** — the plugin must itself see the GPU to enumerate
  it, and on K3s the NVIDIA runtime is not the default
  ([step 6](#6-verify-the-runtime-registration--layer-23)). Omit this and the
  DaemonSet runs, logs `failed to initialize NVML: could not load NVML library`,
  and advertises nothing. Skip it only if you set `--default-runtime nvidia`.
- **`gfd.enabled=true`** — adds GPU Feature Discovery, which applies
  `nvidia.com/gpu.present`, `.product`, `.memory`, `.count` labels. Your chart's
  default `gpu.nodeSelector` uses `nvidia.com/gpu.present`, so this is what makes
  it match.
- **`tolerations`** — the chicken-and-egg from [§0.3](#03-the-naming-contract).
  The plugin has to land on the tainted node, or nothing ever advertises the
  resource. Set it explicitly rather than trusting a chart default.

```sh
kubectl -n nvidia-device-plugin get pods -o wide
kubectl -n nvidia-device-plugin logs -l app.kubernetes.io/name=nvidia-device-plugin --tail=30
```

<details id="nvidia-gpu-operator">
<summary><b>GPU Operator instead</b> — batteries included, more K3s friction</summary>

```sh
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled=false
```

**Both flags are mandatory here, and both are load-bearing:**

- `driver.enabled=false` — [step 2](#2-install-the-gpu-driver--layer-1) installed
  the driver on the host. Leave it `true` and the Operator loads a second kernel
  driver over the running one: the validator crash-loops, host `nvidia-smi` starts
  failing, and the node melts down.
- `toolkit.enabled=false` — [step 4](#4-wire-the-gpu-into-the-container-runtime--layer-2)
  installed the toolkit on the host. Leave it `true` on K3s and the Operator writes
  to `/etc/containerd/config.toml`, which K3s does not read; K3s's config lives at
  `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` with its socket at
  `/run/k3s/containerd/containerd.sock`. The result is a toolkit container that
  reports success while changing nothing.

  Managing the toolkit through the Operator anyway means overriding all of it:

  ```sh
  --set toolkit.enabled=true \
  --set toolkit.env[0].name=CONTAINERD_CONFIG \
  --set toolkit.env[0].value=/var/lib/rancher/k3s/agent/etc/containerd/config.toml \
  --set toolkit.env[1].name=CONTAINERD_SOCKET \
  --set toolkit.env[1].value=/run/k3s/containerd/containerd.sock
  ```

  Host toolkit + `toolkit.enabled=false` is simpler and is why Part 1 is ordered
  the way it is.

```sh
kubectl get pods -n gpu-operator
```

Wait for every pod `Running`/`Completed`, `nvidia-cuda-validator` included. Any
pod `Pending` here means the taint key does not match
[§0.3](#03-the-naming-contract).

</details>

### AMD

AMD ships a GPU Operator that bundles Node Feature Discovery and Kernel Module
Management. Since [step 2](#2-install-the-gpu-driver--layer-1) already installed
ROCm on the host, you want **neither** managing your driver:

```sh
helm repo add rocm https://rocm.github.io/gpu-operator
helm repo update

helm upgrade --install amd-gpu-operator rocm/gpu-operator-charts \
  --namespace kube-amd-gpu --create-namespace \
  --version=v1.5.1 \
  --set kmm.enabled=false \
  --set kmm.watch=false
```

- **`kmm.enabled=false`** — do not deploy KMM; it exists to build and load kernel
  modules, which `amdgpu-dkms` already did.
- **`kmm.watch=false`** — and do not *reconcile* KMM resources either. This is the
  documented pairing for "alternative driver management", i.e. a host-installed
  driver. `kmm.enabled=false` with `watch=true` is for reusing an **existing** KMM
  install — the wrong choice here.
- Add `--set node-feature-discovery.enabled=false` **only if NFD already runs in
  the cluster.** Two NFD instances fight over the same labels.

Then tell the operator to skip driver installation, which is AMD's equivalent of
NVIDIA's `driver.enabled=false` — and the same node-melting failure if you get it
wrong. v1.3.0+ creates a default `DeviceConfig`, so either edit that
(`kubectl edit deviceconfig -n kube-amd-gpu default`) or apply your own:

```sh
kubectl apply -f - <<'EOF'
apiVersion: amd.com/v1alpha1
kind: DeviceConfig
metadata:
  name: default
  namespace: kube-amd-gpu
spec:
  driver:
    # host already has amdgpu-dkms + ROCm — do NOT install a second one
    enable: false
  devicePlugin:
    devicePluginImage: rocm/k8s-device-plugin:latest
    nodeLabellerImage: rocm/k8s-device-plugin:labeller-latest
  metricsExporter:
    enable: true
    serviceType: NodePort
    nodePort: 32500
  selector:
    # NFD applies this. Swap for `gpu.vendor: amd` (step 8) if NFD is not running.
    feature.node.kubernetes.io/amd-gpu: "true"
EOF

kubectl get deviceconfig -n kube-amd-gpu
kubectl get pods -n kube-amd-gpu
```

With `driver.enable: false` the operator deploys only what you want: device
plugin, node labeller and metrics exporter.

### Intel

Intel's is an operator + CR, like AMD's. Node Feature Discovery is **optional
here but worth installing**: it applies the `gpu.intel.com/i915` node label, and
it is what lets you keep the vendor-neutral `nodeSelector` style the rest of this
doc uses. Skip it and fall back to the manual `gpu.vendor=intel` label from
[step 8](#8-label-and-taint-the-node).

If you do install NFD, it must come **before** the plugin, and the
`NodeFeatureRules` are a separate apply — NFD without them detects no GPU, so the
labels never appear and a label-scoped plugin schedules nothing.

```sh
# 1. NFD, then the GPU detection rules — both, and before the plugin
kubectl apply -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd?ref=main'
kubectl apply -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd/overlays/node-feature-rules?ref=main'
kubectl get pods -A | grep -i nfd

# 2. the device-plugin operator
kubectl apply -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/operator/default?ref=main'

# 3. the GPU plugin itself
kubectl apply -f - <<'EOF'
apiVersion: deviceplugin.intel.com/v1
kind: GpuDevicePlugin
metadata:
  name: gpu-plugin
spec:
  # 1 = exclusive. >1 shares one physical GPU across that many containers,
  # which is Intel's equivalent of NVIDIA time-slicing (step 14).
  sharedDevNum: 1
  nodeSelector:
    kubernetes.io/os: linux
EOF

kubectl get gpudeviceplugin
kubectl get pods -A | grep -i gpu
```

## 10. Verify the GPU resource — layer 5

Same command for everyone; substitute your resource name from
[§0.3](#03-the-naming-contract). Backslash-escape the dots — they are JSONPath
separators otherwise.

```sh
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
NVIDIA:.status.allocatable.nvidia\\.com/gpu,\
AMD:.status.allocatable.amd\\.com/gpu,\
I915:.status.allocatable.gpu\\.intel\\.com/i915,\
XE:.status.allocatable.gpu\\.intel\\.com/xe
```

```text
NAME            NVIDIA   AMD     I915    XE
gpu-worker-01   1        <none>  <none>  <none>      # 4 on a 4-GPU box
k3s-master-01   <none>   <none>  <none>  <none>
```

Exactly one column should be populated on the GPU node — and **that is the name
you put in `limits`**. All `<none>` means layer 5 is not working: the plugin is not
running, or it is running blind. Check its logs first, then re-read
[step 9](#9-install-the-device-plugin--layer-5).

## 11. Smoke test the GPU — layer 3

The whole stack in one pod. Nothing about your app is involved yet, so a failure
here is infrastructure, not code.

> **Do only your vendor's block.**

### NVIDIA

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke-test
spec:
  restartPolicy: Never
  runtimeClassName: nvidia          # K3s: required — step 6
  nodeSelector:
    gpu.vendor: nvidia
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: cuda
      image: nvidia/cuda:12.8.1-base-ubuntu24.04
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1
EOF
```

### AMD

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke-test
spec:
  restartPolicy: Never
  nodeSelector:
    gpu.vendor: amd
  tolerations:
    - key: amd.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: rocm
      image: rocm/rocm-terminal:latest
      command: ["bash", "-c", "rocm-smi && rocminfo | grep -m1 gfx"]
      resources:
        limits:
          amd.com/gpu: 1
EOF
```

No `runtimeClassName` — the plugin mounts `/dev/kfd` and `/dev/dri` directly.

### Intel

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke-test
spec:
  restartPolicy: Never
  nodeSelector:
    gpu.vendor: intel
  tolerations:
    - key: gpu.intel.com/i915
      operator: Exists
      effect: NoSchedule
  containers:
    - name: intel-gpu
      image: intel/intel-extension-for-pytorch:2.8.10-xpu
      command:
        - python3
        - -c
        - |
          import torch, intel_extension_for_pytorch
          print("xpu available:", torch.xpu.is_available())
          print("device count :", torch.xpu.device_count())
          print("device 0     :", torch.xpu.get_device_name(0))
      resources:
        limits:
          gpu.intel.com/i915: 1     # or gpu.intel.com/xe — step 2
EOF
```

Intel's device selector is `xpu`, not `cuda` — that is the whole difference in
application code.

> **Do not use `intel/opencl-icd` for this.** Intel's own docs run `clinfo` from
> that image, but it is **built from source** (`make intel-opencl-icd`) and pushed
> to your own registry — there is no such public tag, so a pod referencing it sits
> in `ImagePullBackOff` and looks like a GPU problem. The lighter official
> alternative is their prebuilt demo job:
>
> ```sh
> kubectl apply -f https://raw.githubusercontent.com/intel/intel-device-plugins-for-kubernetes/main/demo/intelgpu-job.yaml
> ```
>
> The IPEX image above is several GB but proves more: it exercises the actual
> compute path, not just device enumeration.

### All vendors — read the result

```sh
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke-test --timeout=180s
kubectl logs gpu-smoke-test
kubectl delete pod gpu-smoke-test
```

The vendor's own tool listing your GPU, printed from inside a pod, means **layers
1–6 are all working**. That is the milestone; everything after this is application
wiring.

If it stays `Pending` or `ContainerCreating`, go to
[Appendix A](#appendix-a--troubleshooting) — each failure mode maps to a layer.

---

# Part 4 — Run GPU workloads

## 12. What a GPU pod needs

Four things, identical mechanics for all three vendors. Miss any one and you get a
distinct, misleading failure:

| # | Field | Missing → |
|---|---|---|
| 1 | GPU count in `resources.limits` | pod `Running`, `torch.cuda.is_available()` is `False` |
| 2 | `nodeSelector` matching the node label | lands on a CPU node, same silent failure |
| 3 | `tolerations` matching the taint | `Pending` — *"node(s) had untolerated taint"* |
| 4 | `runtimeClassName: nvidia` — **NVIDIA on K3s only** | `Running`, no device files, CUDA init fails |

```yaml
spec:
  runtimeClassName: nvidia          # NVIDIA on K3s only; omit for AMD/Intel
  nodeSelector:
    nvidia.com/gpu.present: "true"  # or gpu.vendor: <vendor>
  tolerations:
    - key: nvidia.com/gpu           # amd.com/gpu | gpu.intel.com/i915
      operator: Exists
      effect: NoSchedule
  containers:
    - name: inference
      image: <YOUR_GPU_IMAGE>
      resources:
        requests:
          cpu: "2"
          memory: 8Gi
        limits:
          cpu: "4"
          memory: 16Gi
          nvidia.com/gpu: 1         # amd.com/gpu | gpu.intel.com/i915
```

> **The GPU goes in `limits` only.** It is an *extended resource*: it must appear
> in `limits`, and if it also appears in `requests` the two must be equal. Setting
> it in `limits` alone makes Kubernetes copy the value into `requests` itself, so
> they cannot drift. Putting a GPU in `requests` alone is the trap — the pod
> schedules and then gets no device.
>
> Whole devices only. `nvidia.com/gpu: 0.5` is rejected. To share, see
> [step 14](#14-sharing-one-gpu).

`helm` renders all four from one block — see
[step 18](#18-helm-values-the-gpu-block).

## 13. The container image contract

Base image supplies the GPU userspace; the host supplies the driver. Two rules
decide whether this works, and they hold for every vendor:

1. **The container's toolkit version must be compatible with the host driver.**
   For NVIDIA, the `CUDA Version` from host `nvidia-smi` is the ceiling — newer
   drivers run older CUDA containers fine, the reverse fails at init. For ROCm, the
   image's ROCm version should match the host's reasonably closely, and the image
   must support your `gfx` target from [step 3](#3-verify-the-driver-and-harden--layer-1).
2. **Install the accelerated build of your framework.** `pip install torch`
   defaults to a CUDA wheel, but a stray `--index-url .../whl/cpu` silently gives
   you a CPU-only build that runs, reports `cuda.is_available() == False`, and looks
   like a Kubernetes problem. ROCm needs `--index-url .../whl/rocm6.x` explicitly.
   Pin the index deliberately, whichever vendor.

### NVIDIA

```dockerfile
# runtime, not devel: ~2 GB smaller, and nvcc is a build-time need
FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt
COPY . .

CMD ["python3", "app.py"]
```

### AMD

```dockerfile
FROM rocm/dev-ubuntu-24.04:6.2-complete

WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir --index-url https://download.pytorch.org/whl/rocm6.2 \
        torch torchvision && \
    pip3 install --no-cache-dir -r requirements.txt
COPY . .

CMD ["python3", "app.py"]
```

Consumer Radeon cards frequently need the compute target spoofed — set it in the
pod, not the image, so one image serves several card types:

```yaml
env:
  - name: HSA_OVERRIDE_GFX_VERSION
    value: "11.0.0"
```

### Intel

```dockerfile
FROM intel/intel-extension-for-pytorch:2.8.10-xpu

WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt
COPY . .

CMD ["python3", "app.py"]
```

Intel's stack is oneAPI + Level Zero + IPEX, and device selection is `xpu`, not
`cuda`. Not every Intel GPU is supported by every Intel AI image — check the matrix
for your specific card before concluding a `Pending` pod is a cluster bug.

## 14. Sharing one GPU

By default **one container gets one whole GPU**, and a second pod stays `Pending`
against an idle device.

| Vendor | Mechanism | Isolation | Set where |
|---|---|---|---|
| NVIDIA | time-slicing | none (context switch) | plugin config, any GPU |
| NVIDIA | MPS | none (shared context) | plugin config, Volta+ |
| NVIDIA | MIG | hardware-partitioned | Operator `migManager`, A100/H100+ |
| Intel | `sharedDevNum` | none | `GpuDevicePlugin` spec |
| AMD | MIG-like partitioning | hardware | firmware/`amd-smi`, CDNA only |

Time-slicing is the lab answer for NVIDIA — one config change, no hardware
requirement:

```sh
cat > /tmp/dp-timeslice.yaml <<'EOF'
version: v1
sharing:
  timeSlicing:
    resources:
      - name: nvidia.com/gpu
        replicas: 4
EOF

helm upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --reuse-values \
  --set-file config.map.config=/tmp/dp-timeslice.yaml
```

One physical GPU now advertises `nvidia.com/gpu: 4`. Nothing changes in the pod
spec — each replica is a slice. Note what this is **not**: replicas grant shared
access, not a guaranteed quarter of the compute, and there is no memory isolation.
Four pods that each want 20 GB on a 24 GB card still OOM. Time-slicing and MPS are
mutually exclusive.

Intel's equivalent is one field — `sharedDevNum: 4` in the `GpuDevicePlugin` from
[step 9](#9-install-the-device-plugin--layer-5), with the same caveats.

For NVIDIA MIG, partition with the Operator's `migManager`
(`mig.strategy=single|mixed`) and inspect with `nvidia-smi -L`. **Never hand-mount
device files into a pod to fake sharing** — it bypasses the scheduler's accounting
entirely, so Kubernetes believes the GPU is free and oversubscribes it.

---

# Part 5 — CI/CD: ship a GPU app

Vendor-independent: the pipeline never touches a GPU. Only the base image in
[step 13](#13-the-container-image-contract) differs.

The pipeline in [`Jenkinsfile`](../Jenkinsfile) already does build → scan → push →
sign → GitOps commit, and Argo CD syncs from
[`argocd/application.yaml`](../argocd/application.yaml). A GPU app needs **no new
stages** — only the deltas below.

## 15. The flow

```text
  developer ──git push──▶ GitHub
                            │  pollSCM
                            ▼
   ┌──────────── Jenkins agent pod (CPU node — no GPU) ────────────┐
   │  kaniko  build ──▶ image.tar                                  │
   │  trivy   scan the tarball        ← gates the push             │
   │  helm    template + lint                                      │
   │  crane   push the scanned tarball                             │
   │  cosign  sign + attach SBOM                                   │
   │  git     bump image: in helm/values.yaml  [ci skip] │
   └───────────────────────────┬───────────────────────────────────┘
                               ▼
                     GitOps repo (values.yaml)
                               │
                          Argo CD sync
                               ▼
                    Rollout ──▶ canary steps
                               ▼
             GPU worker (tainted) ──▶ AI pod ──▶ <vendor>/gpu
```

**The build agent needs no GPU.** kaniko assembles layers; it never executes CUDA
or ROCm. Do not taint-tolerate your Jenkins agents onto the GPU node — building
there just steals memory and page cache from inference.

## 16. What actually changes — and what breaks

Four deltas. Two are one-liners; two are the ones that fail a real pipeline the
first time.

| # | Change | Where |
|---|---|---|
| 1 | GPU base image | `Dockerfile` — [step 13](#13-the-container-image-contract) |
| 2 | `gpu.enabled=true` (+ `runtimeClassName` on NVIDIA) | `helm/values.yaml` |
| 3 | **Raise kaniko's memory + ephemeral storage** | `Jenkinsfile` pod template |
| 4 | **Expect the Trivy gate to fail** | `Jenkinsfile` / base-image choice |

**3 — kaniko OOMs on a GPU build.** The agent pod template caps kaniko at
`limits: {memory: 1500Mi}` and requests no ephemeral storage. That is right for a
Flask image and hopeless for this one: `nvidia/cuda:12.8.1-runtime` is ~2.5 GB
before your code (ROCm images are larger still), a `torch` wheel is another
~2.5 GB, and kaniko unpacks base layers onto its filesystem while `--tar-path`
writes a multi-GB tarball into the shared workspace. You get an opaque
`OOMKilled`, or `no space left on device` from the emptyDir. In the `kaniko`
container of the pod template:

```yaml
    - name: kaniko
      resources:
        requests: {cpu: 500m, memory: 2Gi, ephemeral-storage: 20Gi}
        limits:   {memory: 8Gi,  ephemeral-storage: 40Gi}
```

Bump the `crane` container's `ephemeral-storage` too — it reads the same tarball.

**4 — the Trivy gate will fail on a GPU base image.** The pipeline runs
`--severity HIGH,CRITICAL --exit-code 1`, and a CUDA or ROCm image carries orders
of magnitude more packages than a slim Python one. `--ignore-unfixed` is already
set, which absorbs most of it; what remains are genuinely fixed HIGH/CRITICALs
from a stale base image. In order of preference:

1. **Rebuild on the current base tag.** Usually enough — vendors rebuild these.
2. **Slim the image.** `-runtime` not `-devel`; drop build tooling in a second
   stage. Fewer packages, fewer CVEs, faster pulls onto the GPU node.
3. **Waive specific CVEs in `.trivyignore`**, with an expiry date and a reason.

Do **not** widen the gate to `CRITICAL` only, and do not set `--exit-code 0`, to
get a GPU image through. That trades the one control that runs before anything
reaches the registry for a base-image problem you can fix.

## 17. Jenkinsfile: no new stages

Everything else already generalises — `IMAGE_REPOSITORY`, the shared
`DOCKER_CONFIG`, the tarball hand-off, the `sed` that bumps `values.yaml`, the
`[ci skip]` token that stops the deploy commit re-triggering the build. If the
GPU app is a **second** app rather than a change to `notes-app`, copy the pipeline
and change two variables — the chart directory is shared:

```groovy
APP_NAME     = 'gpu-inference'
HELM_RELEASE = 'gpu-inference'
// HELM_CHART_DIR / HELM_VALUES_FILE stay at helm/ -- one generic chart, or copy
// it to helm-gpu/ if the two apps need to diverge.
```

`helm/` is already generic: nothing in `templates/` names an app, every name
derives from `nameOverride` + `.Release`, and the `gpu:` block is
vendor-agnostic. Porting is `nameOverride` + `image` in `values.yaml`.

## 18. Helm values: the GPU block

[`helm/values.yaml`](../helm/values.yaml) already carries this,
off by default. Turning it on is the entire deploy-side change:

```yaml
# NVIDIA on K3s only: registers the runtime but not as default — step 6.
runtimeClassName: nvidia

gpu:
  enabled: true
  vendor: nvidia      # nvidia · amd · intel — picks resourceName + node label
  count: 1
```

`vendor` selects the preset from [§0.3](#03-the-naming-contract); anything you set
explicitly overrides it:

```yaml
gpu:
  enabled: true
  resourceName: nvidia.com/mig-1g.5gb   # amd.com/gpu · gpu.intel.com/i915 · /xe
  count: 1
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-A100-SXM4-40GB
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  env:
    HIP_VISIBLE_DEVICES: "0"            # merged only when enabled
```

`templates/workload.yaml` merges `gpu.nodeSelector` into `nodeSelector`,
concatenates `gpu.tolerations` onto `tolerations`, and splices
`resourceName: count` into `resources.limits` — so all four requirements from
[step 12](#12-what-a-gpu-pod-needs) come from one flag and cannot disagree.

**Switching vendor is one value**: `gpu.vendor`, plus dropping `runtimeClassName`
for AMD/Intel. Nothing in the templates names NVIDIA. An unknown vendor with no
explicit `resourceName` fails the render with a message rather than shipping a
GPU-less pod.

Render before committing:

```sh
helm template notes-app helm \
  --set gpu.enabled=true --set runtimeClassName=nvidia \
  | grep -A6 -E 'runtimeClassName|nvidia.com/gpu'
```

> **Canary + GPUs need a replica check.** `workload.canary.maxSurge: 1` means one
> extra pod during a canary, and each replica takes a whole GPU. On a single-GPU
> node a 1-replica Rollout cannot surge — the canary pod sits `Pending` on
> *"Insufficient nvidia.com/gpu"* and the rollout stalls until it times out.
> Either enable sharing ([step 14](#14-sharing-one-gpu)), set `maxSurge: 0` with
> `maxUnavailable: 1` (brief downtime, correct on scarce hardware), or keep a
> spare GPU.

## 19. Argo CD

[`argocd/application.yaml`](../argocd/application.yaml) needs **no GPU-specific
change** — it points at the chart path and syncs whatever `values.yaml` says. GPU
scheduling is a property of the workload, not of the Application.

```sh
kubectl apply -f argocd/application.yaml
kubectl -n argocd get application notes-app
```

## 20. Verify the deploy landed on the GPU

```sh
kubectl get pods -o wide                       # NODE column = gpu-worker-01
kubectl argo rollouts get rollout notes-app --watch
```

Then confirm the pod actually holds a device, not just a node:

```sh
POD=$(kubectl get pod -l app.kubernetes.io/name=notes-app -o name | head -1)
kubectl exec "$POD" -- nvidia-smi          # rocm-smi | clinfo
kubectl describe node gpu-worker-01 | grep -A5 'Allocated resources'
```

`Allocated resources` should show your GPU resource at `1  1`. A pod on the right
node whose vendor CLI fails means `runtimeClassName` or the `limits` entry did not
render — go back to [step 12](#12-what-a-gpu-pod-needs).

---

# Part 6 — Operate

## 21. Monitoring

Watch: utilisation, memory used vs total, temperature, power draw, hardware errors,
and — the Kubernetes-specific one — **allocated vs idle GPUs**, since a GPU held by
an idle pod is invisible to the vendor CLI but unavailable to the scheduler.

| Vendor | Ad hoc | Exporter |
|---|---|---|
| NVIDIA | `nvidia-smi` | DCGM exporter |
| AMD | `rocm-smi`, `amd-smi` | `device-metrics-exporter` (in the DeviceConfig above) |
| Intel | `intel_gpu_top` | `intel-xpumanager` |

The real answer is exporter → Prometheus → Grafana. NVIDIA's GPU Operator installs
DCGM already; with the standalone plugin:

```sh
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  -n gpu-monitoring --create-namespace \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
```

The toleration again — every GPU exporter is a DaemonSet and must reach the
tainted node. Import Grafana dashboard **12239**. Key series:
`DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_GPU_TEMP`,
`DCGM_FI_DEV_XID_ERRORS`.

AMD's exporter is already enabled by the `DeviceConfig` in
[step 9](#9-install-the-device-plugin--layer-5) — scrape it on `nodePort: 32500`.

## 22. Day-2

- **Driver upgrades break running containers.** A driver upgraded under a live
  module gives every GPU pod *"Driver/library version mismatch"* (NVIDIA) or a
  `hipInit` failure (ROCm) until reboot. `apt-mark hold`
  ([step 3](#3-verify-the-driver-and-harden--layer-1)), then upgrade deliberately:
  `kubectl drain` → upgrade → reboot → `kubectl uncordon`.
- **Drain GPU nodes with `--ignore-daemonsets`.** The device plugin and the
  exporters are DaemonSets; a plain drain refuses to proceed.
- **Hardware errors in `dmesg` are the card talking.** NVIDIA Xid errors, or
  `amdgpu: ring timeout`, alongside a pod dying with a CUDA/HIP launch failure, is
  not an application bug.
- **Cordon before you debug.** A flapping GPU node will happily accept the next
  scheduled inference pod.

---

# Appendix A — Troubleshooting

Read the symptom, note the layer, fix at that layer. Debugging one layer above the
break is why GPU problems take days.

## Layers 1–2 — host

| Symptom | Vendor | Fix |
|---|---|---|
| `nvidia-smi`: "couldn't communicate with the NVIDIA driver" | NVIDIA | Secure Boot blocked the unsigned module, or no reboot — [step 1](#1-detect-the-gpu-and-check-secure-boot) |
| `nvidia-smi: command not found`, driver fine | NVIDIA | `--gpgpu` omits it — `nvidia-utils-<branch>-server`, [step 2](#2-install-the-gpu-driver--layer-1) |
| `Failed to initialize NVML: Driver/library version mismatch` | NVIDIA | Driver upgraded under a running module. Reboot, then `apt-mark hold` — [step 3](#3-verify-the-driver-and-harden--layer-1) |
| `nouveau` still loaded | NVIDIA | `sudo update-initramfs -u && sudo reboot` |
| `/dev/kfd` missing, `rocminfo` finds no agent | AMD | `amdgpu-dkms` not installed or DKMS build failed — in-tree `amdgpu` alone is display-only, [step 2](#2-install-the-gpu-driver--layer-1) |
| `rocminfo` works as root, fails as user | AMD | Not in `render`/`video`, or no re-login — [step 2](#2-install-the-gpu-driver--layer-1) |
| `clinfo` reports 0 platforms | Intel | `intel-opencl-icd` missing, or not in `render` — [step 2](#2-install-the-gpu-driver--layer-1) |
| No `nvidia` block in K3s containerd config | NVIDIA | Toolkit installed after K3s started — `systemctl restart k3s-agent`, [step 6](#6-verify-the-runtime-registration--layer-23) |
| Config edited by `nvidia-ctk`, reverts on restart | NVIDIA | K3s regenerates its own config. Don't edit it — [step 4](#4-wire-the-gpu-into-the-container-runtime--layer-2) |
| Operator's toolkit pod "succeeds", nothing changes | NVIDIA | Wrote `/etc/containerd/config.toml`, which K3s ignores — [step 9](#nvidia-gpu-operator) |

## Layers 3–4 — runtime and node

| Symptom | Vendor | Fix |
|---|---|---|
| Host CLI works, pod sees no GPU | NVIDIA | Missing `runtimeClassName: nvidia` — [step 6](#6-verify-the-runtime-registration--layer-23) |
| Host CLI works, pod sees no GPU | AMD/Intel | Plugin not mounting device files — check plugin logs, [step 9](#9-install-the-device-plugin--layer-5) |
| `RuntimeClass "nvidia" not found` | NVIDIA | Runtime never detected; K3s only registers classes it found — [step 6](#6-verify-the-runtime-registration--layer-23) |
| Node `NotReady` | any | Agent can't reach `:6443` — `journalctl -u k3s-agent`. K3s bundles a CNI, so this is rarely CNI |

## Layer 5 — device plugin

| Symptom | Vendor | Fix |
|---|---|---|
| **Plugin / exporter / Operator pods `Pending`** | any | **Taint key mismatch — the classic.** [§0.3](#03-the-naming-contract) |
| GPU resource absent from allocatable | any | Plugin not running, or running blind — [step 9](#9-install-the-device-plugin--layer-5) |
| Plugin logs `could not load NVML library` | NVIDIA | Plugin needs the GPU runtime itself — `--set runtimeClassName=nvidia` |
| Operator validator crash-loops; host `nvidia-smi` starts failing | NVIDIA | `driver.enabled=true` with a host driver. Reinstall with `false` — [step 9](#nvidia-gpu-operator) |
| KMM tries to rebuild the driver; node degrades | AMD | `driver.enable: false` in the DeviceConfig, plus `kmm.enabled=false kmm.watch=false` — [step 9](#9-install-the-device-plugin--layer-5) |
| Plugin healthy, node has no `gpu.intel.com/*` label | Intel | NFD installed without the `NodeFeatureRules` overlay, or after the plugin — [step 9](#9-install-the-device-plugin--layer-5) |
| Intel smoke pod `ImagePullBackOff` on `intel/opencl-icd` | Intel | No such public tag — it is built from source. Use the IPEX image or the upstream demo job — [step 11](#11-smoke-test-the-gpu--layer-3) |
| Node labels look duplicated / flap | AMD | Two NFD instances — `--set node-feature-discovery.enabled=false` |

## Layer 6 — workload

| Symptom | Vendor | Fix |
|---|---|---|
| `Pending`, "Insufficient \<resource\>" | any | Every GPU allocated (one container per GPU) — [step 14](#14-sharing-one-gpu) |
| `Pending`, "node(s) had untolerated taint" | any | Missing toleration — [step 12](#12-what-a-gpu-pod-needs) |
| `Pending` forever, resource name looks right | Intel | `i915` vs `xe` mismatch — [step 2](#2-install-the-gpu-driver--layer-1) |
| `Running` but `torch.cuda.is_available()` is `False` | any | No GPU in `limits`, missing `runtimeClassName`, or a CPU-only wheel — [step 13](#13-the-container-image-contract) |
| `Running`, HIP reports no agent | AMD | Image doesn't support your `gfx` target — set `HSA_OVERRIDE_GFX_VERSION` |
| Canary pod `Pending` forever, rollout stalls | any | `maxSurge: 1` needs a spare GPU — [step 18](#18-helm-values-the-gpu-block) |

## CI

| Symptom | Fix |
|---|---|
| kaniko `OOMKilled` / `no space left on device` | GPU image exceeds the agent's memory and ephemeral storage — [step 16](#16-what-actually-changes--and-what-breaks) |
| Trivy fails the build on a GPU base image | Rebuild on current base, slim the image, or a dated `.trivyignore` — [step 16](#16-what-actually-changes--and-what-breaks) |

Logs, in the order to read them:

```sh
sudo dmesg | grep -iE 'nvidia|xid|amdgpu|i915'
sudo journalctl -u k3s-agent -n 200 --no-pager
kubectl -n nvidia-device-plugin logs -l app.kubernetes.io/name=nvidia-device-plugin
kubectl describe node "$NODE"
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

# Appendix B — One-shot verification

Paste on the control plane. Prints the state of layers 4–6 for whichever vendor
you set.

```sh
NODE=gpu-worker-01
RES=nvidia.com/gpu          # amd.com/gpu | gpu.intel.com/i915 | gpu.intel.com/xe
JP=${RES//./\\.}            # escape dots for JSONPath

echo "── L4 node ──";        kubectl get node "$NODE" -o wide --no-headers
echo "── L2/3 runtime ──";   kubectl get runtimeclass 2>&1 | grep -E 'NAME|nvidia'
echo "── L5 allocatable ──"; kubectl get node "$NODE" -o "jsonpath={.status.allocatable.$JP}{\"\n\"}"
echo "── L5 plugins ──";     kubectl get pods -A | grep -Ei 'device-plugin|gpu-operator|amd-gpu|nfd'
echo "── labels ──";         kubectl get node "$NODE" \
  -o jsonpath='{range $k,$v := .metadata.labels}{$k}={$v}{"\n"}{end}' | grep -Ei 'gpu|nvidia|amd|intel'
echo "── taints ──";         kubectl get node "$NODE" \
  -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}'
echo "── L6 allocated ──";   kubectl describe node "$NODE" | grep -A6 'Allocated resources'
```

## Production checklist

**Host** — GPU in `lspci` · Secure Boot handled (NVIDIA/AMD) · driver installed ·
vendor CLI works · device files present · persistence mode on (NVIDIA) · driver
`apt-mark hold`

**Node** — runtime wiring done (NVIDIA toolkit / AMD+Intel device files) ·
`nvidia` in K3s containerd config (NVIDIA) · agent joined · node `Ready` ·
labelled · tainted with the **vendor-prefixed** key

**Cluster** — device plugin running · GPU resource in allocatable · smoke-test pod
prints the vendor CLI · metrics exporter scraped

**Workload** — GPU in `limits` only · `nodeSelector` · toleration ·
`runtimeClassName: nvidia` (NVIDIA on K3s) · image toolkit ≤ host driver ·
framework built for the right accelerator · `maxSurge` fits the GPU count

**Pipeline** — kaniko memory/ephemeral-storage raised · Trivy gate passes without
being widened · image signed · GitOps commit carries `[ci skip]` · Argo CD synced ·
pod verified on the GPU node

# Appendix C — The two-minute interview answer

> **"Walk me through adding a GPU node to Kubernetes and deploying a GPU app."**

1. **Host first, and check Secure Boot before anything else** — NVIDIA and AMD
   both build out-of-tree modules that will not load unsigned, and the failure only
   surfaces after the reboot, looking like a driver bug.
2. **Install the driver** and confirm it with the vendor CLI — `nvidia-smi`,
   `rocm-smi`, `clinfo`. Everything above reads through this. For NVIDIA,
   `--gpgpu` is the headless install and it omits `nvidia-smi`, so you add
   `nvidia-utils-*-server`. For AMD, the in-tree `amdgpu` is display-only —
   compute needs `amdgpu-dkms` plus ROCm. Intel is in-tree and needs nothing.
3. **Wire the GPU into the container runtime.** This is where the vendors really
   differ: NVIDIA needs the Container Toolkit, because the driver exposes
   `/dev/nvidia*` to the *host* and a container is namespaced away from it. AMD and
   Intel need nothing — their plugins mount `/dev/kfd` and `/dev/dri` directly.
   Skipping this on NVIDIA is the single most common mistake, and the symptom is
   host `nvidia-smi` working while the pod sees nothing.
4. **Join K3s.** For NVIDIA, toolkit *before* the agent starts: K3s scans `PATH`
   for alternative runtimes at startup and writes its containerd config from what it
   finds. K3s ships the `nvidia` RuntimeClass but doesn't make it default, so pods
   need `runtimeClassName: nvidia`.
5. **Label and taint** — label so GPU work finds the node, taint so ordinary work
   stays off it. Use the vendor-prefixed key like `nvidia.com/gpu`, because that is
   the only toleration the device-plugin DaemonSets ship by default. A custom key
   like `accelerator` leaves them `Pending` and the GPU never gets advertised.
6. **Device plugin** to advertise the resource into node capacity. NVIDIA: the
   standalone plugin with `runtimeClassName=nvidia`, or the GPU Operator with
   `driver.enabled=false` and `toolkit.enabled=false` since the host already has
   both. AMD: the ROCm operator with `driver.enable: false` and KMM off. Intel: the
   plugin operator plus a `GpuDevicePlugin` CR — and if you use NFD for the labels,
   it and its `NodeFeatureRules` go in before the plugin.
7. **Workload: four things** — the GPU in `limits` (extended resource, whole
   devices only, never in `requests` alone), `nodeSelector`, toleration, and
   `runtimeClassName` on NVIDIA. Our Helm chart renders all four from one
   `gpu.enabled` flag, so switching vendor is three values.
8. **CI/CD needs no new stages.** kaniko never executes CUDA, so the build agent
   stays on CPU. What does change: raise kaniko's memory and ephemeral storage or a
   multi-GB GPU build gets `OOMKilled`, and expect the Trivy HIGH/CRITICAL gate to
   fail on a CUDA base image — fix that by rebuilding on a current base or slimming
   the image, not by widening the gate.

**The framing that lands:** *the driver makes the GPU work on the host, the runtime
wiring makes it visible to containers, the device plugin makes it visible to the
scheduler.* Three separate problems that all present as "the GPU doesn't work" —
and each is invisible until the one below it works, which is why you verify at
every layer instead of debugging from the top.

# Appendix D — Official docs

| | |
|---|---|
| K3s advanced (alternative runtimes) | https://docs.k3s.io/advanced |
| Kubernetes: schedule GPUs | https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/ |
| NVIDIA Container Toolkit | https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/ |
| NVIDIA GPU Operator | https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/ |
| NVIDIA device plugin (+ time-slicing) | https://github.com/NVIDIA/k8s-device-plugin |
| DCGM exporter | https://github.com/NVIDIA/dcgm-exporter |
| ROCm install (Linux) | https://rocm.docs.amd.com/projects/install-on-linux/en/latest/ |
| ROCm system requirements (supported GPUs) | https://rocm.docs.amd.com/projects/install-on-linux/en/latest/reference/system-requirements.html |
| AMD GPU Operator | https://instinct.docs.amd.com/projects/gpu-operator/ |
| Intel device plugins | https://github.com/intel/intel-device-plugins-for-kubernetes |
| Intel GPU plugin | https://github.com/intel/intel-device-plugins-for-kubernetes/tree/main/cmd/gpu_plugin |
