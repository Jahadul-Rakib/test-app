# Production-style K3s on OrbStack — 3 nodes, from scratch

A 3-node K3s cluster on one Apple Silicon MacBook, with **every** bundled K3s
convenience component stripped out and replaced by the thing you would actually
run in production. Everything below is a command you can paste. No files to
create by hand, no `/etc/hosts`, no separate scripts — every manifest and every
Helm values file is a heredoc inside the command that consumes it.

| Layer | We run | Replaces the K3s default |
|---|---|---|
| Kubernetes | **K3s** `v1.36.3+k3s1` | — |
| CNI + network policy | **Calico** `v3.32.1` | Flannel, and K3s' own NetworkPolicy controller |
| Cluster DNS | **CoreDNS** chart `1.47.0` (app `1.14.6`) | K3s' packaged CoreDNS |
| Load balancer | **MetalLB** `0.16.1` | ServiceLB / Klipper |
| Ingress | **ingress-nginx** chart `4.15.1` (app `1.15.1`) | Traefik |
| Storage | **OpenEBS LocalPV** `4.5.1` | local-path-provisioner |

Then a CI/CD layer on top of that platform (steps 15–19):

| Layer | We run | Reached at |
|---|---|---|
| Progressive delivery | **Argo Rollouts** `2.41.1` (app `v1.9.1`) | — (CRDs + controller) |
| GitOps CD | **Argo CD** chart `10.3.3` (app `v3.5.1`) | `/argocd` |
| CI | **Jenkins** chart `5.9.54` (app `2.568.2`) | `/jenkins` |
| Image build | **Kaniko** `v1.23.2` — no Docker daemon | in the build pod |

Nothing else. No metrics-server, no dashboard, no observability stack.

> **The CI/CD layer fits in 8 GB, but only if you size Jenkins yourself.** With
> the stock 1 GB heap this machine hit **load 21, macOS at 117 MB free and
> 4.8 GB of swap in use**, and every controller holding a leader-election lease
> began restarting. The platform is not the problem — measured, it is ~1.15 GB
> of container memory. Jenkins at `-Xmx512m` (step 17) runs permanently
> alongside it. Read the sizing note in step 17 before you install it.

> **This document was executed, not drafted.** Every command below was run
> against a real 3-node cluster on an 8 GB M1 while writing it, and the outputs
> quoted are the outputs that came back. Where something failed the first time,
> the fix is in the step rather than in a footnote. The five places that bite
> are called out as **Trap** boxes — they are the reason this is not just the
> upstream quickstarts pasted together.

---

## Architecture: one IP, path-based routing

Everything is reached through **a single MetalLB LoadBalancer IP**, with NGINX
routing on the URL path. There is nothing to add to `/etc/hosts`.

```
  macOS browser / curl
        │
        │   http://<METALLB-IP>/demo/
        ▼
  bridge100 ── the OrbStack bridge on macOS
        │       subnet from: orb config get network.subnet4
        │
        │   ARP: "who has <METALLB-IP>?"  ──►  answered by ONE metallb-speaker
  ══════╪════════════════════════════════════════════════════════════════
        │      OrbStack's SINGLE Linux VM — one shared kernel
  ══════╪════════════════════════════════════════════════════════════════
        ▼
  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
  │   k3s-server    │  │  k3s-worker-1   │  │  k3s-worker-2   │
  │  TAINTED:       │  │                 │  │                 │
  │  control plane  │  │  ingress-nginx  │  │  coredns        │
  │  + DaemonSets   │  │  coredns        │  │  metallb-ctrl   │
  │  only           │  │  openebs-lpv    │  │  demo-web + PVC │
  ├─────────────────┤  ├─────────────────┤  ├─────────────────┤
  │ kube-apiserver  │  │ kubelet         │  │ kubelet         │
  │ scheduler       │  │ kube-proxy      │  │ kube-proxy      │
  │ controller-mgr  │  │                 │  │                 │
  │ sqlite          │  │                 │  │                 │
  ├─────────────────┤  ├─────────────────┤  ├─────────────────┤
  │ calico-node     │  │ calico-node     │  │ calico-node     │ DaemonSet
  │ metallb-speaker │  │ metallb-speaker │  │ metallb-speaker │ DaemonSet
  └─────────────────┘  └─────────────────┘  └─────────────────┘

  Pod network      10.42.0.0/16   Calico, VXLAN-encapsulated, natOutgoing
  Service network  10.43.0.0/16   kube-proxy, iptables mode
  Cluster DNS      10.43.0.10     CoreDNS
```

### The request path, hop by hop

```
macOS curl
   │ 1. ARP for <METALLB-IP>          ← one metallb-speaker answers
   ▼
node eth0
   │ 2. kube-proxy iptables DNAT      → ingress-nginx pod
   ▼
ingress-nginx-controller
   │ 3. matches  /demo(/|$)(.*)  → rewrites to /$2
   │ 4. resolves demo-web.demo.svc.cluster.local  ← CoreDNS on 10.43.0.10
   ▼
demo-web pod                          ← reached over the Calico VXLAN overlay
   │ 5. nginx serves index.html
   ▼
OpenEBS LocalPV volume                ← a directory on ONE node's disk
```

If `http://<METALLB-IP>/demo/` renders, all six components work.

Everything else added later hangs off the same single address, separated only by
path — there is still nothing to put in `/etc/hosts`:

| Path | Served by | Added in |
|---|---|---|
| `/demo/` | the step 13 sample app | step 13 |
| `/argocd` | Argo CD UI + API | step 16 |
| `/jenkins` | Jenkins UI | step 17 |
| `/app` | notes-app, deployed by Argo CD | step 19 |

None of the four uses an nginx `rewrite-target`. Each backend is told its own
prefix instead — `server.rootpath` for Argo CD, `jenkinsUriPrefix` for Jenkins,
gunicorn's `SCRIPT_NAME` for the app — so every link, redirect and asset URL
they generate already carries it. The one that *does* rewrite is `/demo`, which
serves static files and has no links to get wrong.

---

## Before you start — the 8 GB reality check

Read this. It is the difference between a cluster that works and one that
half-works in a way that is very hard to diagnose.

**OrbStack "Linux machines" are not VMs.** They are full Ubuntu userlands —
systemd, `apt`, passwordless `sudo` — but all of them run inside OrbStack's
*single* Linux VM and share **one kernel**. You can see it directly:

```
$ for m in k3s-server k3s-worker-1 k3s-worker-2; do orb -m $m -u root cat /proc/loadavg; done
2.21 ...        # identical
2.21 ...        # identical  -- one kernel, one load average
2.21 ...        # identical
```

Consequences that matter here:

- **`--memory` per machine is a cap, not a reservation.** Every machine reports
  the *whole* VM's RAM in `/proc/meminfo` (`MemTotal: 5992 MB` on a 6144 MiB
  VM, in all three). They compete for one pool.
- **You cannot load kernel modules.** `modprobe` is best-effort. Step 2 therefore
  *proves* VXLAN works by creating a real vxlan link rather than trusting `lsmod`.
- **Swap cannot be disabled** (zram). K3s runs the kubelet with
  `--fail-swap-on=false`, so this is fine — it just looks alarming in `free -m`.
- **`/dev/kmsg` is present** on current OrbStack builds (kernel 7.0.x). Older
  LXC-style guides tell you to symlink it; step 2 does so only if it is missing.

**The binding constraint is CPU, not RAM.** With ~4 GB still free, this cluster
drove the load average to **40** and the API server stopped answering, because
three nodes were pulling and unpacking container images at once on a shared
8-core VM. The two mitigations below are not optional:

1. **The control-plane node is tainted** (step 3) so add-ons never stack on top
   of the API server. Applying this taint took the load average from 40 to 2.
2. **Install one component at a time**, waiting for each to settle. Every step
   below ends with a wait for exactly that reason. Do not paste the whole
   document in at once.

Give OrbStack room, but leave macOS some:

```sh
orb config set memory_mib 6144      # of 8 GB total
orb config get cpu                  # 8 = every core; drop to 6 if macOS stutters
```

---

## Quick installation

**For rebuilding an environment you already understand.** Every command is
explained in the full walkthrough below; if this is your first time, use that.
Steps 6 (address discovery) and the settle-waits are **not** optional.

```sh
# 0. Tools
brew install --cask orbstack && brew install kubectl helm

# 1. Machines  (NO --isolated: an isolated machine cannot join a cluster)
orb create --arch arm64 --memory 2560M --cpus 2 --disk 20G ubuntu:24.04 k3s-server
orb create --arch arm64 --memory 1536M --cpus 2 --disk 20G ubuntu:24.04 k3s-worker-1
orb create --arch arm64 --memory 1536M --cpus 2 --disk 20G ubuntu:24.04 k3s-worker-2

# 2-5. Prepare, install K3s, join workers, fetch kubeconfig -- see full steps 2-5.
#      The server MUST be installed with --node-taint CriticalAddonsOnly=true:NoExecute.

# 6. Derive the MetalLB range from the REAL subnet. Never copy a range from a doc.
orb config get network.subnet4
orb -m k3s-server -u root ip -4 -o addr show eth0

# 7. Calico -- CRDs FIRST, then the chart (the chart alone fails; see step 7)
kubectl apply --server-side -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/operator-crds.yaml

# 8-11. CoreDNS -> MetalLB -> ingress-nginx -> OpenEBS, one at a time.

# 12. Verify
export KUBECONFIG=~/.kube/k3s-lab.yaml
kubectl get nodes
curl -sS "http://$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/demo/"
```

---

## Full installation

| | Step |
|---|---|
| 0 | Prerequisites |
| 1 | Create the three Ubuntu ARM64 machines |
| 2 | Prepare Ubuntu |
| 3 | Install the K3s server (with the control-plane taint) |
| 4 | Join the two workers |
| 5 | Kubeconfig on macOS |
| 6 | Discover the network, choose the MetalLB range |
| 7 | Calico — the CNI |
| 8 | CoreDNS — cluster DNS |
| 9 | MetalLB — LoadBalancer addresses |
| 10 | NGINX Ingress Controller |
| 11 | OpenEBS LocalPV — storage |
| 12 | Storage concepts + persistence test |
| 13 | Sample application + end-to-end test |
| 14 | Full-stack verification |
| | **— platform done. CI/CD below; see the 8 GB warning at the top —** |
| 15 | Argo Rollouts |
| 16 | Argo CD — at `/argocd` |
| 17 | Jenkins — at `/jenkins`, and why there is no Docker socket |
| 18 | Credentials |
| 19 | The pipeline — Jenkins builds, Argo CD deploys |

---

## 0. Prerequisites

```sh
brew install --cask orbstack
brew install kubectl helm

orb status                       # must print: Running
orb config get memory_mib        # RAM for ALL machines combined
orb config get cpu
orb config get network.subnet4   # the subnet the machines live on
```

Add the Helm repositories once:

```sh
helm repo add projectcalico https://docs.tigera.io/calico/charts
helm repo add coredns       https://coredns.github.io/helm
helm repo add metallb       https://metallb.github.io/metallb
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add openebs       https://openebs.github.io/openebs
helm repo update
```

> Every version in this document was read from the live upstream source, not
> from memory. Refresh them with:
> ```sh
> curl -s https://update.k3s.io/v1-release/channels | python3 -c \
>   'import json,sys; print([c["latest"] for c in json.load(sys.stdin)["data"] if c["id"]=="stable"][0])'
> helm search repo projectcalico/tigera-operator --versions | head -3
> ```

---

## 1. Create the three Ubuntu ARM64 machines

```sh
orb create --arch arm64 --memory 2560M --cpus 2 --disk 20G ubuntu:24.04 k3s-server
orb create --arch arm64 --memory 1536M --cpus 2 --disk 20G ubuntu:24.04 k3s-worker-1
orb create --arch arm64 --memory 1536M --cpus 2 --disk 20G ubuntu:24.04 k3s-worker-2
```

- `--arch arm64` — explicit, though it is the default on Apple Silicon. Do not
  use `amd64` here; emulated nodes pull x86 images and crawl.
- `--memory`/`--cpus` — caps, not reservations (see the reality check above).
- **No `--isolated` and no `--isolate-network`.** An isolated machine is
  deliberately blocked from other machines and host IPs, which makes clustering
  impossible.

