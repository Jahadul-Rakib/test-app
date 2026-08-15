# GPU node + cluster essentials, from scratch (bare-metal Ubuntu)

The companion to `local-kind-setup.md`. That one builds a throwaway cluster on a
laptop; this one takes a **bare-metal Ubuntu server with an NVIDIA card**, turns
it into a Kubernetes node that can actually schedule GPUs, and installs the
cluster-side pieces that make that work.

Nothing here needs a GPU on the machine you are reading it from. Section 12
rehearses the entire cluster-side half against the kind cluster with **no GPU at
all**, including scheduling a pod that asks for `nvidia.com/gpu: 1`.

## The one thing to get right

GPU support is a stack of six layers, and **each one is invisible until the one
below it works**. Almost every "the GPU doesn't show up" problem is someone
debugging layer 5 when layer 2 is broken. Install bottom-up, verify each layer
before moving on:

| # | Layer | Installed by | Verified by |
|---|---|---|---|
| 1 | NVIDIA kernel driver | `apt`, on the host | `nvidia-smi` on the host |
| 2 | Container runtime (containerd) | `apt`, on the host | `sudo crictl info` |
| 3 | NVIDIA Container Toolkit | `apt` + `nvidia-ctk` | `nvidia-smi` **inside a container** |
| 4 | Kubernetes node | `kubeadm join` | `kubectl get nodes` → `Ready` |
| 5 | Device plugin | Helm, in the cluster | `nvidia.com/gpu` in node capacity |
| 6 | The workload asking for one | your chart | pod `Running`, not `Pending` |

Layers 1–4 are on the **node**, over SSH. Layers 5–6 are in the **cluster**, from
wherever your kubeconfig lives. That split is the whole shape of the task: the
host owns the hardware, Kubernetes only learns about it second-hand.

Budget ~45 minutes, two reboots.

> **Which Kubernetes?** Step 5 uses `kubeadm`, the neutral answer and the one an
> interview usually means by "bare metal". A k3s box is in step 5.4 — the GPU
> layers above and below it are identical either way, only the join changes.

---

## 0. Inventory before you touch anything

Five commands, and they decide the next hour. Run them all before installing
anything:

```sh
# 1. Is there actually a supported NVIDIA card on the PCI bus?
lspci -nn | grep -Ei 'vga|3d|display'

# 2. Which Ubuntu, and which kernel?
. /etc/os-release && echo "$PRETTY_NAME"; uname -r

# 3. Secure Boot -- this is the one that ambushes people. See the warning below.
mokutil --sb-state 2>/dev/null || echo "mokutil not installed (likely BIOS/legacy boot)"

# 4. Is a driver already here, half-installed, or is nouveau holding the card?
lsmod | grep -E '^nvidia|^nouveau' || echo "no nvidia/nouveau module loaded"
dpkg -l | grep -E 'nvidia|cuda' | head

# 5. Room to work. Driver + toolkit + CUDA images want ~20 GB free.
df -h /var /
```

`lspci` printing nothing in step 1 means the card is not seated, not powered, or
disabled in the BIOS — no amount of `apt install` fixes that. Note the PCI ID it
does print (`[10de:20b2]`, say); it is what identifies the exact model when a
driver branch turns out not to support it.

> **Secure Boot.** If step 3 says `SecureBoot enabled`, the NVIDIA kernel module
> is built by DKMS and **will not load unsigned** — you install the driver, it
> looks successful, you reboot, and `nvidia-smi` says
> `NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver`.
> The module is on disk; the kernel refused it.
>
> Two ways out. Either **disable Secure Boot in the BIOS** (simplest, and normal
> on a machine you own), or **enroll a MOK key**: the `apt install` in step 2
> shows a blue prompt asking for a one-time password, and on the next boot you
> must sit at the console and pick *Enroll MOK → Continue* and type it. That
> screen appears **before** the OS starts, so it is invisible over SSH — a
> headless server hangs there until someone with a KVM or IPMI console clicks
> through. Decide which one you are doing *now*, not after the reboot.

Base packages, needed by the DKMS build:

```sh
sudo apt-get update
sudo apt-get install -y build-essential dkms "linux-headers-$(uname -r)" \
                        curl ca-certificates gnupg pciutils
```

`linux-headers-$(uname -r)` pins headers to the **running** kernel. If `apt`
upgraded the kernel and you have not rebooted, that is the wrong version and the
DKMS build fails with `Your kernel headers ... cannot be found`. Reboot first if
`uname -r` and the newest installed kernel disagree.

---

## 1. Reboot policy

