# GPU node setup (bare-metal Ubuntu)

Turns a bare-metal Ubuntu server with an NVIDIA card into a Kubernetes node that
can run GPU containers. **13 steps, one command block each, top to bottom.**

Budget ~45 minutes, two reboots.

### What this covers, and what it does not

| | Where | Doc |
|---|---|---|
| **Node side** — driver, containerd, toolkit, join | SSH, on the box with the card | **this doc** |
| **Cluster side** — device plugin, labels, taints, scheduling | `kubectl` / `helm`, from anywhere | [local-kind-setup.md](local-kind-setup.md) step 10 |

Do this doc first, then step 10 of the other one. If someone hands you a cluster
whose nodes are already prepared, skip straight there.

### Why the order matters

Six layers, and **each is invisible until the one below it works**. Almost every
"the GPU doesn't show up" is someone debugging layer 5 with layer 2 broken.

| # | Layer | Proof it works |
|---|---|---|
| 1 | NVIDIA driver | `nvidia-smi` on the host — step 5 |
| 2 | containerd | `systemctl status containerd` — step 6 |
| 3 | Container Toolkit | `nvidia-smi` **inside a container** — step 8 |
| 4 | kubelet joined | `kubectl get nodes` — step 13 |
| 5 | Device plugin | `nvidia.com/gpu` in node capacity — other doc |
| 6 | Pod asks for one | pod `Running`, not `Pending` — other doc |

Never skip a proof. A failure at layer 1 resurfaces three steps later wearing a
completely different error message.

---

## 1. Check the GPU and Secure Boot

```sh
lspci -nn | grep -Ei 'vga|3d|display'
. /etc/os-release && echo "$PRETTY_NAME"; uname -r
mokutil --sb-state 2>/dev/null || echo "no mokutil (BIOS/legacy boot)"
```

No `lspci` output means the card is not seated, not powered, or off in the BIOS.
No amount of `apt install` fixes that.

> **`SecureBoot enabled` is the ambush.** The NVIDIA module is built by DKMS and
> will not load unsigned. The install looks fine, then after the reboot
> `nvidia-smi` reports *"couldn't communicate with the NVIDIA driver"*.
>
> Pick one **now**, not after the reboot:
> - **Disable Secure Boot in the BIOS** — simplest.
> - **Enroll a MOK key** — step 3 prompts for a one-time password, and the next
>   boot stops at a blue *Enroll MOK* screen. That screen is **pre-OS, so it is
>   invisible over SSH** — a headless box hangs there until someone reaches it
>   with a KVM or IPMI console.

## 2. Install build prerequisites

```sh
sudo apt-get update
sudo apt-get install -y build-essential dkms "linux-headers-$(uname -r)" \
                        curl ca-certificates gnupg pciutils
```

`$(uname -r)` pins headers to the **running** kernel. If apt upgraded the kernel
and you have not rebooted, that is the wrong version and the DKMS build fails
with *"Your kernel headers cannot be found"*. Reboot first if `uname -r` is
behind the newest installed kernel.

## 3. Install the NVIDIA driver

```sh
sudo apt-get install -y ubuntu-drivers-common
ubuntu-drivers devices                    # note the line marked `recommended`
sudo ubuntu-drivers install --gpgpu
```

`--gpgpu` is the headless/compute install — it skips the X11 and desktop
packages a server has no use for.

Now the step everyone misses. `--gpgpu` does **not** install `nvidia-smi`, so
you end up with a working driver and no way to look at it:

```sh
sudo apt-get install -y nvidia-utils-570-server    # match the branch above
```

<details>
<summary>Need a newer driver than Ubuntu ships? Use NVIDIA's repo instead</summary>

Do **not** mix this with the commands above — the two package the same driver
under different names and apt cannot resolve the conflict.

```sh
. /etc/os-release
distro="ubuntu$(echo "$VERSION_ID" | tr -d '.')"    # ubuntu2404 / ubuntu2204
arch=$(uname -m)                                     # x86_64 / sbsa

curl -fsSLO "https://developer.download.nvidia.com/compute/cuda/repos/${distro}/${arch}/cuda-keyring_1.1-1_all.deb"
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get install -y nvidia-open        # Turing and newer
# pre-Turing: sudo apt-get install -y cuda-drivers
```