> **Trap 1 — a pre-existing machine may be isolated.** Check before you debug a
> phantom network problem:
> ```sh
> for m in k3s-server k3s-worker-1 k3s-worker-2; do
>   printf '%-14s isolate_network=%s\n' "$m" "$(orb config get machine.$m.isolate_network 2>/dev/null)"
> done
> # any 'true' -> orb config set machine.<name>.isolate_network false && orb restart <name>
> ```

Verify. `orb list` prints the addresses directly:

```sh
orb list
```
```
k3s-server    running  ubuntu  noble  arm64  802.1 MB  192.168.139.109
k3s-worker-1  running  ubuntu  noble  arm64  802.1 MB  192.168.139.229
k3s-worker-2  running  ubuntu  noble  arm64  681.0 MB  192.168.139.146
```

---

## 2. Prepare Ubuntu

Runs on all three. Idempotent — rerun freely. It installs what K3s and Calico
shell out to, sets the sysctls, and **fails loudly** if a kernel capability is
missing, so you find out in 30 seconds rather than 40 minutes into Calico.

```sh
for m in k3s-server k3s-worker-1 k3s-worker-2; do
  echo "================ $m ================"
  orb -m "$m" -u root bash -s <<'PREP'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl ca-certificates iptables iproute2 conntrack socat ethtool >/dev/null 2>&1
echo "packages       : ok"

# The kubelet opens /dev/kmsg for its log/OOM watchers. It IS present on current
# OrbStack builds; this is a no-op guard for builds where it is not.
printf 'L /dev/kmsg - - - - /dev/console\n' > /etc/tmpfiles.d/k3s-kmsg.conf
[ -e /dev/kmsg ] || ln -sf /dev/console /dev/kmsg
echo "/dev/kmsg      : $([ -e /dev/kmsg ] && echo present || echo MISSING)"

printf 'br_netfilter\noverlay\nvxlan\n' > /etc/modules-load.d/k3s-calico.conf
for mod in br_netfilter overlay vxlan; do modprobe "$mod" 2>/dev/null || true; done

cat > /etc/sysctl.d/99-k3s-calico.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system >/dev/null 2>&1 || true
echo "ip_forward     : $(cat /proc/sys/net/ipv4/ip_forward)"

# --- capability checks: fail here, not halfway through Calico ---
fail=0
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || { echo "FAIL ip_forward"; fail=1; }

# Prove VXLAN rather than trusting lsmod -- on a shared kernel lsmod lies.
if ip link add vxprobe type vxlan id 1 dstport 4789 2>/dev/null; then
  ip link del vxprobe; echo "vxlan          : supported"
else echo "FAIL: kernel cannot create vxlan links -- Calico VXLAN cannot work"; fail=1; fi

[ -f /sys/fs/cgroup/cgroup.controllers ] && echo "cgroups        : v2" \
  || { echo "FAIL: cgroup v2 required by Kubernetes 1.35+"; fail=1; }

echo "hostname       : $(hostname)"
echo "eth0           : $(ip -4 -o addr show eth0 | awk '{print $4}')"
exit $fail
PREP
done
```

Expected, per node:

```
packages       : ok
/dev/kmsg      : present
ip_forward     : 1
vxlan          : supported
cgroups        : v2
hostname       : k3s-server
eth0           : 192.168.139.109/24
```

Why each sysctl: `ip_forward` lets the node route between the pod network and
`eth0` (without it pods reach nothing); `bridge-nf-call-iptables` makes bridged
traffic traverse iptables, without which kube-proxy's Service rules never match.

> Note the netmask: machines get a **/24** on `eth0` even though
> `orb config get network.subnet4` reports a **/23**. The /24 is what governs
> ARP scope, so step 6 derives the MetalLB range from the node's CIDR.

---

## 3. Install the K3s server

```sh
SERVER_IP="$(orb -m k3s-server -u root ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
echo "SERVER_IP=$SERVER_IP"

orb -m k3s-server -u root sh -c "curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION='v1.36.3+k3s1' \
  INSTALL_K3S_EXEC='server \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=traefik,servicelb,local-storage,coredns,metrics-server \
    --node-taint CriticalAddonsOnly=true:NoExecute \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16 \
    --cluster-dns=10.43.0.10 \
    --node-ip=$SERVER_IP \
    --tls-san=$SERVER_IP \
    --tls-san=k3s-server.orb.local \
    --write-kubeconfig-mode=644' \
  sh -"

orb -m k3s-server -u root systemctl is-active k3s     # -> active
```

Flag by flag:

| Flag | Why |
|---|---|
| `--flannel-backend=none` | K3s lays down no CNI. Nodes stay `NotReady` until Calico. Correct, not a failure. |
| `--disable-network-policy` | K3s' NetworkPolicy controller would fight Calico's over the same objects. |
| `--disable=traefik,servicelb,local-storage,coredns,metrics-server` | the five packaged add-ons we replace or do not want. |
| `--node-taint CriticalAddonsOnly=true:NoExecute` | **the single most important flag in this document** — see below. |
| `--cluster-cidr=10.42.0.0/16` | K3s' default, kept deliberately. Calico's IPPool is set to match. Calico's own quickstart uses `192.168.0.0/16`, which on a laptop collides with real LANs. |
| `--cluster-dns=10.43.0.10` | written into every pod's `/etc/resolv.conf`. CoreDNS must land on exactly this address. |
| `--node-ip` | pins the node address so kubelet and Calico cannot disagree. |
| `--tls-san` ×2 | so a kubeconfig pointing at either the IP or the name validates. |

> **Trap 2 — without the taint, this cluster eats itself.** Left untainted, the
> scheduler stacks ingress-nginx, CoreDNS and metallb-controller onto
> `k3s-server` *alongside the API server*. Under image-pull load the
> `calico-node` liveness probe on that node times out, the kubelet restarts it,
> networking on the control plane drops, the API server stops answering, and
> everything with a leader-election lease (tigera-operator, the OpenEBS
> provisioner, calico-kube-controllers) starts crash-looping. Observed here:
> **load average 40, API server unreachable, `calico-node` restarted 8 times.**
> Applying the taint dropped the load average to **2** and moved every add-on to
> the workers.
>
> `--node-taint` only applies **at node registration**. Putting it in
> `/etc/rancher/k3s/config.yaml` after the fact does nothing (verified — the
> taint silently did not appear). On an already-running cluster use:
> ```sh
> kubectl taint nodes k3s-server CriticalAddonsOnly=true:NoExecute --overwrite
> ```

**The Helm controller stays enabled** on purpose. It is a goroutine inside the
k3s process, not a pod — disabling it saves zero memory and only removes the
mechanism K3s uses to tear down the add-ons we just disabled.

---

## 4. Join the two workers

```sh
TOKEN="$(orb -m k3s-server -u root cat /var/lib/rancher/k3s/server/node-token)"

# Prefer the DNS name: OrbStack addresses come from DHCP, and a name survives a
# renumbering that an IP does not. Verify it resolves from inside a worker first.
orb -m k3s-worker-1 -u root getent hosts k3s-server.orb.local && JOIN=k3s-server.orb.local \
  || JOIN="$(orb -m k3s-server -u root ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
echo "workers will join https://${JOIN}:6443"

for m in k3s-worker-1 k3s-worker-2; do
  WIP="$(orb -m "$m" -u root ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
  echo "================ joining $m ($WIP) ================"
  orb -m "$m" -u root sh -c "curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION='v1.36.3+k3s1' \
    K3S_URL='https://${JOIN}:6443' \
    K3S_TOKEN='$TOKEN' \
    INSTALL_K3S_EXEC='agent --node-ip=$WIP' \
    sh -"
done

orb -m k3s-server -u root k3s kubectl get nodes -o wide
```

Agents take **no** `--flannel-backend` or `--disable` flags — those are
control-plane decisions the agents inherit.

Expected — `NotReady` is correct here, there is no CNI yet:

```
NAME           STATUS     ROLES           AGE   VERSION
k3s-server     NotReady   control-plane   60s   v1.36.3+k3s1
k3s-worker-1   NotReady   <none>          26s   v1.36.3+k3s1
k3s-worker-2   NotReady   <none>          0s    v1.36.3+k3s1
```

---

## 5. Kubeconfig on macOS

Writes to `~/.kube/k3s-lab.yaml`. It does **not** touch `~/.kube/config`.

```sh
mkdir -p ~/.kube
SERVER_IP="$(orb -m k3s-server -u root ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
orb -m k3s-server -u root cat /etc/rancher/k3s/k3s.yaml \
  | sed "s#https://127.0.0.1:6443#https://${SERVER_IP}:6443#" > ~/.kube/k3s-lab.yaml
chmod 600 ~/.kube/k3s-lab.yaml
kubectl --kubeconfig ~/.kube/k3s-lab.yaml config rename-context default k3s-lab

export KUBECONFIG=~/.kube/k3s-lab.yaml     # re-run this in every new terminal
kubectl get nodes
```

Confirm the bundled components really are gone:

```sh
kubectl -n kube-system get deploy traefik   # NotFound
kubectl -n kube-system get deploy coredns   # NotFound
kubectl get sc                              # empty -- no local-path
kubectl get ds -A | grep svclb              # empty -- no ServiceLB
kubectl get pods -A                         # "No resources found"
orb -m k3s-server -u root ip link show flannel.1   # does not exist
```

A completely empty `kubectl get pods -A` is the point: K3s is providing only the
core, and we add every layer ourselves.

---

## 6. Discover the network and choose the MetalLB range

**There is no correct IP range to copy from a document, including this one.**
OrbStack's *documented* default is `198.19.249.0/24`; the machine this was
written on reports `192.168.138.0/23`. Derive it.

### 6.1 Ask OrbStack, then look at what the nodes actually got

```sh
orb config get network.subnet4      # authoritative: OrbStack's own config
```
```
192.168.138.0/23
```

```sh
# macOS side of the bridge
ifconfig | awk '/^[a-z0-9]+:/{i=substr($1,1,length($1)-1)} /inet /&&$2!="127.0.0.1"{printf "%-10s %s netmask %s\n",i,$2,$4}'
```
```
en0        192.168.0.163 netmask 0xffffff00
bridge100  192.168.139.3 netmask 0xfffffe00     <-- macOS is ON the machine bridge
```

```sh
NODE_CIDR="$(orb -m k3s-server -u root ip -4 -o addr show eth0 | awk '{print $4}')"
echo "node CIDR: $NODE_CIDR"      # 192.168.139.109/24
```

Derive from the **node's** CIDR (`/24`), not OrbStack's `/23`: the node's mask is
what decides which addresses it will ARP for.

### 6.2 Propose a range at the top of the subnet

```sh
read -r POOL_START POOL_END <<< "$(python3 -c "
import ipaddress
n = ipaddress.ip_interface('$NODE_CIDR').network
h = list(n.hosts())
print(h[-14], h[-5])      # 10 addresses, 4 of headroom below broadcast
")"
echo "proposed pool: $POOL_START - $POOL_END"
```
```
proposed pool: 192.168.139.241 - 192.168.139.250
```

Four rules the proposal follows:

1. **Inside the node's subnet.** MetalLB will happily assign an address from
   outside it, and that address then answers nothing at all, because macOS has
   no route putting packets for it on the bridge. This is the most common
   MetalLB mistake and it produces a Service that *looks* perfectly healthy.
2. **At the top.** DHCP allocates from the low end, so the top is least likely
   to be handed to a machine you create next month.
3. **Not the broadcast address**, with a few spare below it.
4. **Probed, not assumed.**

### 6.3 Probe every candidate

```sh
python3 -c "
import ipaddress
a=ipaddress.ip_address('$POOL_START'); b=ipaddress.ip_address('$POOL_END')
for i in range(int(a), int(b)+1): print(ipaddress.ip_address(i))
" | while read -r ip; do
  ping -c1 -W300 "$ip" >/dev/null 2>&1
  if arp -n "$ip" 2>/dev/null | grep -qE 'at [0-9a-f]{1,2}:'; then echo "  IN USE  $ip"
  else echo "  free    $ip"; fi
done
```

All ten should read `free`. Sanity-check the probe itself against addresses you
know are occupied — it must report those as `IN USE`:

```sh
for ip in 192.168.139.1 "$SERVER_IP"; do
  ping -c1 -W300 "$ip" >/dev/null 2>&1
  arp -n "$ip" | grep -qE 'at [0-9a-f]{1,2}:' && echo "IN USE $ip (correct)" || echo "free $ip (probe is broken)"
done
```