You will reboot twice: once after the driver (step 2), once after swap/sysctl
(step 5). Both are load-bearing — the driver reboot unloads nouveau and loads
`nvidia`, and neither `modprobe` nor `systemctl` substitutes reliably. Plan the
window before you start, especially if step 0 pushed you toward MOK enrollment
and you need console access for the first one.

---

## 2. NVIDIA driver (layer 1)

Two routes. **Pick one and do not mix them** — the Ubuntu archive and the CUDA
network repo package the same driver under different names, and installing from
both leaves `apt` resolving a conflict it cannot win.

### 2.1 Route A — Ubuntu archive (recommended for a plain server)

Fewer moving parts, and the `-server` branch is the long-lived one meant for
datacenter cards:

```sh
sudo apt-get install -y ubuntu-drivers-common
ubuntu-drivers devices                    # look for the line marked `recommended`

# Headless/compute install. --gpgpu skips the X11 and desktop packages, which a
# server has no use for and which drag in a display stack.
sudo ubuntu-drivers install --gpgpu

# nvidia-smi is NOT part of the --gpgpu set. Install it explicitly, matching the
# branch number ubuntu-drivers just picked, or you have a working driver and no
# way to look at it.
sudo apt-get install -y nvidia-utils-570-server   # substitute your branch
```

That `nvidia-utils-*-server` line is the single most common omission on this
path: everything installs cleanly, and then `nvidia-smi: command not found`
reads like a failed driver install when the driver is fine.

### 2.2 Route B — NVIDIA CUDA network repo

Use when you need a specific driver branch, a newer one than Ubuntu ships, or
CUDA userspace libraries on the host:

```sh
. /etc/os-release
distro="ubuntu$(echo "$VERSION_ID" | tr -d '.')"      # ubuntu2404 / ubuntu2204
arch=$(uname -m)                                       # x86_64 / sbsa

curl -fsSLO "https://developer.download.nvidia.com/compute/cuda/repos/${distro}/${arch}/cuda-keyring_1.1-1_all.deb"
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update

# Open kernel modules -- the supported default on Turing and newer.
sudo apt-get install -y nvidia-open
# Pre-Turing (or if nvidia-open refuses the card), the proprietary metapackage:
#   sudo apt-get install -y cuda-drivers
```

CUDA **toolkit** on the host is not required for Kubernetes and is a few GB.
Containers ship their own CUDA userspace; the host only supplies the driver.
Skip it unless you are compiling on the node.

### 2.3 Reboot and verify

```sh
sudo reboot
```

Back in:

```sh
nvidia-smi
```

This must print a table with your GPU, a driver version and a CUDA version.
**Do not continue until it does** — every later layer reads through this driver,
and a failure here reappears three steps away wearing a completely different
error message.

```sh
lsmod | grep nouveau && echo "PROBLEM: nouveau still loaded"   # expect no output
```

Nouveau is the open-source driver that ships in the kernel; it grabs the card at
boot and the NVIDIA module then cannot. The driver packages blacklist it
automatically, so a hit here means the blacklist did not take —
`/etc/modprobe.d/` will show whether the file is there, and
`sudo update-initramfs -u && sudo reboot` applies it if it is.

Two settings worth having on a server:

```sh
# Persistence mode: keeps the driver initialised when no process is using the
# GPU. Without it every container start pays a multi-second driver init, and
# under Kubernetes that shows up as random slow pod starts.
sudo nvidia-smi -pm 1
sudo systemctl enable --now nvidia-persistenced

# Pin the driver so an unattended-upgrade cannot swap it out from under a
# running node -- a driver upgrade without a reboot breaks every GPU container
# on the box with "Driver/library version mismatch".
sudo apt-mark hold "$(dpkg -l | grep -oE 'nvidia-(open|driver-[0-9]+-server)' | head -1)"
```

---

## 3. Container runtime (layer 2)

Kubernetes needs a CRI runtime. **containerd** is the default and the one the
NVIDIA toolkit configures most cleanly:

```sh
# Docker's repo, because Ubuntu's containerd package is old and lacks the CRI
# plugin config that kubeadm expects.
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y containerd.io
```

Generate a real config — the packaged `/etc/containerd/config.toml` is a stub
that disables the CRI plugin, and a node built on it fails to join with
`validate service connection: CRI v1 runtime API is not implemented`:

```sh
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# SystemdCgroup = true. Ubuntu boots with systemd as the cgroup manager and
# kubelet defaults to the systemd driver; containerd defaults to cgroupfs. Two
# managers writing the same cgroup tree gives you pods that start and then get
# killed under memory pressure that never actually happened.
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n 'SystemdCgroup' /etc/containerd/config.toml    # must read true

sudo systemctl restart containerd
sudo systemctl enable containerd
```