The CUDA **toolkit** on the host is not needed for Kubernetes and costs a few
GB. Containers ship their own CUDA userspace; the host only supplies the driver.

</details>

## 4. Reboot

```sh
sudo reboot
```

Required, not optional: this is what unloads nouveau and loads `nvidia`.

## 5. Verify the driver — layer 1

```sh
nvidia-smi
```

Must print a table with your GPU, a driver version and a CUDA version.
**Do not continue until it does.**

```sh
lsmod | grep nouveau && echo "PROBLEM: nouveau still loaded"
```

Expect no output. Nouveau is the in-kernel open driver; it grabs the card at
boot and the NVIDIA module then cannot. The packages blacklist it automatically,
so a hit means the blacklist never reached initramfs — fix with
`sudo update-initramfs -u && sudo reboot`.

Two settings worth having on a server:

```sh
sudo nvidia-smi -pm 1                        # persistence mode
sudo systemctl enable --now nvidia-persistenced
```

Without persistence mode every container start pays a multi-second driver init,
which shows up in Kubernetes as random slow pod starts.

```sh
sudo apt-mark hold "$(dpkg -l | grep -oE 'nvidia-(open|driver-[0-9]+-server)' | head -1)"
```

An unattended driver upgrade without a reboot breaks every GPU container on the
box with *"Driver/library version mismatch"*.

## 6. Install containerd — layer 2

Ubuntu's containerd package is too old and lacks the CRI config kubeadm expects,
so use Docker's repo:

```sh
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

Generate a real config — the packaged one is a stub with the CRI plugin
disabled, and a node built on it fails to join with *"CRI v1 runtime API is not
implemented"*:

```sh
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n 'SystemdCgroup' /etc/containerd/config.toml       # must read true
sudo systemctl restart containerd && sudo systemctl enable containerd
```

`SystemdCgroup = true` is not cosmetic. Ubuntu boots with systemd as cgroup
manager and kubelet defaults to the systemd driver, while containerd defaults to
cgroupfs. Two managers writing one cgroup tree gives pods that get killed under
memory pressure that never happened.

> If the `grep` printed nothing you are on **containerd 2.x**, where that key
> moved under `[plugins.'io.containerd.cri.v1.runtime'…]`. Open the file and set
> `SystemdCgroup = true` in the `runc` options block by hand.

## 7. Install the NVIDIA Container Toolkit — layer 3

This is the layer people skip, and skipping it is exactly why `nvidia-smi` works
on the host but a container sees nothing. The driver exposes `/dev/nvidia*` to
the **host**; a container is namespaced away from it. The toolkit injects the
device nodes and driver libraries at container creation.

```sh
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
```

Wire it into containerd — never hand-edit that TOML:

```sh
sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
sudo systemctl restart containerd
grep -A3 'containerd.runtimes.nvidia' /etc/containerd/config.toml
```

> **`--set-as-default` is a real choice.** With it, every container on the node
> runs under the NVIDIA runtime — simple, and what a dedicated GPU node wants.
> Without it, pods must ask for the runtime by name, which needs a RuntimeClass
> and `runtimeClassName: nvidia` in the pod spec (that is what the
> `runtimeClassName` value in `helm/values.yaml` is for):
>
> ```sh
> kubectl apply -f - <<'EOF'
> apiVersion: node.k8s.io/v1
> kind: RuntimeClass
> metadata:
>   name: nvidia
> handler: nvidia
> EOF
> ```

## 8. Verify a container sees the GPU — layer 3

The last thing you can check before Kubernetes is involved. Easiest with Docker,
which needs the **daemon**, not just the client — `docker-ce-cli` alone leaves
`systemctl restart docker` failing with no such unit:

```sh
sudo apt-get install -y docker-ce docker-ce-cli
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

The same table as on the host, from inside a container, means layers 1–3 are
done.