> **Trap 3 — the obvious ARP test gives false positives.** macOS `arp -n <ip>`
> prints `? (192.168.139.241) at (incomplete) on bridge100`, not "no entry", and
> the preceding `ping` *creates* that incomplete entry. Testing for the absence
> of "no entry" therefore marks every address in the pool as occupied. The test
> must match a **resolved MAC** — `at [0-9a-f]{1,2}:` — as above. `ping` is the
> primary signal; ARP is the fallback for hosts that ignore ICMP.

Keep `$POOL_START` and `$POOL_END` exported for step 9.

---

## 7. Calico — the CNI

**What it does.** Gives every pod an address from the cluster CIDR, programs the
routes that carry pod traffic between nodes, and enforces `NetworkPolicy`.
**Why we need it.** Without a CNI the kubelet reports `NetworkPlugin cni failed`,
every node stays `NotReady`, and nothing can be scheduled.
**Replaces.** Flannel *and* K3s' built-in NetworkPolicy controller.

### 7.1 Install the CRDs first — the chart alone fails

```sh
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/operator-crds.yaml

kubectl get crd installations.operator.tigera.io    # must exist before 7.2
```

> **Trap 4 — `helm install` on its own does not work.** The chart templates an
> `Installation` custom resource, but the CRD defining it is installed by the
> operator at *runtime*, so the very first apply fails:
> ```
> Error: unable to build kubernetes objects from release manifest:
> resource mapping not found for name: "default" ... no matches for kind
> "Installation" in version "operator.tigera.io/v1"  ensure CRDs are installed first
> ```
> `--server-side` is required too: these CRDs exceed the 256 KB annotation limit
> that client-side apply uses.

### 7.2 Install the operator

```sh
kubectl create namespace tigera-operator --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | helm upgrade --install calico projectcalico/tigera-operator \
  --version v3.32.1 --namespace tigera-operator -f - --wait --timeout 10m
installation:
  enabled: true
  # Disables Calico's CSI driver, which exists for its own flow-log ephemeral
  # volumes. K3s does not use the standard kubelet plugin path. Already the
  # chart default; pinned so a chart bump cannot turn it on.
  kubeletVolumePluginPath: "None"
  controlPlaneReplicas: 1
  calicoNetwork:
    # No router on the OrbStack bridge to peer with, and VXLAN carries pod
    # traffic, so the BGP daemon would only burn memory.
    bgp: "Disabled"
    # eBPF would need a kernel we do not control (shared with every machine).
    linuxDataplane: "Iptables"
    # Use the address K3s pinned with --node-ip. The default (firstFound) can
    # latch onto the wrong interface. NodeInternalIP is the only valid value.
    nodeAddressAutodetectionV4:
      kubernetes: NodeInternalIP
    ipPools:
      # MUST equal --cluster-cidr. If they disagree, pods get addresses that
      # kube-proxy's rules do not expect and "some traffic works" -- miserable.
      - cidr: "10.42.0.0/16"
        # Unconditional VXLAN. The upstream default VXLANCrossSubnet would send
        # pod traffic UNENCAPSULATED here, because all three machines are on one
        # subnet -- which only works if the bridge forwards frames for addresses
        # it never handed out. 50 bytes of MTU removes the question entirely.
        encapsulation: "VXLAN"
        natOutgoing: "Enabled"
        nodeSelector: "all()"
        blockSize: 26
# Off for memory. Each is genuinely useful on a real cluster and unaffordable here.
apiServer: {enabled: false}    # aggregated projectcalico.org/v3 API
goldmane:  {enabled: false}    # flow aggregator, ~150 MiB
whisker:   {enabled: false}    # web UI for Goldmane
resources:
  requests: {cpu: 50m, memory: 64Mi}
EOF
```

The operator runs `hostNetwork: true` and tolerates every taint — which is
exactly why it can bootstrap onto a node that has no CNI and is `NotReady`.

### 7.3 Wait and verify

```sh
until kubectl -n calico-system get ds/calico-node >/dev/null 2>&1; do sleep 5; done
kubectl -n calico-system rollout status ds/calico-node --timeout=600s   # pulls ~200 MB/node

kubectl get nodes -o wide
kubectl -n calico-system get pods -o wide
kubectl get ippools.crd.projectcalico.org -o custom-columns=\
NAME:.metadata.name,CIDR:.spec.cidr,VXLAN:.spec.vxlanMode,NAT:.spec.natOutgoing
```

All three nodes must now be `Ready`, and:

```
NAME                  CIDR           VXLAN    NAT
default-ipv4-ippool   10.42.0.0/16   Always   true
```

The test that actually proves a CNI — **cross-node** pod traffic, since a broken
overlay looks perfectly healthy on a single node:

```sh
kubectl create deployment cnitest --image=nginx:1.29-alpine --replicas=3
kubectl rollout status deploy/cnitest
kubectl get pods -l app=cnitest -o wide          # confirm they span nodes

# Pin BOTH ends by name. `kubectl exec deploy/cnitest` and `.items[0]` resolve
# to the SAME pod, so the obvious one-liner has a pod fetch its own address --
# which passes on a completely broken overlay. Pick a destination whose
# nodeName differs from the source's, and the hop is real.
SRC=$(kubectl get pod -l app=cnitest -o jsonpath='{.items[0].metadata.name}')
SRC_NODE=$(kubectl get pod "$SRC" -o jsonpath='{.spec.nodeName}')
read -r DST_IP DST_NODE <<< "$(kubectl get pods -l app=cnitest \
  -o jsonpath="{range .items[?(@.spec.nodeName!='$SRC_NODE')]}{.status.podIP} {.spec.nodeName}{'\n'}{end}" | head -1)"
echo "$SRC ($SRC_NODE) -> $DST_IP ($DST_NODE)"
[ -n "$DST_IP" ] || echo "WARNING: all replicas on one node -- scale up until they span"

kubectl exec "$SRC" -- wget -qO- --timeout=5 "http://${DST_IP}" | head -3
kubectl exec "$SRC" -- wget -qO- --timeout=5 -O /dev/null https://github.com && echo egress-ok
kubectl delete deployment cnitest
```

The first line of output is the assertion — if the two node names are not
different, the test proved nothing:

```
cnitest-5679f4f594-rtjvj (k3s-worker-2) -> 10.42.76.18 (k3s-worker-1)
<!DOCTYPE html>
egress-ok
```

**Troubleshooting**

```sh
kubectl -n tigera-operator logs deploy/tigera-operator -f
kubectl -n calico-system logs ds/calico-node -c calico-node --tail=100
kubectl get tigerastatus                       # operator's own health summary
orb -m k3s-server -u root ip route | grep 10.42
orb -m k3s-server -u root ls -la /etc/cni/net.d/
```

| Symptom | Cause | Fix |
|---|---|---|
| Nodes stay `NotReady` | `calico-node` still pulling | `kubectl -n calico-system get pods -w` |
| Same-node traffic works, cross-node fails | VXLAN not passing | re-run the step 2 vxlan probe; check UDP 4789 is not firewalled |
| `IPPool` CIDR ≠ cluster CIDR | mismatched install | fix the values and reinstall; if pods already have wrong IPs, rebuild |
| `tigera-operator` restarts, `leader election lost` | API server stalling under load | resource pressure — see the reality check; confirm the taint from step 3 is applied |

---

## 8. CoreDNS — cluster DNS

**What it does.** Watches Services and Endpoints and synthesises DNS records
(`demo-web.demo.svc.cluster.local` → ClusterIP), forwarding everything else
upstream. **Why.** Service discovery in Kubernetes *is* DNS; without it the
ingress controller cannot resolve its backends. **Replaces.** K3s' packaged
CoreDNS, so the Corefile and version are ours rather than rewritten on restart.

**Install after Calico** — CoreDNS pods run on the pod network.

```sh
cat <<'EOF' | helm upgrade --install coredns coredns/coredns \
  --version 1.47.0 --namespace kube-system -f - --wait --timeout 5m
replicaCount: 2
service:
  # THE one value that must be right. K3s starts every kubelet with
  # --cluster-dns=10.43.0.10 and writes it into every pod's /etc/resolv.conf.
  # Land anywhere else and nothing in the cluster resolves anything -- and it
  # presents as "the network is broken", not "DNS is on the wrong address".
  clusterIP: "10.43.0.10"
  name: kube-dns
serviceAccount: {create: true}
rbac: {create: true}
# When the VM gets tight, DNS must not be what gets evicted.
priorityClassName: system-cluster-critical
resources:
  requests: {cpu: 50m, memory: 70Mi}
  limits:   {memory: 170Mi}
# Two replicas stacked on one node buy nothing. Preferred, not required, so a
# two-node outage does not leave DNS unschedulable.
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels: {app.kubernetes.io/name: coredns}
podDisruptionBudget: {maxUnavailable: 1}
EOF

kubectl -n kube-system rollout status deploy/coredns --timeout=300s
```

Verify — the ClusterIP assertion first, because everything else depends on it:

```sh
kubectl -n kube-system get svc kube-dns          # CLUSTER-IP must be 10.43.0.10
kubectl -n kube-system get pods -l app.kubernetes.io/name=coredns -o wide

kubectl run dnstest --rm -i --restart=Never --image=busybox:1.37 --command -- sh -c '
  echo "--- resolv.conf ---"; cat /etc/resolv.conf
  echo "--- in-cluster ---";  nslookup kubernetes.default.svc.cluster.local
  echo "--- upstream ---";    nslookup github.com'
```

Both lookups must succeed — in-cluster proves the `kubernetes` plugin and RBAC,
upstream proves `forward . /etc/resolv.conf` reaching the node's resolver:

```
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.43.0.10
...
Name:	kubernetes.default.svc.cluster.local
Address: 10.43.0.1
...
Name:	github.com
Address: 20.205.243.166
```

| Symptom | Cause | Fix |
|---|---|---|
| Everything fails DNS | Service not on `10.43.0.10` | `kubectl -n kube-system get svc kube-dns`; reinstall with the right `clusterIP` |
| `provided IP is already allocated` | K3s' CoreDNS still holds it | `kubectl -n kube-system delete deploy coredns svc kube-dns cm coredns`, rerun |
| Pods stuck `ContainerCreating` | installed before Calico | finish step 7 |
| In-cluster fails, upstream works | RBAC | logs show `Failed to list *v1.Service`; ensure `rbac.create` and `serviceAccount.create` |

---

## 9. MetalLB — LoadBalancer addresses

**What it does.** On bare metal `type: LoadBalancer` has nothing to call, so
Services sit `<pending>` forever. MetalLB allocates an address from your pool and,
in **L2 mode**, has one elected speaker answer ARP for it — so macOS resolves it
to a node's MAC. **Replaces.** ServiceLB/Klipper, which opens a `hostPort` on
every node and calls the node IPs "external" — clever, but not a load balancer.

```sh
kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | helm upgrade --install metallb metallb/metallb \
  --version 0.16.1 --namespace metallb-system -f - --wait --timeout 5m
crds: {enabled: true}
# frr-k8s is the DEFAULT BGP backend in chart 0.16.x and ships ENABLED, quietly
# adding a DaemonSet + controller to every node. BGP is unusable here (no router
# to peer with), so L2 is the only option and FRR is ~150 MiB of dead weight.
frrk8s: {enabled: false}
controller:
  enabled: true
  logLevel: info
  resources: {requests: {cpu: 25m, memory: 64Mi}}
speaker:
  enabled: true
  logLevel: info
  tolerateMaster: true
  frr: {enabled: false}
  # Speakers gossip to elect, per address, the ONE node that answers ARP for it.
  # Without it two nodes claim the same address and ARP flaps. Needs 7946 tcp+udp.
  memberlist: {enabled: true, mlBindPort: 7946}
  # REQUIRED because of the step 3 taint: tolerateMaster only covers the
  # control-plane taint, not CriticalAddonsOnly. Without this the speaker is
  # evicted from k3s-server and that node can never announce an address.
  tolerations:
    - {key: CriticalAddonsOnly, operator: Exists, effect: NoExecute}
    - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
  resources: {requests: {cpu: 25m, memory: 64Mi}}
prometheus: {serviceMonitor: {enabled: false}}
EOF

kubectl -n metallb-system rollout status ds/metallb-speaker --timeout=300s
```

Apply the pool — **only after the validating webhook is serving**, or you get a
TLS error that reads like a MetalLB bug and is not:

```sh
until kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: probe, namespace: metallb-system}
spec: {addresses: ["${POOL_START}-${POOL_END}"]}
EOF
do echo "waiting for webhook..."; sleep 5; done

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: orbstack-pool
  namespace: metallb-system
spec:
  addresses:
    - ${POOL_START}-${POOL_END}
  autoAssign: true
---
# L2: one speaker answers ARP for these on the OrbStack bridge. No router exists
# here to peer with, which rules BGP out. Consequence: all traffic for a given
# address enters through a single node -- failover, not load sharing.
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: orbstack-l2
  namespace: metallb-system
spec:
  ipAddressPools: [orbstack-pool]
  # Announce only on the bridge interface. By default a speaker announces from
  # ALL interfaces, which on a node full of cali* veths is noise at best.
  interfaces: [eth0]
EOF

kubectl -n metallb-system get ipaddresspools.metallb.io,l2advertisements.metallb.io
```

### Verify — assignment is easy, reachability is the real test

```sh
kubectl create deployment lbprobe --image=nginx:1.29-alpine
kubectl expose deployment lbprobe --port=80 --type=LoadBalancer
kubectl rollout status deploy/lbprobe --timeout=300s
until [ -n "$(kubectl get svc lbprobe -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" ]; do sleep 3; done
IP="$(kubectl get svc lbprobe -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "assigned: $IP"

# 1. from inside the cluster -- isolates Kubernetes from ARP
orb -m k3s-worker-1 -u root curl -sS -m 5 -o /dev/null -w 'inside  HTTP %{http_code}\n' "http://${IP}/"
# 2. from macOS -- the one that matters
curl -sS -m 8 -o /dev/null -w 'macOS   HTTP %{http_code}\n' "http://${IP}/"
# 3. which node is answering
arp -n "$IP"

kubectl delete svc lbprobe; kubectl delete deploy lbprobe
```

Verified result on this setup — **L2 mode does work through the OrbStack bridge**:

```
assigned: 192.168.139.241
inside  HTTP 200
macOS   HTTP 200
? (192.168.139.241) at c2:de:11:8c:ca:98 on bridge100 ifscope [bridge]
```

If step 1 succeeds and step 2 fails, the problem is ARP on the bridge, not
Kubernetes. The fallback that always works is in the troubleshooting section.

### Limitations of L2 mode

- **One node per address.** L2 elects a single speaker; it is failover, not load
  sharing. Irrelevant at three nodes, a bottleneck at thirty.
- **Failover is ARP-cache-bound.** Clients with a stale entry keep sending to the
  dead node until it expires.
- **Addresses must be in the nodes' own subnet** — the mechanism is ARP. Not a
  configuration choice; it is what L2 *is*.
- **`externalTrafficPolicy: Local`** preserves the client IP but restricts
  announcement to nodes running a backing pod; with one ingress replica a
  reschedule leaves a stale ARP entry. We use `Cluster` for that reason.
- **kube-proxy in IPVS mode needs `strictARP: true`.** K3s uses iptables mode,
  so it does not apply here — but check it first if you move this elsewhere.

---

## 10. NGINX Ingress Controller

**What it does.** Compiles `Ingress` objects into NGINX config so one external
address fronts every HTTP app, routing on host and path. **Why.** Otherwise five
apps means five LoadBalancer addresses. **Replaces.** Traefik — ingress-nginx is
what most Kubernetes documentation and annotations assume.

> This is the community **`ingress-nginx`**, not F5's `nginx-ingress`. Different
> annotations, different chart; mixing their docs wastes an afternoon.

```sh
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.15.1 --namespace ingress-nginx -f - --wait --timeout 10m
controller:
  replicaCount: 1
  ingressClassResource:
    name: nginx
    enabled: true
    # Default class: an Ingress with no ingressClassName still gets picked up.
    # With one controller there is nothing to collide with, and it removes a
    # whole category of "my Ingress does nothing".
    default: true
    controllerValue: k8s.io/ingress-nginx
  watchIngressWithoutClass: true
  service:
    enabled: true
    type: LoadBalancer          # this is what consumes a MetalLB address
    # Cluster, not Local: any node can accept the packet, so the address keeps
    # working the instant the controller pod moves. Cost: the client IP is
    # SNATed away. A lab wants the robust one.
    externalTrafficPolicy: Cluster
  config:
    use-forwarded-headers: "true"
    proxy-body-size: "16m"
  resources:
    requests: {cpu: 100m, memory: 128Mi}
  # Rejects malformed Ingress objects at admission instead of breaking NGINX's
  # config reload at runtime. Two short-lived Jobs, no standing cost.
  admissionWebhooks: {enabled: true}
  metrics: {enabled: false}
# An unmatched request gets NGINX's own 404 rather than another pod's memory.
defaultBackend: {enabled: false}
EOF

kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

export INGRESS_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "INGRESS_IP=$INGRESS_IP"
```

Verify:

```sh
kubectl -n ingress-nginx get svc,pods
kubectl get ingressclass                     # nginx must show (default)
curl -sS -m 8 -D - -o /dev/null "http://${INGRESS_IP}/"
```

```
NAME                       CONTROLLER             AGE
nginx (default)            k8s.io/ingress-nginx   63s

HTTP/1.1 404 Not Found
```

**A 404 is the correct answer here** — the controller is up and simply has no
rule matching `/` yet. Connection refused or a timeout is not.

---

## 11. OpenEBS LocalPV — storage

**What it does.** Watches for PVCs asking for `openebs-hostpath`; when a pod is
scheduled, creates `/var/openebs/local/<pv-name>` on that pod's node and
publishes it as a PV pinned there. **Replaces.** local-path-provisioner.

> **Trap 5 — do not install this chart with defaults on 8 GB.** The `openebs`
> umbrella chart is an entire storage platform: Mayastor (replicated NVMe-oF,
> wanting hugepages and a dedicated block device), ZFS LocalPV, LVM LocalPV,
> plus a Loki + Alloy logging stack — **all enabled by default**. On a 6 GB VM
> that is not a slow start, it is an OOM. The values below cut it to exactly one
> Deployment and one StorageClass.

```sh
kubectl create namespace openebs --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | helm upgrade --install openebs openebs/openebs \
  --version 4.5.1 --namespace openebs -f - --wait --timeout 10m
engines:
  local:
    lvm:      {enabled: false}   # needs an LVM volume group per node
    zfs:      {enabled: false}   # needs a ZFS pool; shared kernel has no ZFS
    rawfile:  {enabled: false}   # upstream still marks it non-stable
    hostpath: {enabled: true}    # the one we want
  replicated:
    mayastor: {enabled: false}   # hugepages + a block device + ~1 GiB/node
loki:  {enabled: false}          # OpenEBS' own log shipping, ~400 MiB
alloy: {enabled: false}
openebs-crds:
  csi:
    volumeSnapshots: {enabled: false}   # for the CSI engines, all off
preUpgradeHook: {enabled: false}        # only for v3 -> v4 upgrades
localpv-provisioner:
  localpv:
    resources:
      requests: {cpu: 25m, memory: 64Mi}
EOF

kubectl -n openebs rollout status deploy/openebs-localpv-provisioner --timeout=300s
```

Verify the diet worked — one Deployment, one StorageClass:

```sh
kubectl -n openebs get deploy,ds,pods
kubectl get sc -o custom-columns=\
NAME:.metadata.name,PROVISIONER:.provisioner,BINDING:.volumeBindingMode,RECLAIM:.reclaimPolicy
```
```
deployment.apps/openebs-localpv-provisioner   1/1     1            1

NAME               PROVISIONER        BINDING                RECLAIM
openebs-hostpath   openebs.io/local   WaitForFirstConsumer   Delete
```

---

## 12. Storage concepts, and a persistence test

### The four words

| Object | Created by | What it is |
|---|---|---|
| **StorageClass** | admin, once | *How to make* a volume — a named recipe: which provisioner, binding mode, reclaim policy. |
| **PersistentVolumeClaim (PVC)** | app author | *A request for* a volume: "1Gi, ReadWriteOnce, from class `openebs-hostpath`". Namespaced; lives and dies with the app. |
| **PersistentVolume (PV)** | the provisioner | *The actual volume.* Cluster-scoped, created dynamically to satisfy a PVC. |
| **LocalPV** | — | Not an object — a *kind* of PV whose storage is a directory or device on one specific node. |

Flow: PVC names a StorageClass → the provisioner creates a PV → PV is **bound**
to the PVC → the pod mounts the PVC.

**`WaitForFirstConsumer` is the field that matters.** With `Immediate` binding
the provisioner would pick a node before the scheduler did, and could create the
directory on a node the pod can never run on — instant deadlock. So a `Pending`
PVC with no pod is **correct, not broken**.

### Node-local limitations, stated plainly

1. **The volume exists on exactly one node.** The PV carries a `nodeAffinity`
   permitting only that node; every pod using it is pinned there forever.
2. **A lost node is lost data.** No replication, no rebuild.
3. **A cordoned, tainted or full node means a `Pending` pod** — it will not fail
   over, it waits. *This one is demonstrated for real in step 13.*
4. **`ReadWriteOnce` only.** `ReadWriteMany` is not merely unsupported, it is
   meaningless. (Multiple pods *on the same node* can share it — RWO is
   per-node, not per-pod.)
5. **The requested size is bookkeeping, not a quota.** A hostpath PV is a plain
   directory. A pod can write 50 GiB into a "1Gi" volume and will keep going
   until the **node's** disk fills, taking the kubelet and every other pod on
   that node with it. Enforcement needs LVM or ZFS LocalPV.
6. **No snapshots, clones, or online expansion** — those need a CSI driver.
7. **`reclaimPolicy: Delete` really deletes.** Removing the PVC runs a helper pod
   that erases the directory. Use `Retain` for anything you care about.

### The test

```sh
# 1. a PVC with nothing consuming it -- Pending is CORRECT
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: storage-test}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: localpv-test, namespace: storage-test}
spec:
  storageClassName: openebs-hostpath
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
EOF
kubectl -n storage-test get pvc localpv-test          # STATUS: Pending

# 2. scheduling a pod is what binds it
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata: {name: storage-writer, namespace: storage-test}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: writer
          image: busybox:1.37
          command: ["sh","-c"]
          args:
            - |
              printf 'persisted-by=%s node=%s\n' "$HOSTNAME" "$NODE_NAME" > /data/witness.txt
              dd if=/dev/urandom of=/data/blob.bin bs=1k count=256 2>/dev/null
              sync; cat /data/witness.txt; md5sum /data/blob.bin
          env:
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          volumeMounts: [{name: data, mountPath: /data}]
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: localpv-test}
EOF
kubectl -n storage-test wait --for=condition=complete job/storage-writer --timeout=300s
kubectl -n storage-test logs job/storage-writer

# 3. where the bytes actually live
kubectl -n storage-test get pvc localpv-test          # STATUS: Bound
PV=$(kubectl -n storage-test get pvc localpv-test -o jsonpath='{.spec.volumeName}')
NODE=$(kubectl get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
HP=$(kubectl get pv "$PV" -o jsonpath='{.spec.local.path}')
echo "PV=$PV  pinned-to=$NODE  path=$HP"
orb -m "$NODE" -u root ls -la "$HP"        # the "persistent volume" is a directory

# 4. destroy the pod, read with a DIFFERENT one
kubectl -n storage-test delete job storage-writer --wait=true
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata: {name: storage-reader, namespace: storage-test}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: reader
          image: busybox:1.37
          command: ["sh","-c"]
          args:
            - |
              echo "read by pod : $HOSTNAME"
              echo "read on node: $NODE_NAME"
              cat /data/witness.txt; md5sum /data/blob.bin
              test -s /data/witness.txt || { echo "DATA LOST"; exit 1; }
              echo "OK: data survived the writer pod"
          env:
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          volumeMounts: [{name: data, mountPath: /data}]
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: localpv-test}
EOF
kubectl -n storage-test wait --for=condition=complete job/storage-reader --timeout=300s
kubectl -n storage-test logs job/storage-reader
```

Verified output — same md5, different pod, necessarily the same node:

```
# writer
persisted-by=storage-writer-wmtx8 node=k3s-worker-1
d2c67b7d5c71c81fc578925ed9cefa8f  /data/blob.bin

# PV
PV=pvc-da7a6586-...  pinned-to=k3s-worker-1  path=/var/openebs/local/pvc-da7a6586-...

# reader
read by pod : storage-reader-879lf
read on node: k3s-worker-1
persisted-by=storage-writer-wmtx8 node=k3s-worker-1
d2c67b7d5c71c81fc578925ed9cefa8f  /data/blob.bin
OK: data survived the writer pod
```

Clean up (this erases the directory — `reclaimPolicy: Delete` doing its job):

```sh
kubectl delete ns storage-test
```

---

## 13. Sample application and end-to-end test

Deliberately trivial, because its job is to touch every component at once.

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: demo}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: demo-data, namespace: demo}
spec:
  storageClassName: openebs-hostpath
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: demo-web, namespace: demo}
spec:
  replicas: 1
  # Recreate, not RollingUpdate: the volume is RWO and pinned by nodeAffinity to
  # one node, so a surge pod elsewhere could never mount it and the rollout wedges.
  strategy: {type: Recreate}
  selector: {matchLabels: {app: demo-web}}
  template:
    metadata: {labels: {app: demo-web}}
    spec:
      # Writes the page into the volume once. The timestamp it records is what
      # proves, after a pod delete, that you are seeing the ORIGINAL data.
      initContainers:
        - name: seed
          image: busybox:1.37
          command: ["sh","-c"]
          args:
            - |
              if [ ! -f /data/index.html ]; then
                {
                  echo "<!doctype html><title>k3s-lab</title><h1>k3s-lab is up</h1><ul>"
                  echo "<li>seeded by pod: $HOSTNAME</li>"
                  echo "<li>seeded on node: $NODE_NAME</li>"
                  echo "<li>seeded at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')</li>"
                  echo "</ul><p>Served from an OpenEBS LocalPV volume.</p>"
                } > /data/index.html
              fi
              echo ok > /data/healthz
          env:
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          volumeMounts: [{name: data, mountPath: /data}]
      containers:
        - name: nginx
          image: nginx:1.29-alpine
          ports: [{name: http, containerPort: 80}]
          volumeMounts: [{name: data, mountPath: /usr/share/nginx/html}]
          readinessProbe: {httpGet: {path: /healthz, port: http}, initialDelaySeconds: 2, periodSeconds: 5}
          resources:
            requests: {cpu: 25m, memory: 32Mi}
            limits:   {memory: 96Mi}
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: demo-data}
---
apiVersion: v1
kind: Service
metadata: {name: demo-web, namespace: demo}
spec:
  # ClusterIP, not LoadBalancer: only the ingress controller needs an external
  # address; everything behind it is reached through that one IP.
  type: ClusterIP
  selector: {app: demo-web}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo
  namespace: demo
  annotations:
    # /demo/foo at the edge must reach the app as /foo -- nginx knows nothing
    # about a /demo prefix. $2 is the second capture group below.
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    # NO host. A host-less rule matches any Host header -- exactly what you want
    # when the client types a bare IP, because then there is no name to match.
    - http:
        paths:
          # ImplementationSpecific (not Prefix) is required for capture groups.
          - path: /demo(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service: {name: demo-web, port: {name: http}}
EOF

kubectl -n demo rollout status deploy/demo-web --timeout=420s
kubectl -n demo get pods,svc,ingress,pvc -o wide
```

### The end-to-end test

```sh
export INGRESS_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
curl -sS -m 15 "http://${INGRESS_IP}/demo/"
```

Verified output:

```html
<!doctype html><title>k3s-lab</title><h1>k3s-lab is up</h1><ul>
<li>seeded by pod: demo-web-54647ff455-tdrgn</li>
<li>seeded on node: k3s-worker-2</li>
<li>seeded at: 2026-08-16T13:02:11Z</li>
</ul><p>Served from an OpenEBS LocalPV volume.</p>
```

That single response exercised macOS → ARP/MetalLB → kube-proxy → ingress-nginx
→ CoreDNS → Calico overlay → pod → LocalPV.

### The persistence half

```sh
BEFORE="$(curl -sS "http://${INGRESS_IP}/demo/" | grep -o 'seeded at: [^<]*')"
kubectl -n demo delete pod -l app=demo-web --wait=true
kubectl -n demo rollout status deploy/demo-web --timeout=300s

# `rollout status` returns when the POD is ready, which is a beat before
# ingress-nginx has re-synced its endpoint to the new pod IP. Curling straight
# through returns 503, and the comparison below then reports a data loss that
# did not happen. Measured here: ~1-2s, but it is never zero.
for i in $(seq 1 30); do
  [ "$(curl -sS -o /dev/null -w '%{http_code}' -m 10 "http://${INGRESS_IP}/demo/")" = "200" ] && break
  sleep 2
done

AFTER="$(curl -sS "http://${INGRESS_IP}/demo/" | grep -o 'seeded at: [^<]*')"
echo "before: $BEFORE"; echo "after : $AFTER"
# -n guards the false PASS: if the ingress is down both sides are empty and
# an equality test alone would happily call that a success.
[ -n "$AFTER" ] && [ "$BEFORE" = "$AFTER" ] \
  && echo "PASS -- served off the persistent volume" || echo "FAIL"
```

```
before: seeded at: 2026-08-16T13:02:11Z
after : seeded at: 2026-08-16T13:02:11Z
PASS -- served off the persistent volume
```

### Worked example: limitation 3, for real

While writing this, the demo PVC bound while its pod was scheduled to
`k3s-server`, *before* the control-plane taint was applied. Tainting the node
then left the pod unschedulable **anywhere**:

```
0/3 nodes are available: 1 node(s) had untolerated taint(s),
2 node(s) didn't match PersistentVolume's node affinity.
```

The PV was pinned to `k3s-server`; the taint forbade running there; the other
two nodes were forbidden by the PV. There is no migration for node-local
storage — the only fix is to delete the PVC and let it re-provision:

```sh
kubectl delete ns demo      # deletes the PVC -> deletes the PV -> re-provisions on reapply
```

This is exactly why step 3 applies the taint **at install time**.

---

## 14. Full-stack verification

```sh
export KUBECONFIG=~/.kube/k3s-lab.yaml

echo "--- 1. nodes ---"
kubectl get nodes -o wide
kubectl get node k3s-server -o jsonpath='{.spec.taints}{"\n"}'   # CriticalAddonsOnly

echo "--- 2. nothing bundled survived ---"
kubectl -n kube-system get deploy traefik 2>&1 | tail -1        # NotFound
kubectl get sc local-path 2>&1 | tail -1                        # NotFound
kubectl get ds -A | grep svclb || echo "no ServiceLB: ok"
orb -m k3s-server -u root ip link show flannel.1 2>&1 | tail -1 # does not exist

echo "--- 3. all pods ---"
kubectl get pods -A -o wide | grep -v Completed

echo "--- 4. Calico ---"
kubectl get ippools.crd.projectcalico.org -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidr,VXLAN:.spec.vxlanMode

echo "--- 5. DNS ---"
kubectl -n kube-system get svc kube-dns                          # 10.43.0.10
kubectl run dnschk --rm -i --restart=Never --image=busybox:1.37 --command -- \
  nslookup kubernetes.default.svc.cluster.local

echo "--- 6. MetalLB + Ingress ---"
kubectl -n metallb-system get ipaddresspools.metallb.io
kubectl get ingressclass

echo "--- 7. storage ---"
kubectl get sc openebs-hostpath

echo "--- 8. end to end ---"
curl -sS -m 15 "http://${INGRESS_IP}/demo/" | head -3

echo "--- 9. headroom (shared kernel: all three report the same) ---"
for m in k3s-server k3s-worker-1 k3s-worker-2; do
  printf '%-14s %s\n' "$m" "$(orb -m $m -u root sh -c \
    'printf "load=%s memavail=%sMB" "$(cut -d\  -f1 /proc/loadavg)" "$(awk "/MemAvailable/{print int(\$2/1024)}" /proc/meminfo)"')"
done
```

Steady state on the tested cluster: 15 pods running, load ~2, ~4 GB available.

---

## 15. Argo Rollouts

Install **before** Argo CD syncs the app — the chart renders a `Rollout`, and
without these CRDs Argo CD fails with `no matches for kind "Rollout"`.

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add jenkins https://charts.jenkins.io
helm repo update

helm upgrade --install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts --create-namespace \
  --version 2.41.1 \
  --set dashboard.enabled=true \
  --set controller.replicas=1 \
  --wait --timeout 8m

kubectl get crd rollouts.argoproj.io
```

`dashboard.enabled=true` is not optional, but not because you visit it. It is
the API the Argo CD rollout extension proxies to — the canary controls in the
Argo CD UI are dead without it. It needs no ingress of its own.

---

## 16. Argo CD

Reached at `http://<METALLB-IP>/argocd`, no DNS and no `/etc/hosts`.

```sh
cat <<'EOF' | helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace --version 10.3.3 -f - --wait --timeout 12m
# Required for a host-less Ingress rule. server.ingress.hostname: "" alone is
# NOT enough -- the chart falls back to global.domain, default
# argocd.example.com, giving a hostname-bound rule that answers nothing on an
# IP. Blanking both is what produces HOSTS `*`.
global:
  domain: ""

configs:
  params:
    # Plain HTTP. Otherwise argocd-server serves a self-signed cert and every
    # port-forward, CLI call and ingress hop needs --insecure.
    server.insecure: true
    # rootpath: argocd-server strips /argocd itself and serves the subtree --
    # which is why there is NO rewrite-target annotation below.
    # basehref: rewrites <base href> in index.html so the UI's relative asset
    # and API URLs resolve under /argocd.
    # Set only rootpath and you get a blank white page: the HTML arrives, then
    # every JS/CSS request goes to /assets/... and 404s.
    server.rootpath: /argocd
    server.basehref: /argocd
  cm:
    # GitHub cannot reach a laptop cluster, so webhooks are out and polling is
    # the only trigger. 60s instead of the 180s default.
    timeout.reconciliation: 60s
    timeout.reconciliation.jitter: 10s
    # Lets argocd-server proxy UI calls to the Rollouts dashboard API. Without
    # it the canary controls in the Argo CD UI are dead.
    extension.config: |
      extensions:
        - name: rollout
          backend:
            services:
              - url: http://argo-rollouts-dashboard.argo-rollouts.svc.cluster.local:3100

server:
  replicas: 1
  ingress:
    enabled: true
    ingressClassName: nginx
    path: /argocd
    # Prefix, not a regex: rootpath means the backend wants the prefix left on.
    pathType: Prefix
    hostname: ""
  # initContainer that downloads the rollout extension bundle into
  # argocd-server. Keep it INSIDE this single `server:` block -- a second
  # top-level `server:` key silently wins and drops everything above it.
  extensions:
    enabled: true
    extensionList:
      - name: rollout-extension
        env:
          - name: EXTENSION_URL
            value: https://github.com/argoproj-labs/rollout-extension/releases/download/v0.4.0/extension.tar

redis-ha: {enabled: false}
controller:
  replicas: 1
repoServer:
  replicas: 1
  # The chart ships timeoutSeconds: 1 on both probes. On hardware this slow
  # that is not enough for repo-server to answer /healthz while it is still
  # starting, so the kubelet kills it mid-boot and it never finishes -- a
  # CrashLoopBackOff whose containers all exit 0, because nothing crashed.
  # See "argocd-repo-server CrashLoopBackOff with exit 0" in troubleshooting.
  livenessProbe:
    initialDelaySeconds: 30
    timeoutSeconds: 10
    periodSeconds: 20
    failureThreshold: 6
  readinessProbe:
    initialDelaySeconds: 20
    timeoutSeconds: 10
    failureThreshold: 6

# ~100-150 MB each, unused here.
dex: {enabled: false}
notifications: {enabled: false}
EOF
```

> **Trap 6 — `applicationSet.enabled: false` does nothing in chart 10.3.3.**
> That block has `name`, `replicas`, `runtimeClassName` … and no `enabled` key,
> and Helm accepts unknown values in silence. You set it, the controller starts
> anyway, and you are ~80 MB down without a hint why. Nothing here uses
> ApplicationSet — we sync one plain `Application` — so scale it away:
> ```sh
> kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0
> ```

Verify — `HOSTS` must be `*`, not a hostname:

```sh
kubectl get ingress -n argocd
curl -sS -o /dev/null -w 'argocd HTTP %{http_code}\n' "http://${INGRESS_IP}/argocd"
```

```
NAME            CLASS   HOSTS   ADDRESS           PORTS
argocd-server   nginx   *       192.168.139.241   80

argocd HTTP 307
```

**307 is correct** — argocd-server redirecting to `/argocd/login`. The admin
password is generated at install:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in as `admin`, then delete that secret once you have changed the password.

---

## 17. Jenkins — and why there is no Docker socket

> **Trap 7 — the docker-socket pattern does not exist on K3s.** Every Jenkins-on-
> Kubernetes guide mounts `/var/run/docker.sock` into the controller so
> `docker build` works. K3s runs **containerd**: there is no socket to mount and
> no `docker` binary on the nodes. Mounting the Mac's OrbStack socket through
> `/mnt/mac` does not work either — a unix socket is not a file you can pass
> across that boundary. The build engine has to change, not the mount. See
> step 19: we build with **Kaniko**.

```sh
export INGRESS_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

cat <<'EOF' | helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins --create-namespace --version 5.9.54 -f - \
  --set controller.jenkinsUrl="http://${INGRESS_IP}/jenkins" \
  --wait --timeout 15m
controller:
  # Carries helm, trivy, cosign and git. The build pod in the Jenkinsfile runs
  # the SAME image as its `tools` container, so the toolchain is pinned once.
  image:
    registry: docker.io
    repository: jahadulrakib/jenkins-devops-kubernetes
    tag: lts-jdk21
    pullPolicy: IfNotPresent

  # 0, not 2: every build runs in its own agent pod (Kaniko needs its own
  # container). Executors on the controller would let a job run beside the JVM
  # and compete with it for the little CPU this VM has.
  numExecutors: 0

  # THE load-bearing setting. Appends --prefix=/jenkins to the JVM, so Jenkins
  # serves under /jenkins and generates every internal link, redirect and asset
  # URL with the prefix already on. This is why there is NO rewrite-target
  # annotation -- the backend genuinely expects /jenkins/...
  # It fixes the probes for free: the chart templates them as
  # `{{ default "" .Values.controller.jenkinsUriPrefix }}/login`.
  jenkinsUriPrefix: /jenkins

  # 896m is a FLOOR, not a preference -- see "the agent connects but the build
  # never starts" in troubleshooting. 512m looks like it works (UI serves, pod
  # 1/1 Ready, plugins load) and then silently cannot launch a build agent: the
  # kubernetes plugin's remoting handshake needs headroom the GC never gives it.
  #
  # With no Kubernetes memory limit set (see the sizing note), this line is the
  # ONLY thing bounding the controller. Real usage lands ~100-200 MB above the
  # heap -- metaspace, thread stacks, code cache -- so budget ~1.1 GB for it.
  javaOpts: "-Xms256m -Xmx896m"

  ingress:
    enabled: true
    ingressClassName: nginx
    path: /jenkins
    # Prefix: /jenkins must also match /jenkins/login, /jenkins/static/...
    pathType: Prefix
    annotations:
      # Plugin .hpi uploads exceed nginx's 1m default and fail with 413.
      nginx.ingress.kubernetes.io/proxy-body-size: 50m
      # Long-poll and CLI-over-HTTP idle well past the 60s default.
      nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
      nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"

  # installPlugins is left unset ON PURPOSE -- setting it REPLACES the chart's
  # four pinned defaults (kubernetes, workflow-aggregator, git,
  # configuration-as-code); additionalPlugins layers on top and keeps them.
  additionalPlugins:
    - timestamper:latest          # backs options { timestamps() }
    - credentials-binding:latest  # withCredentials() in Push/Sign/GitOps
    - github:latest
    - antisamy-markup-formatter:latest

# Dynamic pods per build -- this is what replaces the docker socket.
agent:
  enabled: true
  namespace: jenkins
  # REQUIRED here. Without it agents connect over raw TCP to jenkins-agent:50000,
  # print "Connected", and never register -- the build then waits forever on
  # "Waiting for agent to connect (n/1,000)". WebSocket tunnels remoting over the
  # same HTTP port the UI uses. See "the agent connects but the build never
  # starts" in troubleshooting.
  websocket: true

persistence:
  # NOT "standard" -- that class exists on kind, not here. Step 11 installed
  # openebs-hostpath, and a PVC naming a class that does not exist sits Pending
  # forever with the pod stuck in ContainerCreating.
  storageClass: openebs-hostpath
  size: 8Gi

rbac: {create: true}
serviceAccountAgent:
  create: true
  name: jenkins-agent
EOF

kubectl -n jenkins get pods,pvc
```

Jenkins is at `http://<METALLB-IP>/jenkins`. The initial admin password:

```sh
kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

### Sizing — read this before you install it on 8 GB

Jenkins is the single largest consumer in this document: a 1 GB heap, a 1.6 GB
limit, and a JVM that pins a core while it boots. On the 8 GB machine this was
written on, installing it alongside the platform produced:

```
load average 21.6         macOS: 117M unused, 4793M of 6144M swap used
argocd-repo-server        CrashLoopBackOff (7 restarts)
coredns, metallb, tigera-operator, openebs   all restarting
```

Nothing was misconfigured — the machine was out of memory and swap thrash
starved the liveness probes.

**The one control that matters is `javaOpts`, not Kubernetes resources.** The
values in this document deliberately set **no** `resources:` requests or limits:
numbers tuned for an 8 GB laptop are wrong on any other cluster, and this chart
set is meant to install anywhere. `-Xmx` bounds the JVM directly and travels
fine, because it describes the process rather than the machine.

Know what you give up. Without `requests`, the scheduler treats every pod as
costing nothing and will happily stack Jenkins, ingress-nginx, CoreDNS and the
Argo CD controller onto one node. That is not hypothetical — it is what happened
here, and the node went `NotReady` with its containerd wedged:

```
E kubelet.go:2646 "Skipping pod synchronization"
  err="[container runtime is down, PLEG is not healthy: pleg was last seen
       active 7m29s ago; threshold is 3m0s]"
```

Recovery is a service restart, not a rebuild — see the troubleshooting entry:

```sh
orb -m k3s-worker-1 -u root systemctl restart k3s-agent
```

If you would rather have the guardrails than the portability, add them at
install time instead of committing them:

```sh
helm upgrade jenkins jenkins/jenkins -n jenkins --version 5.9.54 --reuse-values \
  --set controller.resources.requests.cpu=150m \
  --set controller.resources.requests.memory=640Mi \
  --set controller.resources.limits.memory=1Gi
```

Measuring rather than guessing is what makes either choice informed. Actual
container memory across all three nodes, with the whole platform running:

```sh
for m in k3s-server k3s-worker-1 k3s-worker-2; do
  orb -m "$m" -u root k3s crictl stats --output table
done
```

```
application-controller   133.8MB     calico-node (x3)   ~71MB each
tigera-operator          104.2MB     coredns (x2)       ~31MB each
ingress-nginx            105.1MB     calico-typha (x2)  ~31MB each
calico-kube-controllers   80.9MB     speaker (x3)       ~42MB each
argocd-server             78.0MB     repo-server         42.0MB
                                     ~1.15 GB total
```

The platform is **not** what is heavy — it is ~1.15 GB. The 1 GB Jenkins heap
was, and it landed while a 1 GB image was still being pulled. At `-Xmx512m` the
controller sits around 600 MB, total container memory lands near 1.8 GB in a
5992 MB VM, and it holds.

Two things still worth knowing on 8 GB:

- **macOS gets whatever the VM does not, and there is no "unlimited" setting.**
  `orb config set memory_mib 0` is rejected outright — `memory must be at least
  500 MiB`. You are choosing a split, not opting out of one. At `6144` of 8 GB
  the host is left ~2 GB, which is why the compressor and swap were the first
  things to suffer; `5120` gives macOS a GB back and the cluster still fits in
  the ~3.3 GB it actually uses. (`orb config reset` does remove the setting, but
  it resets **everything**, including `network.subnet4` — which renumbers the
  nodes and invalidates both the kubeconfig and the MetalLB pool. Not worth it.)
- **Builds are the spike, not steady state.** A Kaniko pod adds ~1.5 GB while it
  runs. `numExecutors: 0` keeps that off the controller, but do not expect to
  run two builds at once here — `disableConcurrentBuilds()` in the Jenkinsfile
  is load-bearing on this hardware, not just hygiene.

**The honest summary:** 8 GB runs the platform comfortably and the platform plus
CI/CD only just. Expect the occasional wedged node under build load, and know
that the fix is `systemctl restart k3s-agent` rather than anything structural.
16 GB removes the whole class of problem.

---

## 18. Credentials

Four things, and none of them belong in git. Every `read -rs` below reads with
echo off, so nothing reaches your shell history or the process list.

> **If you are copying this setup from `abc_local_setup/local-kind-setup.md`,
> rotate first.** That document has a GitHub PAT, a Docker Hub PAT and a cosign
> key password written into it in plaintext, and it is committed to the repo.
> Anything ever pushed to a public remote must be treated as disclosed.

### 18.1 Argo CD repository credential

Only needed for a **private** repo — Argo CD clones anonymously otherwise. It is
a bootstrap credential: it cannot come from the chart, because Argo CD needs it
to clone the repo that holds the chart.

```sh
read -rs -p 'GitHub PAT (repo scope): ' GH_PAT; echo

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: notes-app-repo
  namespace: argocd
  labels:
    # Argo CD ignores the Secret entirely without this label -- the clone then
    # fails exactly as if it did not exist.
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  # Must match spec.source.repoURL in argocd/application.yaml byte for byte --
  # scheme and trailing .git included.
  url: https://github.com/Jahadul-Rakib/test-app.git
  username: Jahadul-Rakib
  password: ${GH_PAT}
EOF

unset GH_PAT
```

Check it in the UI under **Settings → Repositories**: `CONNECTION STATUS` must
read `Successful`. `Failed` almost always means `url` does not match `repoURL`.

### 18.2 Docker Hub pull secret — only for a private image

`helm/notes-app/values.yaml` ships `imagePullSecrets: []` so the chart installs
anywhere. If the image repo is private, create the secret **in the namespace the
pod runs in** — it is read by the kubelet, not by Helm or Argo CD:

```sh
read -rs -p 'Docker Hub token: ' DH_TOKEN; echo

kubectl create secret docker-registry dockerhub-pull \
  --namespace default \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=jahadulrakib \
  --docker-password="${DH_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

unset DH_TOKEN
```

Then set `imagePullSecrets: [{name: dockerhub-pull}]` in values.yaml. The
`--dry-run | apply` pipe is what makes it re-runnable — plain `kubectl create
secret` fails with `AlreadyExists` on a rotation.

### 18.3 Jenkins credentials

**All three steps in this section are scripted.** From the repo root:

```sh
./k3s-lab/setup-credentials.sh
```

It prompts for the two tokens with echo off, creates both Secrets, and re-runs
`helm upgrade` so **JCasC** turns them into real Jenkins credentials. Doing it
declaratively rather than clicking in the UI is what makes them survive a pod
restart or a PVC rebuild — `additionalExistingSecrets` mounts each key under
`/run/secrets/additional/`, where JCasC reads it as `${<secret>-<key>}`.

The rest of this section is what the script does, if you would rather do it by
hand at **Manage Jenkins → Credentials → System → Global**. The IDs must match
exactly — the `Jenkinsfile` looks them up by ID:

| ID | Kind | Username | Content |
|---|---|---|---|
| `github-token` | Username with password | `Jahadul-Rakib` | GitHub PAT, **write** `repo` scope |
| `dockerhub` | Username with password | `jahadulrakib` | Docker Hub access token |
| `cosign-key` | Secret text | — | the whole `cosign.key` PEM, markers included |
| `cosign-key-password` | Secret text | — | the key's password |

`github-token` needs **write** scope: `Update GitOps` commits the image tag back.

> Jenkins renders *Secret text* as a single-line field, so a multi-line PEM
> arrives with its newlines stripped and cosign rejects it with
> `reading key: invalid pem block`. The `Sign Image` stage repairs that — it
> locates the BEGIN/END markers and rebuilds the PEM. What it cannot repair is a
> **truncated** paste. To sidestep the field entirely, use a *Secret file*
> credential and change the binding to
> `file(credentialsId: ..., variable: 'COSIGN_KEY_FILE')`.

---

## 19. The pipeline — Jenkins builds, Argo CD deploys

Jenkins never talks to the Kubernetes API. It builds an image, pushes it, and
commits the new tag to git; Argo CD — running *inside* the cluster — notices the
commit and syncs. That split is why this works with no inbound route to the
cluster and no kubeconfig in CI.

```
git push
   │
   ▼
Jenkins (polls SCM, 60s)
   │  1. Registry Auth   one config.json for the whole pod
   │  2. Build           kaniko  -> image.tar        (NOT pushed yet)
   │  3. Scan            trivy --input image.tar     (the gate)
   │  4. Validate        helm lint + template
   │  5. Push            crane push image.tar        (the scanned bytes)
   │  6. Sign            cosign sign + attach sbom
   │  7. Update GitOps   sed the tag into values.yaml, commit, push
   ▼
git (helm/notes-app/values.yaml now names the new tag)
   │
   ▼
Argo CD  polls every 60s -> syncs the chart
   │
   ▼
Argo Rollouts  canary: 25% -> 50% -> 75% -> 100%
   │
   ▼
http://<METALLB-IP>/app
```

### Why Kaniko, and why a tarball

`docker build` needs a daemon; there is none (step 17). Kaniko builds an OCI
image from a Dockerfile inside an ordinary unprivileged container.

Kaniko's usual mode builds **and pushes** in one shot — which would publish an
unscanned image and only then let Trivy look at it. Building to a tarball first
keeps the original ordering, and is stricter than the docker version ever was:

> `crane push` uploads the exact bytes Trivy scanned, not a rebuild that might
> differ.

The three containers in the build pod share `/home/jenkins/agent`, so the
tarball moves between them with no artifact passing:

| Container | Image | Job |
|---|---|---|
| `tools` | `jahadulrakib/jenkins-devops-kubernetes:lts-jdk21` | git, helm, trivy, cosign |
| `kaniko` | `gcr.io/kaniko-project/executor:v1.23.2-debug` | build → `image.tar` |
| `crane` | `gcr.io/go-containerregistry/crane:debug` | push the tarball |

Three details that bite:

- **Kaniko is distroless.** There is no `/bin/sh`; the step runs
  `#!/busybox/sh`, and the pod keeps it alive with `command: ["/busybox/cat"]`
  plus `tty: true`.
- **Kaniko must run as root** (`runAsUser: 0`) because it unpacks base-image
  layers onto the container root filesystem. It does **not** need `privileged`
  or a socket — that is the whole point.
- **Auth is a file, not a `docker login`.** Kaniko, crane and cosign all read
  `$DOCKER_CONFIG/config.json`, written once in the `Registry Auth` stage. Use
  the `https://index.docker.io/v1/` key, not `docker.io` — the latter is read
  without complaint and then 401s on push.

### Point Argo CD at the repo

```sh
kubectl apply -f argocd/application.yaml
kubectl -n argocd get application notes-app
```

The Application is already in the repo. Two settings in it matter:

- `ignoreDifferences` on `Service.spec.selector` **plus**
  `RespectIgnoreDifferences=true`. Argo Rollouts rewrites Service selectors to
  steer a canary; `selfHeal` would revert that mid-rollout and stall it. Without
  the sync option, `ignoreDifferences` only hides the drift and the sync still
  clobbers the selector.
- `CreateNamespace=true` — the destination namespace need not exist first.

### Run it

Create a **Pipeline** job pointing at the repo with *Script Path* `Jenkinsfile`,
or let `pollSCM` pick up the next push. Then watch the handoff:

```sh
# 1. CI: the build pod appears in the jenkins namespace, then goes away
kubectl -n jenkins get pods -w

# 2. the commit Jenkins wrote back
git log --oneline -1 helm/notes-app/values.yaml   # chore(deploy): notes-app -> <sha> [ci skip]

# 3. CD: Argo CD picks it up within 60s
kubectl -n argocd get application notes-app -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'

# 4. the canary stepping through
kubectl argo rollouts get rollout notes-app -n default --watch

# 5. the app
curl -sS "http://${INGRESS_IP}/app/healthz"
```

`[ci skip]` in the write-back message is what stops the pipeline triggering
itself: every stage carries `when { not { changelog '(?s).*\[ci skip\].*' } }`.

---

## Accessing things by IP — and exactly what it costs

Every Ingress rule here is written with **no `host:`**, so it matches any `Host`
header, including the bare IP a browser sends. Routing is by path alone. That
needs no `/etc/hosts` and no DNS. These are the real costs.

**1. You can only distinguish by path.** Host-based virtual hosting is gone —
there is one host, the IP. Every app needs a distinct prefix, and a rule for `/`
matches everything, so it must be the last resort.

**2. Path rewriting breaks apps with absolute URLs.** `/demo/foo` arrives as
`/foo`, but the *app* still emits `/static/app.css` and `Location:` headers that
the browser resolves against the origin, not against `/demo`. The CSS 404s. There
is no ingress-side fix worth having; the fixes are application-side:

| App | Setting |
|---|---|
| Jenkins | `--prefix=/jenkins` / `JENKINS_OPTS` |
| Argo CD | `server.basehref` + `server.rootpath` |
| Grafana | `GF_SERVER_ROOT_URL`, `GF_SERVER_SERVE_FROM_SUB_PATH` |
| Prometheus | `--web.route-prefix` / `--web.external-url` |

**3. TLS is effectively unusable.** Certificates bind to names. An IP certificate
needs an IP SAN, public CAs will not issue one for a private address, and there
is no SNI to choose between certificates — so you get exactly one. HTTPS here
means clicking through a warning for ingress-nginx's fake certificate.

**4. Cookies and CORS get prefix-sensitive.** Session cookies scoped to `/` from
an app served at `/demo` leak across every other app on the same IP; same-origin
means "same IP", so they share an origin.

**5. There is no name to fail over.** An IP is not a CNAME.

### Two escape hatches, neither needing `/etc/hosts`

**A. `sslip.io` — real hostnames, zero setup.** A public wildcard resolver that
returns any address embedded in the name, so you get host-based routing, clean
root paths, no rewrite annotation, and working relative URLs:

```sh
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-host
  namespace: demo
spec:
  ingressClassName: nginx
  rules:
    - host: demo.${INGRESS_IP}.sslip.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: demo-web, port: {name: http}}
EOF
curl -sS "http://demo.${INGRESS_IP}.sslip.io/"
```

It needs internet access and it leaks private addresses into public DNS queries.
Fine for a lab; not at work.

**B. Give the app its own MetalLB address.** Set its Service to
`type: LoadBalancer` and it is served at `/` with no rewriting at all. Costs one
address per app out of the ten in the pool.

---

## Troubleshooting

### Bisect the stack bottom-up — stop at the first failure

```sh
orb list                                                     # L0 machines
orb -m k3s-worker-1 -u root ping -c2 k3s-server.orb.local
orb -m k3s-server -u root systemctl is-active k3s            # L1 control plane
kubectl get --raw='/readyz'
kubectl get nodes                                            # L2 CNI (NotReady = CNI)
kubectl run d --rm -i --restart=Never --image=busybox:1.37 --command -- \
  nslookup kubernetes.default.svc.cluster.local              # L4 DNS
kubectl get svc -A | grep LoadBalancer                       # L6 address
curl -i -m 5 "http://${INGRESS_IP}/demo/"                    # L7 HTTP
```

### "It worked, now the API server times out"

The signature failure on this hardware:

```
Unable to connect to the server: net/http: TLS handshake timeout
```

```sh
orb -m k3s-server -u root cat /proc/loadavg          # >8 on 8 cores = the cause
orb -m k3s-server -u root head -3 /proc/meminfo      # usually NOT the cause
kubectl get pods -A --no-headers | awk '$5>3{print $2, "restarts="$5}'
```

Load spikes come from concurrent image pulls or a reschedule wave. It usually
recovers on its own in a few minutes — **stop running `kubectl` at it, polling
adds load**.

**Two things to know before you start debugging harder:**

*Your apps are probably fine.* The data plane does not depend on the API server.
Observed here, while `kubectl` was timing out from both macOS **and** the server
itself:

```sh
curl -sS "http://${INGRESS_IP}/demo/"     # still HTTP 200, still serving
```

So an unreachable API server is a management-plane outage, not an outage.

*The fix is a service restart, not a machine restart.* After heavy churn the
API server can wedge while the node itself looks fine — load ~4, ~3.7 GB free,
`systemctl is-active k3s` says `active` — and yet even the server's own
`k3s kubectl` hangs for minutes. Restarting the unit clears it in **seconds**:

```sh
orb -m k3s-server -u root systemctl restart k3s
# then wait for it, rather than polling in a tight loop:
until orb -m k3s-server -u root k3s kubectl get --raw='/readyz' >/dev/null 2>&1; do sleep 10; done
kubectl get nodes
```

Only if that fails:

```sh
kubectl get node k3s-server -o jsonpath='{.spec.taints}{"\n"}'   # must be non-empty
kubectl taint nodes k3s-server CriticalAddonsOnly=true:NoExecute --overwrite
orb restart k3s-server                                # heavier hammer; safe, k3s restarts
```

Expect a handful of pods to be `ContainerCreating` or `CrashLoopBackOff` for a
few minutes after any restart while leases are re-acquired. That is convergence,
not breakage — recheck before acting on it.

Components with a leader-election lease (tigera-operator, openebs provisioner,
calico-kube-controllers) log `leader election lost` and restart when the API
stalls. That is a symptom, not the disease.

### A node goes `NotReady` and its containerd stops answering

The failure mode when the host runs out of memory, and the one you are most
likely to hit once Jenkins is installed. The node is up, `k3s-agent` says
`active`, and the kubelet still cannot talk to the container runtime:

```sh
orb -m k3s-worker-1 -u root journalctl -u k3s-agent --no-pager -n 20
```

```
E kubelet.go:2646 "Skipping pod synchronization"
  err="[container runtime is down, PLEG is not healthy: pleg was last seen
       active 7m29s ago; threshold is 3m0s]"
E remote_runtime.go:801 "Status from runtime service failed"
  err="rpc error: code = DeadlineExceeded desc = context deadline exceeded"
```

`DeadlineExceeded` on *every* runtime call means containerd is starved, not
crashed — on this setup that is macOS swap thrash, not anything in the cluster.
Confirm from the host side:

```sh
top -l 1 -s 0 | grep PhysMem      # "compressor" climbing, "unused" near zero
sysctl -n vm.swapusage            # used approaching total
```

The fix is a service restart, and it takes seconds:

```sh
orb -m k3s-worker-1 -u root systemctl restart k3s-agent
```

Expect pods to reschedule for a few minutes afterwards. **If the node flaps back
to `NotReady` within the hour, the restart is treating a symptom** — give macOS
memory back instead (`orb config set memory_mib 5120`, then `orb stop && orb
start`, which is the only way the setting applies). On the machine this was
written on that single change took the compressor from 3696 MB to 1205 MB.

### `argocd-repo-server` CrashLoopBackOff, but every container exited 0

A crash loop where nothing crashed. The give-away is the termination reason:

```sh
kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server \
  -o jsonpath='{range .items[0].status.containerStatuses[*]}reason={.lastState.terminated.reason} exit={.lastState.terminated.exitCode}{"\n"}{end}'
```

```
reason=Completed exit=0
```

`Completed exit=0` in a CrashLoopBackOff means the **kubelet** stopped it, not
the process. The events say why:

```
Warning  Unhealthy  Readiness probe failed: dial tcp 10.42.198.33:8084: connect: connection refused
Warning  Unhealthy  Liveness probe failed: context deadline exceeded
Normal   Killing    Container repo-server failed liveness probe, will be restarted
```

The chart's default `timeoutSeconds: 1` is too tight for this hardware: the
container cannot answer `/healthz` while it is still starting, so the liveness
probe kills it before it ever becomes ready, forever. Loosen the probes — this
is a timing problem, not a memory one, and no resource change fixes it:

```sh
helm upgrade argocd argo/argo-cd -n argocd --version 10.3.3 --reuse-values \
  --set repoServer.livenessProbe.initialDelaySeconds=30 \
  --set repoServer.livenessProbe.timeoutSeconds=10 \
  --set repoServer.livenessProbe.periodSeconds=20 \
  --set repoServer.livenessProbe.failureThreshold=6 \
  --set repoServer.readinessProbe.initialDelaySeconds=20 \
  --set repoServer.readinessProbe.timeoutSeconds=10 \
  --set repoServer.readinessProbe.failureThreshold=6
```

The same reasoning applies to any component that crash-loops with `exit 0`
after the cluster gets busy — check the probe before you touch anything else.

### The agent connects, but the build never starts

The most misleading failure in this document, because **both sides report
success**. The agent's own log says it connected:

```sh
kubectl -n jenkins logs <build-pod> -c jnlp --tail=5
```
```
INFO: Remote identity confirmed: 76:45:67:b3:fe:87:21:15:31:60:6e:65:75:ed:05:20
INFO: Connected
```

The build pod is `4/4 Running`. And the controller sits there forever:

```sh
kubectl -n jenkins logs jenkins-0 -c jenkins --tail=200 | grep 'Waiting for agent'
```
```
o.c.j.p.k.KubernetesLauncher#launch: Waiting for agent to connect (208/1,000): notes-app-1-...
```

`kubectl -n jenkins get pod` looks perfect, so the instinct is to blame the pod
template. It is not the pod, and it is not memory either.

**The cause is the JNLP transport.** By default agents connect over raw TCP to
the `jenkins-agent` Service on port 50000. On this cluster that connection
completes far enough for the agent to confirm the controller's identity and
print `Connected`, and then never finishes registering — so the computer stays
`offline: true` with an **empty** `offlineCauseReason`, which is the tell: the
controller has no error to report because nothing errored.

Switch agents to WebSocket, which tunnels remoting over the same HTTP port the
UI uses and needs no 50000 path at all:

```sh
helm upgrade jenkins jenkins/jenkins -n jenkins --version 5.9.54 --reuse-values \
  --set agent.websocket=true \
  --set controller.jenkinsUrl="http://${INGRESS_IP}/jenkins"
```

The agent log changes from `Connecting to jenkins-agent...:50000` to:

```
INFO: WebSocket connection open
INFO: Connected
```

and the build starts. No restart of the controller is needed — the cloud config
reloads on its own.

> **A red herring worth naming.** When this was first hit, the controller was at
> **571 MB RSS against `-Xmx512m`**, which looks exactly like GC starvation and
> is a very satisfying explanation. Raising the heap to 896m did not fix it —
> the next build sat at 562 MB with plenty of headroom and hung identically.
> Memory pressure is real on this machine and worth fixing on its own merits,
> but it was not this. If the agent prints `Connected` and the controller still
> waits, look at the transport before the heap.

### The Build Image stage dumps kaniko's help text and fails

There is no error message in the log — just kaniko's entire flag reference,
then `script returned exit code 1`. That **is** the error: kaniko responds to an
unrecognised flag by printing usage and exiting 1, and it never names the flag
it did not like.

Read the dump for the flag you *meant* to pass and check the spelling:

```
--tar-path string   Path to save the image in as a tarball instead of pushing
--tarPath string    This flag is deprecated. Please use '--tar-path'.
```

`--tarball-path` is wrong and cost a full build cycle here. The same trap
applies to `--snapshot-mode` (not `--snapshotMode`) and `--log-format`. When a
kaniko stage fails with a wall of usage text, diff your flags against that dump
before suspecting the registry, the context path, or permissions.

### "Everything broke after a Mac reboot"

OrbStack renumbered the machines by DHCP; `--node-ip` and the kubeconfig are now
wrong.

```sh
orb list                                    # compare against:
kubectl get nodes -o wide                   # INTERNAL-IP
```

Re-run step 5 (kubeconfig) and step 6 (pool). If the *node* addresses changed,
rebuild — which is why step 4 joins workers by `.orb.local` name where possible.

### MetalLB address assigned but macOS cannot reach it

```sh
kubectl -n metallb-system logs -l component=speaker --tail=50 | grep -i announc
arp -n "$INGRESS_IP"
orb -m k3s-worker-1 -u root curl -sS -m5 -o /dev/null -w '%{http_code}\n' "http://${INGRESS_IP}/"
```

Reachable from a node but not macOS = ARP on the bridge, not Kubernetes. The
fallback that always works — publish on a `hostPort` and use a node's own
address, which OrbStack routes unconditionally:

```sh
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.15.1 --namespace ingress-nginx --reuse-values \
  --set controller.kind=DaemonSet \
  --set controller.hostPort.enabled=true \
  --set controller.hostPort.ports.http=80 \
  --set controller.hostPort.ports.https=443 \
  --set controller.service.type=ClusterIP

curl -sS "http://k3s-worker-1.orb.local/demo/"
```

You lose the dedicated, movable address — the point of MetalLB — so this is a
fallback, not the plan.

### Log quick reference

```sh
orb -m k3s-server   -u root journalctl -u k3s -f
orb -m k3s-worker-1 -u root journalctl -u k3s-agent -f
orb -m k3s-server   -u root k3s check-config
orb -m k3s-server   -u root k3s crictl ps -a

kubectl -n tigera-operator logs deploy/tigera-operator
kubectl -n calico-system   logs ds/calico-node -c calico-node
kubectl -n kube-system     logs -l app.kubernetes.io/name=coredns
kubectl -n metallb-system  logs -l component=speaker
kubectl -n ingress-nginx   logs deploy/ingress-nginx-controller
kubectl -n openebs         logs deploy/openebs-localpv-provisioner

kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl get pods -A -o wide | grep -vE 'Running|Completed'
orb doctor
```

### Symptom index

| Symptom | Cause | Fix |
|---|---|---|
| `k3s.service` dies on start | `/dev/kmsg` missing | rerun step 2 |
| Nodes `NotReady` after install | no CNI yet | expected — step 7 |
| Nodes still `NotReady` after Calico | image pull, or vxlan unsupported | `kubectl -n calico-system get pods -w`; rerun the step 2 probe |
| `no matches for kind "Installation"` | Calico CRDs not pre-installed | step 7.1 |
| Every pod fails DNS | CoreDNS not on `10.43.0.10` | `kubectl -n kube-system get svc kube-dns` |
| `EXTERNAL-IP` stuck `<pending>` | no pool, or exhausted | `kubectl -n metallb-system get ipaddresspools` |
| Address assigned, nothing answers | pool outside the node subnet | redo step 6 |
| Webhook TLS error applying the pool | applied before the webhook was ready | the `until` loop in step 9 |
| `404` from nginx for a path you defined | Ingress not adopted | `kubectl describe ingress`; set `ingressClassName: nginx` |
| `503` from nginx | no ready endpoints | `kubectl get endpoints -n <ns>` |
| Page loads, CSS 404s | absolute URLs vs path prefix | app base-path setting, or sslip.io |
| PVC `Pending`, no pod | `WaitForFirstConsumer` | expected — create the pod |
| Pod `Pending`, "didn't match PersistentVolume's node affinity" | PV pinned to an unusable node | delete the PVC and re-provision |
| Volume "full" early | no quota; the node disk filled | `df -h` on the node |
| `leader election lost` restarts | API server stalling | see the API-timeout section |
| `kubectl` times out but the app still serves | management-plane only | `orb -m k3s-server -u root systemctl restart k3s` |
| Node `NotReady`, `PLEG is not healthy`, runtime `DeadlineExceeded` | containerd starved by host swap thrash | `systemctl restart k3s-agent`; if it recurs, `orb config set memory_mib 5120` |
| Agent logs `Connected`, controller loops `Waiting for agent to connect` | JNLP over TCP 50000 never registers | `--set agent.websocket=true` |
| Build Image stage prints kaniko's whole help text, exit 1 | an unrecognised kaniko flag; it never says which | check flag spelling against the dump (`--tar-path`, not `--tarball-path`) |
| Several unrelated pods restart at once, `exit 0` + `context deadline exceeded` | k3s datastore I/O-starved; `/readyz` fails `etcd-readiness` | reduce load; this is the host, not the pods |
| LB address assigned, ARP `(incomplete)`, works from inside the cluster | speakers restarted and lost the L2 election | `kubectl -n metallb-system rollout restart ds/metallb-speaker` |

---

## Uninstall and rebuild from scratch

Three levels, least destructive first.

```sh
# 1. workloads only -- keeps the platform
kubectl delete ns demo storage-test --ignore-not-found

# 2. the whole platform, keeping K3s
helm -n jenkins uninstall jenkins;              kubectl delete ns jenkins --ignore-not-found
helm -n argocd uninstall argocd;                kubectl delete ns argocd --ignore-not-found
helm -n argo-rollouts uninstall argo-rollouts;  kubectl delete ns argo-rollouts --ignore-not-found
helm -n openebs uninstall openebs;              kubectl delete ns openebs --ignore-not-found
helm -n ingress-nginx uninstall ingress-nginx;  kubectl delete ns ingress-nginx --ignore-not-found
helm -n metallb-system uninstall metallb;       kubectl delete ns metallb-system --ignore-not-found
helm -n kube-system uninstall coredns
helm -n tigera-operator uninstall calico
kubectl delete ns tigera-operator calico-system --ignore-not-found

# 3. K3s itself -- agents first, then the server
orb -m k3s-worker-1 -u root /usr/local/bin/k3s-agent-uninstall.sh
orb -m k3s-worker-2 -u root /usr/local/bin/k3s-agent-uninstall.sh
orb -m k3s-server   -u root /usr/local/bin/k3s-uninstall.sh
for m in k3s-server k3s-worker-1 k3s-worker-2; do
  orb -m "$m" -u root rm -rf /var/openebs /etc/cni/net.d /var/lib/calico /opt/cni/bin
done
rm -f ~/.kube/k3s-lab.yaml

# 4. the machines themselves
orb delete -f k3s-server k3s-worker-1 k3s-worker-2
```

Full rebuild from nothing:

```sh
orb delete -f k3s-server k3s-worker-1 k3s-worker-2
# then start again at step 1
```

**That round trip is the acceptance test for this document.** If it does not
complete without an undocumented manual step, the document has a bug.

If the `tigera-operator` namespace hangs in `Terminating` on a finalizer — only
once the workloads are genuinely gone:

```sh
kubectl get namespace tigera-operator -o json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); d["spec"]["finalizers"]=[]; print(json.dumps(d))' \
  | kubectl replace --raw /api/v1/namespaces/tigera-operator/finalize -f -
```

---

## Version reference

| Component | Pinned | Where it came from |
|---|---|---|
| K3s | `v1.36.3+k3s1` | `https://update.k3s.io/v1-release/channels` (`stable`) |
| Calico / tigera-operator | `v3.32.1` | `helm search repo projectcalico/tigera-operator --versions` |
| CoreDNS chart | `1.47.0` (app `1.14.6`) | `helm search repo coredns/coredns --versions` |
| MetalLB | `0.16.1` | `helm search repo metallb/metallb --versions` |
| ingress-nginx chart | `4.15.1` (app `1.15.1`) | `helm search repo ingress-nginx/ingress-nginx --versions` |
| OpenEBS | `4.5.1` | `helm search repo openebs/openebs --versions` |
| Argo Rollouts | `2.41.1` (app `v1.9.1`) | `helm search repo argo/argo-rollouts --versions` |
| Argo CD | `10.3.3` (app `v3.5.1`) | `helm search repo argo/argo-cd --versions` |
| Jenkins | `5.9.54` (app `2.568.2`) | `helm search repo jenkins/jenkins --versions` |
| Kaniko | `v1.23.2-debug` | `gcr.io/kaniko-project/executor` |
| crane | `debug` | `gcr.io/go-containerregistry/crane` |
| Helm (client) | `3.21.4` | `brew install helm@3` — **not** Helm 4; see below |
| Ubuntu | `24.04` noble, arm64 | `orb create --help` |
| Images | `nginx:1.29-alpine`, `busybox:1.37` | Docker Hub, arm64 confirmed |

> **Helm 3, not Helm 4.** `brew install helm` now gives **4.2.4**. Every chart
> and values file here is Helm 3 idiom, and the cluster carries eight live Helm 3
> releases, so this document pins the 3.x line via the keg-only formula:
> ```sh
> brew install helm@3          # 3.21.4; brew links it ahead of any older binary
> helm version --short
> ```
> Helm 4 is a major-version migration with its own breaking changes — worth
> doing deliberately, not in the middle of a cluster build.

Tested on: MacBook Pro M1, 8 GB, macOS 25.5, OrbStack 2.2.3, kernel
`7.0.14-orbstack`, Ubuntu 24.04.4 LTS, containerd `2.3.2-k3s2`.