> **containerd 2.x** writes `version = 3` configs where that key lives under
> `[plugins.'io.containerd.cri.v1.runtime'...]` and the `sed` above may not
> match. Check the `grep` output; if it printed nothing, open the file and set
> `SystemdCgroup = true` under the `runc` options block by hand.

Docker Engine on the node is **optional** — Kubernetes has not used it since
1.24. Install it only if you want the convenient `docker run --gpus all` test in
step 4.3; `containerd.io` above already supplies everything kubelet needs.

---

## 4. NVIDIA Container Toolkit (layer 3)

This is the layer people skip, and skipping it is why `nvidia-smi` works on the
host but a container sees no GPU. The driver exposes `/dev/nvidia*` to the
**host**; a container is namespaced away from it. The toolkit is the shim that
injects the device nodes and the driver libraries into a container at creation
time.

```sh
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
```

### 4.1 Wire it into containerd

```sh
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd
```

`nvidia-ctk` edits `/etc/containerd/config.toml` for you — hand-editing that
TOML is a reliable way to lose an afternoon.

**`--set-as-default` is a real decision, not a formality.** With it, *every*
container on the node runs under the NVIDIA runtime, which is simple and is what
a dedicated GPU node usually wants. Without it, the runtime exists but nothing
uses it unless a pod names it — which means a `RuntimeClass`:

```sh
# Only needed if you did NOT pass --set-as-default.
kubectl apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF
```

and then `runtimeClassName: nvidia` in the pod spec — which is exactly what
`runtimeClassName` in this repo's `helm/notes-app/values.yaml` is for. Leave it
empty when you used `--set-as-default`.

### 4.2 Verify the config landed

```sh
grep -A3 'containerd.runtimes.nvidia' /etc/containerd/config.toml
sudo ctr version
```

### 4.3 Verify a container sees the GPU

The real test of layer 3, and the last thing you can check before Kubernetes is
involved. If Docker is installed:

```sh
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

The same table as on the host, from inside a container, means layers 1–3 are
done. If you skipped Docker, the equivalent check is the `cuda-vectoradd` pod in
step 8 — but note that you are then testing three layers at once, and a failure
is harder to place.

---

## 5. Join the node to Kubernetes (layer 4)

### 5.1 Kernel and swap prerequisites

```sh
# Modules, loaded now and on every boot.
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Bridged traffic must be visible to iptables or the CNI cannot NAT pod
# traffic -- Services resolve and then time out, which reads like a DNS bug.
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# Swap off. kubelet refuses to start with swap enabled unless you opt in, and
# the memory accounting the scheduler relies on is meaningless with it on.
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab      # survives reboot
```

### 5.2 kubeadm, kubelet, kubectl

Pin the minor to the control plane's. A node more than one minor behind or any
amount ahead is outside the supported skew:

```sh
K8S_MINOR=v1.33          # must match your control plane

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl     # no surprise minor bumps
sudo systemctl enable --now kubelet
```

`apt-mark hold` matters more here than anywhere else: an unattended upgrade that
moves kubelet a minor version can take the node `NotReady` overnight.

```sh
sudo reboot        # second and last reboot: swap-off and sysctl settle
```

### 5.3 Join

On the **control plane**, mint a fresh command (join tokens expire after 24h):

```sh
kubeadm token create --print-join-command
```

On the **GPU node**, run what it printed:

```sh
sudo kubeadm join <cp-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

From your workstation:

```sh
kubectl get nodes -o wide
```

> **Node stuck `NotReady`?** Nine times in ten there is no CNI installed —
> `kubeadm` deliberately ships none, and kubelet reports
> `NetworkReady=false ... cni plugin not initialized` until one is. See step
> 10.1. It is a cluster-wide install, not a per-node one, so it is only missing
> here if this is a fresh cluster.

### 5.4 Alternative: k3s

Everything above and below is unchanged; only this step differs. k3s bundles its
own containerd, and **auto-detects the NVIDIA runtime** if the toolkit from step
4 is installed *before* k3s:

```sh
# on the control plane
curl -sfL https://get.k3s.io | sh -
sudo cat /var/lib/rancher/k3s/server/node-token

# on the GPU node -- order matters: toolkit (step 4) BEFORE this line
curl -sfL https://get.k3s.io | K3S_URL=https://<cp-ip>:6443 K3S_TOKEN=<token> sh -

# confirm k3s found the runtime
sudo grep -i nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
```