Docker is **not** needed by Kubernetes — it has not used it since 1.24, and
step 6 already installed everything kubelet requires. This is purely a test
convenience, and dockerd drives the same containerd underneath. Skip it if you
would rather not have the daemon on a node, and take the first cluster-side
check in the other doc as your layer-3 proof instead — accepting that a failure
there spans three layers at once and is harder to place.

## 9. Prepare the node for Kubernetes

```sh
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
```

```sh
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

Bridged traffic must be visible to iptables or the CNI cannot NAT pod traffic —
Services then resolve and time out, which reads like a DNS bug.

```sh
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
```

kubelet refuses to start with swap on, and the memory accounting the scheduler
relies on is meaningless with it.

## 10. Install kubeadm, kubelet, kubectl

Pin the minor to the **control plane's**. More than one minor behind, or any
amount ahead, is outside the supported skew.

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
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

`apt-mark hold` matters more here than anywhere else — an unattended upgrade
that moves kubelet a minor version takes the node `NotReady` overnight.

## 11. Reboot

```sh
sudo reboot
```

Second and last. Lets swap-off and the sysctl settings settle.

## 12. Join the cluster — layer 4

On the **control plane**, mint a command (join tokens expire after 24h):

```sh
kubeadm token create --print-join-command
```

On the **GPU node**, run what it printed:

```sh
sudo kubeadm join <cp-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

## 13. Verify the node

```sh
kubectl get nodes -o wide
```

The node must reach `Ready`.

> **Stuck `NotReady`?** Nine times in ten there is no CNI — kubeadm ships none
> on purpose, and kubelet reports `cni plugin not initialized` until one is
> installed. That is a cluster-wide install, not a per-node one, so it is only
> missing if the cluster itself is fresh. See Appendix B.

---

## Next: the cluster side

The node is ready; Kubernetes still does not know it has a GPU. A **device
plugin** is what advertises `nvidia.com/gpu` into the node's capacity so the
scheduler can count it.

That, plus node labels, the taint and the workload wiring, is
**[local-kind-setup.md](local-kind-setup.md) step 10** — run it from anywhere
with a kubeconfig. When you get there, install the GPU Operator with:

```sh
--set driver.enabled=false --set toolkit.enabled=false
```

because steps 3 and 7 above already installed both. Leaving them `true` makes
the Operator load a second kernel driver over the running one and the node melts
down. Step 10.3 spells this out.

---

## Appendix A — k3s instead of kubeadm

Replaces steps 9–12; everything before and after is unchanged. k3s bundles its
own containerd and auto-detects the NVIDIA runtime **if the toolkit from step 7
is installed first**.

```sh
# control plane
curl -sfL https://get.k3s.io | sh -
sudo cat /var/lib/rancher/k3s/server/node-token

# GPU node -- order matters: step 7 BEFORE this line
curl -sfL https://get.k3s.io | K3S_URL=https://<cp-ip>:6443 K3S_TOKEN=<token> sh -

sudo grep -i nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
```

k3s registers the runtime but **not** as the default, so set
`runtimeClassName: nvidia` in `values.yaml` on this path.

---

## Appendix B — essentials a fresh kubeadm cluster lacks

Only if you built the cluster yourself. Skip entirely when joining an existing
one.

**CNI — required, nothing works without it.** Every node stays `NotReady` and no
pod gets an IP:

```sh
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/custom-resources.yaml
```

The pod CIDR in `custom-resources.yaml` must match `--pod-network-cidr` from
`kubeadm init`. Mismatched, you get intermittent cross-node-only timeouts — the
worst class of bug to debug from the top down.

**Storage — no default StorageClass**, so every PVC sits `Pending`:

```sh
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Node-local, so a pod that moves loses its data. Fine for a lab; Longhorn or
Rook/Ceph is the multi-node answer.

**metrics-server** — without it `kubectl top` says *"Metrics API not available"*
and every HPA reads `<unknown>/80%`:

```sh
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --set 'args={--kubelet-insecure-tls}'
```

`--kubelet-insecure-tls` is the lab shortcut — kubeadm gives kubelets
self-signed serving certs. The real fix is `serverTLSBootstrap: true` plus
approving the CSRs.

**Ingress** — on bare metal there is no cloud load balancer, so a
`LoadBalancer` Service stays `<pending>` forever. Use `hostPort` or MetalLB:

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.hostPort.enabled=true
```