k3s registers the runtime but **not** as the default, so pods need
`runtimeClassName: nvidia`. Set `runtimeClassName: nvidia` in `values.yaml` on
this path.

---

## 6. Expose GPUs to the scheduler (layer 5)

The node has GPUs; Kubernetes does not know. A **device plugin** is what
advertises `nvidia.com/gpu` into the node's capacity so the scheduler can count
it. Two ways to get one.

| | **GPU Operator** | **Standalone device plugin** |
|---|---|---|
| Installs | driver, toolkit, plugin, GFD, DCGM metrics, MIG manager, validator | the device plugin, and that is all |
| Node prep | can do layers 1 and 3 for you | you did them, in steps 2 and 4 |
| Footprint | ~8 pods per GPU node + an operator | one DaemonSet |
| Node labels | yes, via Node Feature Discovery | only with `gfd.enabled=true` |
| Metrics | DCGM exporter included | install separately |
| Use when | a real/growing GPU fleet | one node, or a tight cluster |

The Operator is the production answer and the one to name in an interview: it
makes GPU nodes reproducible and self-describing rather than hand-built. Below
are both; **install one, not both** — two device plugins on one node fight over
the same devices and the node flaps between advertising and withdrawing them.

### 6.1 Option A — NVIDIA GPU Operator (recommended)

```sh
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# Pin the version. Print what is available and pick the newest stable:
helm search repo nvidia/gpu-operator --versions | head -5
```

```sh
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --version <VERSION_FROM_ABOVE> \
  --set driver.enabled=false \
  --set toolkit.enabled=false \
  --wait --timeout 10m
```

**Both `false` flags are the point.** The Operator can install the driver and
toolkit itself, in containers — but you already did, by hand, in steps 2 and 4.
Leaving them `true` makes the Operator try to load a *second* kernel driver over
the running one, and the node melts down: the `driver-daemonset` crash-loops,
`nvidia-smi` on the host starts failing, and running containers die with
`Driver/library version mismatch`. **This is the single most destructive mistake
in the whole document.**

Let the Operator manage both instead — omit both flags — only on a node where
you deliberately skipped steps 2 and 4.

Watch it converge. It takes a few minutes and the validator pods are noisy:

```sh
kubectl -n gpu-operator get pods -w
```

The one that matters is `nvidia-operator-validator`, which must reach
`Completed`/`Running`. Everything downstream depends on its verdict.

### 6.2 Option B — standalone device plugin

```sh
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm search repo nvdp/nvidia-device-plugin --versions | head -5

helm upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --create-namespace \
  --version <VERSION_FROM_ABOVE> \
  --set gfd.enabled=true \
  --wait
```

`gfd.enabled=true` adds GPU Feature Discovery, which writes the
`nvidia.com/gpu.*` labels onto the node. Without it there are no labels — and
the `nodeSelector` in this repo's chart (`nvidia.com/gpu.present: "true"`)
matches nothing, so the pod sits `Pending` on a cluster where the GPU is
demonstrably present. Cheap to enable, easy to forget.

### 6.3 The only check that matters

```sh
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu'
```

A number in the GPU column means layer 5 is done. `<none>` means the plugin is
not running, or is running and cannot see the devices — go to step 13.

---

## 7. Label and taint the node

Labels let workloads *find* the GPU node. Taints stop everything else from
*landing* on it. You want both — otherwise the cluster's CPU-only pods
cheerfully fill up your most expensive machine.

```sh
NODE=gpu-1

# Confirm what GFD wrote. These are the labels to select on -- do not invent
# your own when the discovery layer already publishes accurate ones.
kubectl get node "$NODE" -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep nvidia
```

Expect `nvidia.com/gpu.present=true`, `nvidia.com/gpu.count`,
`nvidia.com/gpu.product` (e.g. `NVIDIA-A100-SXM4-40GB`), and
`nvidia.com/cuda.driver.major`. In a mixed fleet, `gpu.product` is how you pin a
job to the right card.

A role label, for humans and for coarse selection:

```sh
kubectl label node "$NODE" node-role.kubernetes.io/gpu=  --overwrite
kubectl label node "$NODE" workload=gpu                  --overwrite
```

The taint:

```sh
kubectl taint node "$NODE" nvidia.com/gpu=present:NoSchedule --overwrite
```

From here, only pods carrying a matching toleration schedule on this node — the
one in `gpu.tolerations` in `values.yaml` is exactly that. The GPU Operator's own
DaemonSets already tolerate it, so they are unaffected.

`NoSchedule`, not `NoExecute`: `NoExecute` evicts pods that are already running
without the toleration, which on a live node means kicking off whatever was
there. Add the taint before you add the workloads and `NoSchedule` is enough.

---

## 8. Verify with a real GPU pod (layer 6)

End-to-end, through all six layers:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
spec:
  restartPolicy: OnFailure
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  nodeSelector:
    nvidia.com/gpu.present: "true"
  containers:
    - name: cuda-vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

kubectl logs -f pod/cuda-vectoradd
```

`Test PASSED` is the whole stack working. Clean up with
`kubectl delete pod cuda-vectoradd`.

Two rules about that `limits` block, and they are the usual interview follow-up:

- **GPUs go in `limits`, never `requests` alone.** `nvidia.com/gpu` is an
  *extended resource*. Kubernetes copies the limit into requests for you; a
  request without a limit is rejected, and the two must match if you write both.
- **Whole devices only.** `0.5` is invalid. One container gets one or more entire
  GPUs, and a GPU is never shared between two containers — unless you turn on
  time-slicing or MIG, which is step 9.

---

## 9. Sharing one GPU: time-slicing

One card, several pods. Without this, the second pod asking for a GPU on a
single-GPU node stays `Pending` forever, however idle the card is.

Time-slicing tells the plugin to advertise *n* replicas of each physical GPU.
They interleave on the hardware — no memory isolation and no fairness guarantee,
so it is right for dev, inference and notebooks, and wrong for training jobs that
need the whole card.

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator      # nvidia-device-plugin if you used option B
data:
  # `any` is the default config name, applied to every GPU on every node. Add
  # more keys and select per-node with the nvidia.com/device-plugin.config
  # node label when cards differ.
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
          - name: nvidia.com/gpu
            replicas: 4
EOF
```

Point the plugin at it:

```sh
# GPU Operator
helm upgrade gpu-operator nvidia/gpu-operator -n gpu-operator --reuse-values \
  --set devicePlugin.config.name=time-slicing-config \
  --set devicePlugin.config.default=any

# or standalone plugin
helm upgrade nvdp nvdp/nvidia-device-plugin -n nvidia-device-plugin --reuse-values \
  --set config.name=time-slicing-config
```

Capacity now reports `4` on a one-GPU node:

```sh
kubectl get node "$NODE" -o jsonpath='{.status.capacity}' | tr ',' '\n' | grep nvidia
```

**That 4 is a lie the scheduler believes.** It is still one GPU with one pool of
VRAM — four pods each allocating 20 GB on a 40 GB card will OOM, and the
scheduler will happily have placed all four. Time-slicing multiplies *scheduling
slots*, not memory.

> **MIG** is the real isolation answer, on A100/H100/A30 only: it partitions the
> card into hardware-isolated instances with their own memory. The GPU Operator
> manages it via `mig.strategy=single|mixed` and a `MIG_CONFIGURATION` ConfigMap,
> and the resource name becomes e.g. `nvidia.com/mig-1g.5gb`. Worth naming as
> "the option when isolation actually matters"; do not attempt it on hardware
> that does not support it.

---

## 10. Cluster essentials (the non-GPU half)

"Essentials in the Kubernetes cluster" means the things a fresh `kubeadm`
cluster does **not** have and cannot work without, plus the operational floor.
Roughly in order of how badly the cluster wants them:

### 10.1 CNI — required, cluster is broken without it

`kubeadm` ships no network plugin on purpose. Until one is installed every node
is `NotReady` and no pod gets an IP. Calico is the common choice:

```sh
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/custom-resources.yaml
```

The pod CIDR in `custom-resources.yaml` must match `--pod-network-cidr` from
`kubeadm init`. Mismatched, pods get addresses nothing routes to and the
symptom is intermittent, cross-node-only connection timeouts — the worst class
of bug to debug from the top down.

### 10.2 CoreDNS — already there, but check it

Installed by `kubeadm`, and it stays `Pending` until the CNI is up. If it is not
`Running`, nothing in the cluster resolves anything:

```sh
kubectl -n kube-system get pods -l k8s-app=kube-dns
```

### 10.3 Storage — no default StorageClass out of the box

Every `PersistentVolumeClaim` sits `Pending` until something provisions. Jenkins
in `local-kind-setup.md` needs 8 Gi, so this is not optional here. Simplest
bare-metal answer:

```sh
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Node-local, so a pod that moves loses its data — fine for a lab, and the honest
caveat to state. Longhorn or Ceph/Rook is the multi-node answer.

### 10.4 metrics-server — `kubectl top` and HPA

Absent by default, and its absence is why `kubectl top nodes` says
`Metrics API not available` and every HorizontalPodAutoscaler reads
`<unknown>/80%`:

```sh
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --set 'args={--kubelet-insecure-tls}'
```

`--kubelet-insecure-tls` is needed because kubeadm gives kubelets self-signed
serving certs. Correct fix on a real cluster is
`serverTLSBootstrap: true` in the kubelet config plus approving the CSRs; the
flag is the lab shortcut, and worth saying out loud as such.

### 10.5 Ingress — the same install as the kind doc, minus the kind flags

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.hostPort.enabled=true
```

On bare metal there is no cloud load balancer, so a `LoadBalancer` Service stays
`<pending>` forever — the same trap as on kind, for the same reason. `hostPort`
(above) or **MetalLB** are the two answers; MetalLB is the better one if you have
a spare IP range to hand it.

### 10.6 GPU monitoring — DCGM exporter

The GPU-specific piece of observability: per-GPU utilisation, memory, temperature
and ECC errors into Prometheus. The GPU Operator already installed it
(`--set dcgmExporter.enabled=true` is the default); with the standalone plugin,
add it:

```sh
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter -n gpu-operator --create-namespace
```

Pair with kube-prometheus-stack for the Prometheus and Grafana halves.

### 10.7 The rest, in priority order

| Piece | Why | Chart |
|---|---|---|
| kube-prometheus-stack | metrics, alerts, Grafana | `prometheus-community/kube-prometheus-stack` |
| cert-manager | TLS; nothing here is HTTPS yet | `jetstack/cert-manager` |
| Argo CD + Argo Rollouts | this repo's delivery path | see `local-kind-setup.md` steps 4–5 |
| Kyverno | admission policy, signature checks | `local-kind-setup.md` step 6 |
| sealed-secrets / external-secrets | secrets in git without secrets in git | `sealed-secrets/sealed-secrets` |
| Velero | backup, including etcd | `vmware-tanzu/velero` |

Steps 4, 5 and 6 of `local-kind-setup.md` apply here **unchanged** — they are
plain Helm installs with no kind-specific flags. The kind-only parts of that
document are the cluster creation (step 1), the ingress node selector and
`hostPort` (step 3), and the `localtest.me` hostnames.

---

## 11. Deploying this chart onto the GPU node

The chart already carries the wiring — `helm/notes-app/values.yaml`, added for
this. To send it to the GPU node:

```yaml
gpu:
  enabled: true
  resourceName: nvidia.com/gpu
  count: 1
  nodeSelector:
    nvidia.com/gpu.present: "true"
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule

# Only on k3s, or if you skipped --set-as-default in step 4.1
runtimeClassName: ""
```

Or without editing the file:

```sh
helm template notes-app helm/notes-app --set gpu.enabled=true \
  | grep -A6 -E 'nodeSelector|tolerations|resources'
```

Three things happen when `gpu.enabled` flips, and they are separable on purpose —
each one alone leaves the pod broken in a different way:

| Rendered | Without it |
|---|---|
| `resources.limits."nvidia.com/gpu": 1` | pod runs on the GPU node with no GPU visible |
| `nodeSelector: nvidia.com/gpu.present: "true"` | scheduler may place it on a CPU node → `Pending`, "Insufficient nvidia.com/gpu" |
| `tolerations` for the taint | blocked by the taint → `Pending`, "node(s) had untolerated taint" |

> **This app does not need a GPU.** It is a Flask notes app; enabling this makes
> it occupy a GPU it will never use. The block exists so the same chart is
> *portable* to a GPU node, and so the scheduling wiring is reviewable. On a real
> workload the values are identical — only the image changes.

The scheduling logic lives in `templates/_helpers.tpl` (`common.nodeSelector`,
`common.tolerations`, `common.resources`). That file and `templates/configmap.yaml`
are written to be copied into any other chart as-is — no chart dependency, no
`helm dependency build`. See "Reusable templates" in the README.

### The ConfigMap

`helm/notes-app/templates/configmap.yaml` renders up to two ConfigMaps:

- `config.env` → flat keys, injected as environment variables via `envFrom`.
  `app.py` reads `APP_TITLE` and `APP_ENV` and echoes both from `/healthz`, so
  one `curl` proves the config reached the pod.
- `config.files` → whole file bodies, mounted read-only at `config.mountPath`.
  Empty by default, so neither the ConfigMap nor the volume is rendered.

They are separate because `envFrom` turns **every** key in the referenced
ConfigMap into an environment variable — a file body in that same ConfigMap
would land in the process environment as one enormous string.