**GPU metrics** — DCGM exporter gives per-GPU utilisation, memory, temperature
and ECC errors. The GPU Operator installs it already; with the standalone
plugin:

```sh
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  -n gpu-operator --create-namespace
```

Then, in rough priority order: kube-prometheus-stack, cert-manager, Argo CD +
Argo Rollouts, Kyverno, sealed-secrets, Velero. Steps 4, 5 and 6 of
[local-kind-setup.md](local-kind-setup.md) install the Argo and Kyverno pieces
unchanged on any cluster.

---

## Appendix C — troubleshooting

| Symptom | Layer | Fix |
|---|---|---|
| `nvidia-smi`: "couldn't communicate with the NVIDIA driver" | 1 | Secure Boot blocked the unsigned module, or no reboot. `mokutil --sb-state`; step 1. |
| `nvidia-smi: command not found`, driver fine | 1 | `--gpgpu` omits it. `apt install nvidia-utils-<branch>-server` — step 3. |
| `Failed to initialize NVML: Driver/library version mismatch` | 1 | Driver upgraded under a running module. Reboot, then `apt-mark hold` — step 5. |
| nouveau still loaded | 1 | `sudo update-initramfs -u && sudo reboot` — step 5. |
| Pods killed under phantom memory pressure | 2 | cgroup driver mismatch. `SystemdCgroup = true` — step 6. |
| `CRI v1 runtime API is not implemented` | 2 | Packaged stub config disables the CRI plugin. Regenerate — step 6. |
| Host `nvidia-smi` works, container sees no GPU | 3 | Toolkit missing or not wired into containerd — steps 7 and 8. |
| kubelet won't start, complains about swap | 4 | `swapoff -a` + fstab — step 9. |
| Node `NotReady`, `cni plugin not initialized` | 4 | No CNI — Appendix B. |
| `nvidia.com/gpu` absent from node capacity | 5 | Device plugin not running or blind — other doc, step 10.3. |
| Operator validator crash-loops; host `nvidia-smi` starts failing | 5 | `driver.enabled=true` with a host driver present. Reinstall with it `false`. |
| Pod `Pending`, "Insufficient nvidia.com/gpu" | 6 | Nothing advertises enough — other doc, step 10.1. |
| Pod `Pending`, "node(s) had untolerated taint" | 6 | Missing toleration — other doc, step 10.4. |
| Pod `Running` but `torch.cuda.is_available()` is False | 3/6 | No GPU in `limits`, or `runtimeClassName` needed and unset. |
| Second GPU pod `Pending` on an idle GPU | 5 | Expected — one container per GPU. Time-slicing, other doc step 10.6. |

Logs, in the order to check them:

```sh
sudo dmesg | grep -i nvidia
sudo journalctl -u containerd -n 100 --no-pager
sudo journalctl -u kubelet -n 100 --no-pager
```

---

## Appendix D — the whole thing in one page

The interview answer, if you get two minutes:

1. **Check the card and Secure Boot.** Secure Boot silently breaks the driver
   later; deal with it first.
2. **Install the driver**, reboot, `nvidia-smi`. Everything reads through this.
3. **Install containerd** with `SystemdCgroup = true`. Mismatched cgroup drivers
   give phantom OOM kills.
4. **Install the NVIDIA Container Toolkit** and `nvidia-ctk runtime configure`.
   This is what lets a *container* see the GPU — the most commonly skipped step.
5. **Prep for Kubernetes** — swap off, `br_netfilter`, sysctl — install
   kubeadm/kubelet/kubectl pinned to the control plane's minor, and join.
6. **Then the cluster side**: a device plugin to advertise `nvidia.com/gpu`,
   labels so GPU work finds the node, a taint so ordinary work stays off it, and
   workloads that request GPUs in **`limits`**, whole devices only.

The line that shows you have done it: *the driver is on the host, the toolkit
makes it visible to containers, and the device plugin makes it visible to the
scheduler — three different problems that all look like "the GPU doesn't work".*