The pod template carries `checksum/config`, a hash of the rendered ConfigMap
file. Without it, editing a value updates the ConfigMap and *nothing restarts*:
the pod spec is byte-identical, so neither Argo CD nor the Rollouts controller
sees a diff, and pods serve the old values until something unrelated restarts
them. With it, a config change steps through the canary like an image change.

Mounted **files** do refresh in place (~60s, kubelet sync period). Environment
variables never do — they are read once at exec time. That asymmetry is why the
checksum is needed even though ConfigMaps are "live".

```sh
helm upgrade notes-app helm/notes-app --set config.env.APP_ENV=gpu-node

# The workload is a Rollout, not a Deployment -- select by label, there is no
# `kubectl exec rollout/...` shorthand.
POD=$(kubectl get pod -l app.kubernetes.io/name=notes-app -o name | head -1)
kubectl exec "$POD" -- env | grep APP_
kubectl exec "$POD" -- wget -qO- localhost:8080/healthz; echo
```

---

## 12. Rehearsing this with no GPU

Everything from step 6 onward can be practised on the kind cluster from
`local-kind-setup.md`, on a laptop with no NVIDIA hardware. This is worth doing
before an interview — it is the half you will be typing live.

### 12.1 Advertise a fake GPU

Kubernetes lets you PATCH an arbitrary extended resource into a node's status.
The scheduler then counts it exactly like a real one. Pods that ask for
`nvidia.com/gpu` will schedule and run — with no GPU inside, but all the
*scheduling* behaviour is genuine:

```sh
NODE=$(kubectl get nodes -o name | grep worker | head -1 | cut -d/ -f2)

kubectl proxy --port=8001 &
sleep 2

# ~1 is the JSON-Pointer escape for the "/" in nvidia.com/gpu. Unescaped, the
# API server reads it as a path separator and rejects the patch.
curl -s --header "Content-Type: application/json-patch+json" --request PATCH \
  --data '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]' \
  "http://localhost:8001/api/v1/nodes/${NODE}/status" >/dev/null

kill %1

kubectl get node "$NODE" -o jsonpath='{.status.capacity}' | tr ',' '\n' | grep nvidia
```

### 12.2 Add the labels and taint the real thing would have

```sh
kubectl label node "$NODE" nvidia.com/gpu.present=true --overwrite
kubectl label node "$NODE" nvidia.com/gpu.count=2      --overwrite
kubectl taint node "$NODE" nvidia.com/gpu=present:NoSchedule --overwrite
```

### 12.3 Deploy the chart against it

```sh
helm upgrade --install notes-app helm/notes-app --set gpu.enabled=true
kubectl get pods -o wide          # lands on $NODE, Running
```

Then break it on purpose — this is what teaches the failure modes:

```sh
# Toleration removed -> "node(s) had untolerated taint"
helm upgrade notes-app helm/notes-app --set gpu.enabled=true --set gpu.tolerations=null
kubectl describe pod -l app.kubernetes.io/name=notes-app | grep -A5 Events

# More GPUs than exist -> "Insufficient nvidia.com/gpu"
helm upgrade notes-app helm/notes-app --set gpu.enabled=true --set gpu.count=99
kubectl describe pod -l app.kubernetes.io/name=notes-app | grep -A5 Events
```

Undo:

```sh
kubectl taint node "$NODE" nvidia.com/gpu- 
kubectl label node "$NODE" nvidia.com/gpu.present- nvidia.com/gpu.count-
helm upgrade notes-app helm/notes-app       # gpu.enabled back to false
```

The fake capacity survives until the node object is rebuilt; recreating the kind
cluster clears it.

### 12.4 What you cannot rehearse

Be straight about this rather than pretending otherwise: the driver install,
Secure Boot/MOK, the container toolkit, the device plugin actually finding
devices, and time-slicing all need real hardware. What 12.1–12.3 exercises is
**layers 5 and 6** — advertisement, selection, tolerations, resource limits and
the failure messages. That is most of what gets asked about, because it is where
most real-world mistakes are.

A cloud alternative for the real thing: any single spot/preemptible GPU instance
(AWS `g4dn.xlarge`, GCP `n1-standard-4` + T4) runs steps 0–9 end to end for well
under a dollar an hour. Destroy it after.

---

## 13. Troubleshooting

| Symptom | Layer | Cause and fix |
|---|---|---|
| `nvidia-smi` → "couldn't communicate with the NVIDIA driver" | 1 | Secure Boot blocked the unsigned module, or no reboot after install. `mokutil --sb-state`; enroll MOK or disable Secure Boot, then reboot. |
| `nvidia-smi: command not found`, driver otherwise fine | 1 | `--gpgpu` does not install it. `apt install nvidia-utils-<branch>-server`. |
| `Failed to initialize NVML: Driver/library version mismatch` | 1 | Driver upgraded under a running kernel module. Reboot. Then `apt-mark hold` the driver. |
| nouveau still loaded after install | 1 | Blacklist did not reach initramfs. `sudo update-initramfs -u && sudo reboot`. |
| Node `NotReady`, `cni plugin not initialized` | 4 | No CNI. Step 10.1. |
| kubelet won't start, complains about swap | 4 | `swapoff -a` and comment the fstab line. Step 5.1. |
| Pods killed under phantom memory pressure | 2 | cgroup driver mismatch. `SystemdCgroup = true`, restart containerd. Step 3. |
| `CRI v1 runtime API is not implemented` | 2 | Packaged stub `config.toml` disables the CRI plugin. Regenerate it. Step 3. |
| Host `nvidia-smi` works, container sees no GPU | 3 | Container Toolkit missing or not wired into containerd. Step 4, then `docker run --gpus all`. |
| `nvidia.com/gpu` absent from node capacity | 5 | Device plugin not running, or running and blind. `kubectl -n gpu-operator logs -l app=nvidia-device-plugin-daemonset`. |
| Operator validator crash-looping; host `nvidia-smi` starts failing | 5 | `driver.enabled=true` with a host driver already installed. `--set driver.enabled=false` and reinstall. Step 6.1. |
| Pod `Pending`, "Insufficient nvidia.com/gpu" | 6 | No node advertises enough. Check capacity vs. `gpu.count`; already-running GPU pods hold theirs exclusively. |
| Pod `Pending`, "node(s) had untolerated taint" | 6 | Missing toleration for the step 7 taint. |
| Pod `Pending`, "didn't match Pod's node affinity/selector" | 6 | `nvidia.com/gpu.present` label absent — GFD not enabled (step 6.2) or on the wrong node. |
| Pod `Running` but `torch.cuda.is_available()` is False | 3/6 | No GPU in `limits` (so none injected), or `runtimeClassName` needed and unset. |
| Second GPU pod `Pending` on an idle GPU | 5 | Expected. One container per GPU. Turn on time-slicing, step 9. |
| Node flaps between advertising and not | 5 | Two device plugins installed. Remove one — step 6. |

Log locations, in the order to check them:

```sh
sudo dmesg | grep -i nvidia                            # driver, at the kernel
sudo journalctl -u containerd -n 100 --no-pager        # runtime
sudo journalctl -u kubelet -n 100 --no-pager           # node
kubectl -n gpu-operator logs -l app=nvidia-device-plugin-daemonset --tail=100
kubectl -n gpu-operator get pods                       # validator verdict
```

---

## 14. The order, in one page

The interview answer, if you get one question and two minutes:

1. **Verify the hardware and check Secure Boot** — `lspci`, `mokutil --sb-state`.
   Secure Boot silently breaks the driver later; deal with it first.
2. **Install the NVIDIA driver**, reboot, `nvidia-smi`. Everything reads through
   this.
3. **Install containerd**, `SystemdCgroup = true`. Mismatched cgroup drivers give
   phantom OOM kills.
4. **Install the NVIDIA Container Toolkit**, `nvidia-ctk runtime configure`.
   This is the layer that lets a *container* see the GPU — the most commonly
   skipped step.
5. **Prep the node for Kubernetes** — swap off, `br_netfilter`, sysctl — install
   kubeadm/kubelet/kubectl pinned to the control plane's minor, and join.
6. **Install the GPU Operator** with `driver.enabled=false` and
   `toolkit.enabled=false`, because layers 1 and 3 are already there. Getting
   this wrong loads a second driver and takes the node down.
7. **Label and taint the node** — labels so GPU work finds it, a taint so
   ordinary work stays off it.
8. **Verify** — `nvidia.com/gpu` in node capacity, then a `cuda-vectoradd` pod
   that prints `Test PASSED`.
9. **Then the cluster essentials** — CNI first (nothing works without it),
   storage, metrics-server, ingress, monitoring with DCGM.
10. **Workloads request GPUs in `limits`, whole devices only**, plus a
    nodeSelector and a toleration. Time-slicing if one card must be shared, and
    say plainly that it multiplies scheduling slots, not memory.

The line that shows you have done it: *the driver is on the host, the toolkit
makes it visible to containers, and the device plugin makes it visible to the
scheduler — three different problems that all look like "the GPU doesn't work".*
