# Local setup from scratch (kind)

Builds the whole stack on a local kind cluster — ingress, Argo CD, Argo
Rollouts, Kyverno, **Jenkins**, credentials, and the app. Everything that ships
a Helm chart is installed with Helm. Every step is a command you can paste; no
files to create by hand.

## Architecture: one IP, path-based routing

Everything is reached through **a single MetalLB LoadBalancer IP**, with
NGINX routing on the URL path:

```
  macOS browser
       │
       │  http://<METALLB-IP>/jenkins
       │  http://<METALLB-IP>/app
       │  http://<METALLB-IP>/argocd
       ▼
  MetalLB  ── assigns ONE external IP ──►  ingress-nginx Service (LoadBalancer)
                                                │
                                    NGINX Ingress Controller
                                                │
                        ┌───────────────────────┼───────────────────────┐
                        ▼                       ▼                       ▼
                  /jenkins → Jenkins      /app → notes-app       /argocd → Argo CD
```

> ## No DNS is required for the local setup.
>
> There is **nothing to add to `/etc/hosts`**, no DNS server, no hostname
> configuration, and no per-application LoadBalancer IP. Services are reached
> by IP and path. Every Ingress rule in this document is deliberately written
> with **no host**, so it matches any `Host:` header.

Find the IP — this one command is the only thing you need before any URL below:

```sh
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo
```

| Service | URL |
|---|---|
| Jenkins | `http://<METALLB-IP>/jenkins` |
| The app | `http://<METALLB-IP>/app` |
| Argo CD — **canary control lives here** | `http://<METALLB-IP>/argocd` — **UI caveat, see step 8.3** |

There is no separate Rollouts URL. The rollout extension renders canary steps,
weights and the Promote/Abort buttons inside Argo CD itself. The Rollouts
dashboard still runs — it is the API the extension proxies to — it just does not
need its own ingress.

Budget ~35 minutes, most of it image pulls.

### macOS or Ubuntu

Both are covered. Almost everything is byte-identical — kind, kubectl and helm
take the same flags on either, and every manifest, values file and `kubectl`
call below is shared. What differs is marked where it comes up:

| Area | Difference | Where |
|---|---|---|
| Tool install | `brew` vs. release binaries | step 0.1 / 0.2 |
| Shell quoting | zsh globs `[0]`, bash does not | step 3 |
| MetalLB IP reachability | works natively on OrbStack; needs a check elsewhere | step 3.1 |

Memory is the one prerequisite that is genuinely not the same:

- **macOS** — Docker Desktop runs a VM with a hard limit, and that limit is what
  bites. Raise it to **4 GB minimum, 6 GB comfortable** under Settings →
  Resources.
- **Ubuntu** — Docker Engine has no VM and no limit to raise; containers draw on
  host RAM directly. Just confirm the box has ~4 GB free with `free -h`. When
  you do run out, there is no friendly Docker error — the kernel OOM killer
  reaps a process and you see `Exit Code 137` in `kubectl describe`.

> **GPUs?** They split in two, and the halves live in different documents.
> **Step 10 below** is the *cluster side* — device plugin or GPU Operator, node
> labels, taints, scheduling — everything you do with `kubectl` and `helm`
> against a cluster that already exists. It runs on this kind cluster with no
> GPU present, by advertising a fake one. The *node side* — NVIDIA driver,
> containerd, container toolkit, `kubeadm join` on a bare-metal Ubuntu box — is
> **[gpu-node-setup.md](gpu-node-setup.md)**, and needs real hardware.
>
> Given a cluster someone hands you, step 10 alone is the whole job.

Everything below fits in 4 GB as written; Kyverno in step 6 is the piece that
pushes it over, so it is opt-in. At 4 GB do not add nodes or re-enable the Argo
CD components switched off in step 5 — the first thing to fail is the API
server, with `TLS handshake timeout`.

---

## Quick installation

**For rebuilding an environment you already understand.** Every command here is
explained in the full walkthrough that follows — if anything fails, or this is
your first time, use that instead. Steps 0 (tools) and 9 (credentials) are
**not** optional and are not repeated here: without the credentials in step 9
Argo CD cannot clone the repo and Jenkins cannot push images.

```sh
# 0. Prerequisites: docker (OrbStack on macOS), kind, kubectl, helm -- see step 0.
#    Run everything below from the repository root.

# 1. Cluster
kind create cluster --config /tmp/kind-notes-app.yaml     # config in step 1

# 2. Helm repos
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add argo          https://argoproj.github.io/argo-helm
helm repo add kyverno       https://kyverno.github.io/kyverno
helm repo add jenkins       https://charts.jenkins.io
helm repo update

# 3. Confirm the kind subnet matches the pool applied in step 3.4, and that
#    container IPs are routable from macOS. Do not skip.
docker network inspect kind --format '{{json .IPAM.Config}}'
ping -c 2 "$(docker network inspect kind --format '{{range .Containers}}{{.IPv4Address}}{{"\n"}}{{end}}' | head -1 | cut -d/ -f1)"

# 4. MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Available deploy/controller --timeout=300s
kubectl -n metallb-system rollout status ds/speaker --timeout=300s
#    the IPAddressPool + L2Advertisement heredoc -- see step 3.4

# 5. Ingress controller on the MetalLB IP
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --version 4.15.1 \
  --set controller.service.type=LoadBalancer \
  --set controller.watchIngressWithoutClass=true \
  --set controller.replicaCount=1 --wait

export LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "LB_IP=$LB_IP"          # must be non-empty before continuing

# 6. Argo Rollouts (before Argo CD -- the app chart renders a Rollout)
helm install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts --create-namespace --version 2.41.1 \
  --set dashboard.enabled=true --set controller.replicas=1 --wait

# 7. Argo CD      -- values heredoc in step 5
# 8. Jenkins      -- values heredoc in step 7, needs --set controller.jenkinsUrl

# 9. Credentials -- REQUIRED, see step 9. Then the app:
kubectl apply -f argocd/application.yaml

# 10. Verify
kubectl get ingress -A                       # HOSTS must all be *
curl -sS -o /dev/null -w 'jenkins %{http_code}\n' "http://$LB_IP/jenkins/login"
curl -sS -o /dev/null -w 'app     %{http_code}\n' "http://$LB_IP/app/healthz"
curl -sS -o /dev/null -w 'argocd  %{http_code}\n' "http://$LB_IP/argocd/api/version"
```

Optional: Kyverno (step 6) for signature enforcement, and step 10 for GPU
support.

---

## Full installation

Steps 0–12 below are the complete, explained procedure, in order:

| | Step |
|---|---|
| 0 | Prerequisites and tools |
| 1 | kind cluster creation |
| 2 | Helm repositories |
| 3 | **Networking — kind network, MetalLB, IP pool, verification, ingress-nginx** |
| 4 | Argo Rollouts |
| 5 | Argo CD (path routing) |
| 6 | Kyverno (optional) |
| 7 | Jenkins (path routing) |
| 8 | Reaching the UIs |
| 9 | Credentials |
| 10 | GPU support (optional) |
| 11 | Pause and resume |
| 12 | Teardown |
| 13 | Troubleshooting |
| 14 | Later: moving to hostname routing |

---

## 0. Tools

Docker, `kind`, `kubectl` and `helm` on the host — everything else runs in the
cluster. No `argocd` CLI and no `kubectl-argo-rollouts` plugin on either
platform: syncing, promoting and aborting are all done from the UIs. `trivy` and
`cosign` are not needed on the host either — they run inside the Jenkins pod,
baked into its image in step 7.

The one exception is cosign, and only if you want image signing: the keypair is
generated on your own machine. It must be **v2** — v3 removed
`--tlog-upload=false`, which the `Sign Image` stage depends on, and the pipeline
asserts the major version and fails fast.

Follow whichever of the two below matches your machine. Each is complete on its
own; there is nothing to take from the other.

### 0.1 macOS

Docker Desktop, plus:

```sh
brew install kind kubectl helm
```

Optional, for signing only. Homebrew ships cosign v3, so check what you got:

```sh
brew install cosign
cosign version | grep GitVersion          # must be v2.x
# if it reports v3, install a v2 release instead:
#   https://github.com/sigstore/cosign/releases  (pick a v2.x tag)
```

Confirm the base:

```sh
docker info >/dev/null && echo "docker ok"
kind version && kubectl version --client && helm version --short
```

### 0.2 Ubuntu (22.04 / 24.04)

None of the three are in the Ubuntu archive, so they come from upstream
releases. Docker Engine first, if it is not already there:

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
newgrp docker            # or log out and back in
```

Without that group change every `docker` and `kind` call needs `sudo`, and a
cluster created under `sudo` writes its kubeconfig to root's home — `kubectl`
then reports `connection refused` as your own user, which looks like a broken
cluster rather than a permissions problem.

```sh
ARCH=$(dpkg --print-architecture)          # amd64 or arm64

# kind -- pinned to the version verified against kindest/node:v1.33.1 in step 1
curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/v0.29.0/kind-linux-${ARCH}"
sudo install -m 755 /tmp/kind /usr/local/bin/kind

# kubectl -- the 1.33 channel, to match kindest/node:v1.33.1. Do NOT use
# stable.txt here: it is on 1.36 now, three minors ahead of the node image and
# outside kubectl's supported one-minor skew.
curl -fsSLo /tmp/kubectl \
  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable-1.33.txt)/bin/linux/${ARCH}/kubectl"
sudo install -m 755 /tmp/kubectl /usr/local/bin/kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Optional, for signing only. Pinning v2 directly means the version problem never
arises:

```sh
curl -fsSLo /tmp/cosign \
  "https://github.com/sigstore/cosign/releases/download/v2.6.5/cosign-linux-$(dpkg --print-architecture)"
sudo install -m 755 /tmp/cosign /usr/local/bin/cosign
cosign version | grep GitVersion
```

Confirm the base:

```sh
docker info >/dev/null && echo "docker ok"
kind version && kubectl version --client && helm version --short
```

### 0.3 Ubuntu bare metal, without kind

Everything in 0.2 installs the *client* tools next to a kind cluster. If the
Ubuntu box is meant to **be** a cluster node rather than host a nested one —
which is the case for any machine with a GPU in it — stop here and switch to
**[gpu-node-setup.md](gpu-node-setup.md)**. It covers containerd, kubeadm, the
NVIDIA driver and container toolkit, and the essentials a fresh `kubeadm`
cluster does not ship (CNI, storage, metrics-server, ingress).

Come back for steps 4–6 here — Argo Rollouts, Argo CD and Kyverno are plain Helm
installs that apply to any cluster unchanged — and for step 10, which is the
GPU cluster side and equally distro-agnostic.

---

## 1. Create the cluster

```sh
cat <<'EOF' >/tmp/kind-notes-app.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: notes-app
nodes:
  - role: control-plane
    image: kindest/node:v1.33.1
    # NO extraPortMappings and no ingress-ready label.
    #
    # Both existed only to work around kind having no LoadBalancer: the ingress
    # controller bound hostPort 80/443 on a labelled node, and kind published
    # those to the host so http://localhost worked. MetalLB replaces that
    # entirely -- it hands out a real routable IP, so nothing needs to bind a
    # host port and nothing needs pinning to a specific node.
    #
    # Dropping them also frees host port 80, which is the usual reason cluster
    # creation failed on a machine already running apache2 or nginx.
    extraMounts:
      # Jenkins runs `docker build`, but kind nodes use containerd and have no
      # docker daemon. Passing the host socket through lets the Jenkins pod
      # drive your host's Docker. Anything in that pod effectively has root on
      # your machine -- acceptable locally, never in a shared cluster.
      #
      # On EVERY node, not just this one: the scheduler can put Jenkins on any
      # of them, and a node without the mount silently gets an empty directory
      # at that path instead, so `docker ps` fails with "permission denied".
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
  - role: worker
    image: kindest/node:v1.33.1
    extraMounts:
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
EOF

kind create cluster --config /tmp/kind-notes-app.yaml
kubectl cluster-info --context kind-notes-app
kubectl get nodes
```

Two nodes. Each kind node costs roughly 400 MB, so a third is the easiest thing
to cut at 4 GB.

> **Already have a cluster from the old hostPort-based version of this guide?**
> You do **not** need to recreate it. The `extraPortMappings` it was created
> with are simply unused once the ingress controller stops binding host ports —
> harmless leftovers. Skip to step 3 and switch the controller over in place.
> Recreating the cluster would destroy the Jenkins PVC and all its job history.

---

## 2. Helm repositories

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add argo          https://argoproj.github.io/argo-helm
helm repo add kyverno       https://kyverno.github.io/kyverno
helm repo add jenkins       https://charts.jenkins.io
helm repo update
```

---

## 3. Networking — MetalLB and the ingress controller

This is the heart of the setup. MetalLB hands out **one** external IP; NGINX
takes it and routes on path. Do the sub-steps in order and verify each — a
LoadBalancer that has an `EXTERNAL-IP` is not the same thing as one you can
reach.

### 3.1 Choose the address pool from the real network

Do not copy an IP range blindly. Derive it from the `kind` Docker network:

```sh
docker network inspect kind --format '{{json .IPAM.Config}}'
```

```sh
docker network inspect kind --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
```

On the machine this was written against those printed subnet
`192.168.107.0/24` (gateway `.1`) with the kind nodes on `.2` and `.3`. Docker
allocates container addresses from the **low** end of the subnet, so a pool at
the **high** end cannot collide with a node that joins later.

The IPAddressPool heredoc in step 3.4 carries that range. **Edit both
`addresses` entries if your subnet differs** — an address outside the kind
subnet gets assigned happily and then answers nothing, because the host has no
route to it.

### 3.2 Check that the pool will be reachable from macOS

The most important check in this document, and the one most guides skip.

```sh
docker network inspect kind --format '{{range .Containers}}{{.IPv4Address}}{{"\n"}}{{end}}' | head -1
ping -c 2 192.168.107.2        # substitute a node IP from the line above
```

- **Replies** — container IPs are routed to the host. **OrbStack does this
  natively**, which is what makes this whole setup work on macOS. Continue.
- **No replies** — you are almost certainly on **Docker Desktop**, whose VM does
  not route the bridge network to macOS. MetalLB will still assign an
  `EXTERNAL-IP`, and it will be unreachable from your browser. Switch to
  OrbStack, or see the troubleshooting entry *"MetalLB IP assigned but
  unreachable from macOS"* in step 13.

```sh
netstat -rn -f inet | grep 192.168.107     # a route via bridgeNNN confirms it
```

### 3.3 Install MetalLB

```sh
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
```

Pin the version. The GitHub *latest release* API for this project returns a
**Helm chart** tag (`metallb-chart-x.y.z`) whose manifest ships `:main` images —
a floating dev tag, wrong for a reproducible setup.

Wait for the controller and every speaker:

```sh
kubectl -n metallb-system wait --for=condition=Available deploy/controller --timeout=180s
kubectl -n metallb-system rollout status ds/speaker --timeout=180s
kubectl -n metallb-system get pods
```

All pods must be `Running` and `1/1` before continuing — the webhook that
validates the next step lives in the controller.

### 3.4 Apply the address pool

The range below is **not** arbitrary — it is carved out of the `kind` Docker
network you inspected in 3.1. Docker hands out container addresses from the LOW
end of the subnet, so a pool at the high end cannot collide with a node that
joins later. **Edit both `addresses` entries if your subnet differs.** A pool
outside the kind subnet is assigned happily by MetalLB and then answers nothing,
because the host has no route to it.

```sh
kubectl apply -f - <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.107.200-192.168.107.250
  # Every Service of type LoadBalancer draws from here unless it asks for a
  # specific pool. With one ingress controller fronting everything, exactly one
  # address is ever consumed -- the other 50 are headroom, not a plan.
  autoAssign: true
---
# L2 mode: a speaker Pod answers ARP for the pool addresses on the node's LAN,
# so the address resolves to a node MAC and traffic lands on kube-proxy.
#
# L2 is the right mode here because there is no router to peer with. BGP mode
# would need one. The tradeoff is that all traffic for a given address enters
# through a single elected node -- irrelevant at this scale.
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF
```

```sh
kubectl get ipaddresspools -n metallb-system
kubectl get l2advertisements -n metallb-system
```

The pool is L2 mode: a speaker answers ARP for the pool addresses, so the IP
resolves to a node MAC. There is no router to peer with here, which is why this
is not BGP mode.

### 3.5 Verify MetalLB with a throwaway Service

Do not continue until this passes.

```sh
kubectl create deploy metallb-test --image=registry.k8s.io/e2e-test-images/agnhost:2.53 \
  -- /agnhost netexec --http-port=8080
kubectl expose deploy metallb-test --type=LoadBalancer --port=80 --target-port=8080
kubectl get svc metallb-test
```

`EXTERNAL-IP` must become an address from your pool, not `<pending>`. Then —
the part that actually matters — reach it **from macOS**:

```sh
IP=$(kubectl get svc metallb-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sS -m 10 -o /dev/null -w 'HTTP %{http_code}\n' "http://${IP}/"
curl -sS -m 10 "http://${IP}/hostname"; echo
```

`HTTP 200` and a pod name printed back is real reachability. `arp -n "$IP"`
should show the IP resolving to a node MAC.

Clean up:

```sh
kubectl delete svc metallb-test
kubectl delete deploy metallb-test
```

### 3.6 Ingress controller, as a LoadBalancer

```sh
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version 4.15.1 \
  --set controller.service.type=LoadBalancer \
  --set controller.watchIngressWithoutClass=true \
  --set controller.replicaCount=1 \
  --wait
```

`service.type=LoadBalancer` is the whole point: MetalLB assigns this Service the
shared IP, and every application reaches the browser through it.

**No `hostPort`, no `NodePort`.** The older version of this document used
`controller.hostPort.enabled=true` plus a `NodePort` Service and an
`ingress-ready=true` nodeSelector, because without MetalLB a `LoadBalancer`
Service on kind stays `<pending>` forever. With MetalLB that workaround is
obsolete — and hostPort is what tied the setup to `http://localhost` and
hostname routing.

### 3.7 Verify the ingress controller got the IP

```sh
kubectl get svc -n ingress-nginx
```

`ingress-nginx-controller` must show an `EXTERNAL-IP` from the pool. Save it:

```sh
export LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$LB_IP"
curl -s -o /dev/null -w '%{http_code}\n' "http://$LB_IP/"      # 404 = up
```

`404` is success: nginx is answering and no rule claims `/` yet.

---

## 4. Argo Rollouts

Install **before** Argo CD syncs the app — the chart renders a `Rollout`, and
without these CRDs Argo CD fails with `no matches for kind "Rollout"`.

```sh
helm install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts --create-namespace \
  --version 2.41.1 \
  --set dashboard.enabled=true \
  --set controller.replicas=1 \
  --wait

kubectl get crd rollouts.argoproj.io
```

`dashboard.enabled=true` is not optional, but not because you visit it. It is
the API the Argo CD rollout extension proxies to — the canary controls in the
Argo CD UI are dead without it. It needs no ingress of its own.

---

## 5. Argo CD

```sh
cat <<'EOF' | helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.3.3 -f - --wait
# Required to get a host-less Ingress rule. `server.ingress.hostname: ""` alone
# is NOT enough -- the chart falls back to `global.domain`, whose default is
# argocd.example.com, and you end up with a hostname-bound rule that answers
# nothing on an IP. Blanking both is what produces HOSTS `*`.
global:
  domain: ""

configs:
  params:
    # Plain HTTP. Otherwise the server serves a self-signed cert and every
    # port-forward, CLI call and ingress hop needs --insecure.
    server.insecure: true

    # --- Path-based routing -------------------------------------------------
    #   server.rootpath  -- argocd-server strips /argocd from incoming request
    #                       paths and routes on the remainder, so the backend
    #                       genuinely serves the subtree. This is why there is
    #                       NO rewrite-target annotation below.
    #   server.basehref  -- rewrites <base href> in the served index.html, so
    #                       the UI's relative asset and API URLs resolve under
    #                       /argocd instead of /.
    # Set only rootpath and the page loads blank white: the HTML arrives, then
    # every JS/CSS request goes to /assets/... and 404s.
    server.rootpath: /argocd
    server.basehref: /argocd

  cm:
    # Poll git every 60s instead of the 180s default. GitHub cannot reach a
    # local cluster, so webhooks are out and polling is the only trigger.
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
    # Prefix is correct here -- no regex, because rootpath means the backend
    # wants the prefix left on.
    pathType: Prefix
    # Empty = matches any Host header, so IP access works with no DNS.
    hostname: ""
  # initContainer that downloads the rollout extension bundle into
  # argocd-server -- what renders canary steps, weights and Promote/Abort
  # inside the Argo CD UI.
  #
  # Keep this inside the single `server:` block -- a second top-level `server:`
  # key silently wins and drops everything above it.
  extensions:
    enabled: true
    extensionList:
      - name: rollout-extension
        env:
          - name: EXTENSION_URL
            value: https://github.com/argoproj-labs/rollout-extension/releases/download/v0.4.0/extension.tar

# HA defaults will not schedule on kind.
redis-ha:
  enabled: false
controller:
  replicas: 1
repoServer:
  replicas: 1

# Not used by this setup, ~100-150 MB each.
dex:
  enabled: false
notifications:
  enabled: false
EOF
```

The two settings that matter for path routing:

- `configs.params."server.rootpath": /argocd` — argocd-server strips `/argocd`
  from incoming paths and serves the subtree itself, so **no rewrite annotation
  is used**.
- `global.domain: ""` — required. Setting `server.ingress.hostname: ""` alone is
  not enough: the chart falls back to `global.domain`, whose default is
  `argocd.example.com`, and you get a hostname-bound rule that answers nothing
  on an IP. Blanking both is what produces `HOSTS *`:

```sh
kubectl get ingress -n argocd        # HOSTS must show *, not a hostname
```

Argo CD is at `http://<METALLB-IP>/argocd` as soon as this finishes, with the
**UI caveat in step 8.3**. Credentials are in step 8.1.
are in step 8.1.

---

## 6. Kyverno (optional — signature enforcement)

Skip if you are not signing yet; nothing else depends on it.

```sh
helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.8.2 \
  --wait
```

Argo CD has **no** image-signature verification of its own — this is what
actually blocks an unsigned image, at admission, before the pod is created.

The public key is written out in full below — no file to read, nothing to
substitute. If you regenerate the keypair in step 9.3, paste the new
`cosign.pub` contents over the block at the bottom and re-apply.

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-notes-app
spec:
  background: false
  rules:
    - name: check-cosign-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - default
      verifyImages:
        # Audit = log failures only. Confirm it passes, THEN switch to Enforce
        # -- under Enforce an unsigned image means pods are refused outright
        # and the app stops deploying. (spec.validationFailureAction is
        # deprecated; this per-rule field replaces it.)
        - failureAction: Audit
          # Kyverno defaults this to true, which Audit rejects -- it will not
          # rewrite tags to digests on a rule that is not enforcing.
          mutateDigest: false
          imageReferences:
            - "docker.io/jahadulrakib/notes-app:*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE9pzDmp26walej+dJG0KmqP82X8EK
                      MbGDNyWjJNZhmYd2RUeNZeOYVHyYYcqCBkhNAu6TElNyVW+fC/RX8ON0hA==
                      -----END PUBLIC KEY-----
                    # Must match how Jenkins signs. The pipeline passes
                    # --tlog-upload=false because rekor.sigstore.dev is
                    # unreachable with no egress, so there is no transparency
                    # log entry to check. Omit and every verification fails.
                    rekor:
                      ignoreTlog: true
                    ctlog:
                      ignoreSCT: true
EOF

kubectl get clusterpolicy verify-notes-app
```

Kyverno needs egress to `docker.io`: signatures live in the registry beside the
image, so it fetches them to verify.

---

## 7. Jenkins

The stock Jenkins image has none of the tools the pipeline needs. A prebuilt one
that does is published publicly, so there is nothing to build here — the kubelet
pulls it like any other image:

```
docker.io/jahadulrakib/jenkins-devops-kubernetes:lts-jdk21
```

It is a public repo: no `docker login`, no pull secret, and no `kind load`. The
manifest covers `linux/amd64` and `linux/arm64`, so the same tag works on an
Intel server and on Apple Silicon.

<details>
<summary>What is in it, and how to rebuild your own</summary>

Only needed if you want to change the tool versions. Substitute your own
`OWNER/REPO` and use that instead of the ref above.

```sh
cat <<'EOF' >/tmp/Dockerfile.jenkins
FROM jenkins/jenkins:lts-jdk21
USER root

# docker-cli, NOT docker.io -- on Debian the docker.io package ships only the
# daemon (dockerd, docker-proxy), and the client lives in docker-cli. Install
# docker.io and `docker` is simply absent. The daemon is not wanted here anyway;
# this container drives the host's, through the mounted socket.
RUN apt-get update && apt-get install -y --no-install-recommends \
        docker-cli git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# docker buildx -- REQUIRED, and not because of the DOCKER_BUILDKIT=1 in the
# Build stage. BuildKit has been the DEFAULT builder since Docker CLI v23, and
# the docker-cli package does not ship the buildx component that implements it,
# so a plain `docker build` fails with "BuildKit is enabled but the buildx
# component is missing or broken" whether or not that variable is set.
#
# The only way to drop this ~50 MB is to build with DOCKER_BUILDKIT=0, which
# selects the classic builder -- deprecated, warns on every run, and slated for
# removal. Not worth it: this project's Dockerfile uses no BuildKit-only
# features, but the classic builder is the thing that is going away, not buildx.
ARG BUILDX_VERSION=v0.36.1
RUN mkdir -p /usr/libexec/docker/cli-plugins \
    && curl -fsSL -o /usr/libexec/docker/cli-plugins/docker-buildx \
       "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-$(dpkg --print-architecture)" \
    && chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# helm -- the pipeline lints and renders the chart
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# trivy -- the Scan Image stage
RUN curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
      | sh -s -- -b /usr/local/bin

# cosign PINNED TO v2: v3 removed --tlog-upload=false and the Sign Image stage
# asserts the major version.
ARG COSIGN_VERSION=v2.6.5
RUN curl -fsSL -o /usr/local/bin/cosign \
      "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-$(dpkg --print-architecture)" \
    && chmod +x /usr/local/bin/cosign

USER jenkins
EOF

# --platform is what makes the tag portable. A plain `docker build` on Apple
# Silicon produces an arm64-only image that lands on an amd64 node as
# "exec format error". The Dockerfile is arch-aware -- every download derives
# its URL from `dpkg --print-architecture` -- so both halves build from it
# unchanged. The amd64 half runs under emulation on an arm64 host: slow, but
# it does not need a second machine.
#
# --push, not --load: a multi-arch manifest cannot live in the local docker
# image store, only in a registry.
docker buildx create --name multiarch --driver docker-container --bootstrap
docker login
docker buildx build --builder multiarch \
  --platform linux/amd64,linux/arm64 \
  -f /tmp/Dockerfile.jenkins \
  -t OWNER/REPO:lts-jdk21 \
  --push /tmp
```

A repo Docker Hub creates on a first push is public, which is what makes the
anonymous pull above work. Nothing needs to be flipped in the UI.

</details>

```sh
export LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

cat <<'EOF' | helm install jenkins jenkins/jenkins \
  --namespace jenkins --create-namespace \
  --version 5.9.54 -f - \
  --set controller.jenkinsUrl="http://${LB_IP}/jenkins" \
  --wait --timeout 10m
controller:
  image:
    registry: docker.io
    repository: jahadulrakib/jenkins-devops-kubernetes
    tag: lts-jdk21
    pullPolicy: IfNotPresent

  numExecutors: 2

  # Root, so the container can use the mounted docker socket without fighting
  # group ownership. BOTH levels are required: the chart's
  # containerSecurityContext.runAsUser overrides the pod-level one.
  runAsUser: 0
  fsGroup: 0
  containerSecurityContext:
    runAsUser: 0
    runAsGroup: 0
    readOnlyRootFilesystem: false
    allowPrivilegeEscalation: false

  # --- Path-based routing ---------------------------------------------------
  # THE load-bearing setting. It appends --prefix=/jenkins to the Jenkins JVM,
  # so Jenkins itself serves under /jenkins and generates every internal link,
  # redirect and static-asset URL with that prefix already on it.
  #
  # This is why there is NO rewrite-target annotation below: the backend
  # genuinely expects /jenkins/... A rewrite that stripped the prefix would give
  # a Jenkins that renders once and then 404s every CSS, JS and form POST.
  #
  # It also fixes the probes for free -- the chart templates them as
  # `{{ default "" .Values.controller.jenkinsUriPrefix }}/login`.
  jenkinsUriPrefix: /jenkins

  ingress:
    enabled: true
    ingressClassName: nginx
    path: /jenkins
    # Prefix, not ImplementationSpecific (the chart default): /jenkins must also
    # match /jenkins/, /jenkins/login, /jenkins/static/...
    pathType: Prefix
    # hostName intentionally omitted -- no host matches ANY Host header, which
    # is what makes http://<IP>/jenkins work with no DNS.
    annotations:
      # Jenkins file uploads (plugin .hpi, job config) exceed nginx's 1m
      # default and fail with 413.
      nginx.ingress.kubernetes.io/proxy-body-size: 50m
      # Long-poll and CLI-over-HTTP connections idle well past the 60s default.
      nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
      nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"

  # `installPlugins` is left unset ON PURPOSE. Setting it REPLACES the chart's
  # four pinned defaults -- kubernetes, workflow-aggregator, git,
  # configuration-as-code -- rather than adding to them; additionalPlugins
  # layers on top and keeps the pins.
  additionalPlugins:
    # REQUIRED. Backs options { timestamps() }. Without it the pipeline dies
    # with `Invalid option type "timestamps"` before any stage runs.
    - timestamper:latest
    # REQUIRED. withCredentials() in the Push, Sign and Update GitOps stages.
    - credentials-binding:latest
    # Not required, kept deliberately: commit/branch links back to the repo,
    # and a formatter that stops raw HTML rendering in job descriptions.
    - github:latest
    - antisamy-markup-formatter:latest

# No dynamic Kubernetes agents -- the tooling lives in the controller image, and
# `agent any` would otherwise schedule onto a bare inbound-agent with no docker.
agent:
  enabled: false

persistence:
  storageClass: standard
  size: 8Gi
  # Host docker socket, passed through by the kind extraMount.
  volumes:
    - name: docker-sock
      hostPath:
        path: /var/run/docker.sock
  mounts:
    - name: docker-sock
      mountPath: /var/run/docker.sock
EOF
```

Only `jenkinsUrl` is passed on the command line, because it needs the live IP.

> On a cluster with **no Docker socket to mount** — K3s and anything else on
> containerd — this values block does not transfer: drop the `volumes`/`mounts`
> pair and build with Kaniko instead. See `k3s-lab/README.md`.

### 7.1 Why Jenkins needs more than an Ingress path

Pointing a `/jenkins` path at the Jenkins Service is **not** enough. Jenkins
generates absolute URLs for its own assets, redirects and form targets. Serve it
under a prefix without telling it, and you get a page that renders once and then
404s every CSS file, every login POST and every link.

The fix is one value:

```yaml
controller:
  jenkinsUriPrefix: /jenkins
```

It appends `--prefix=/jenkins` to the Jenkins JVM, so **Jenkins itself serves
the subtree** and stamps the prefix onto everything it emits.

Two consequences worth understanding, because they are what make this work:

- **No `rewrite-target` annotation.** The backend genuinely expects
  `/jenkins/...`. Stripping the prefix would leave Jenkins listening on `/` while
  its own HTML pointed at `/jenkins/*` — broken in the least obvious way.
- **The probes follow automatically.** The chart templates them as
  `{{ default "" .Values.controller.jenkinsUriPrefix }}/login`, so they move to
  `/jenkins/login` instead of 404ing on `/login` and CrashLoopBackOff-ing the
  pod. This is the single most common failure when bolting a context path onto a
  chart that does not support one.

The ingress annotations in the values file cover the rest: `proxy-body-size: 50m`
so plugin uploads do not fail with 413, and hour-long read/send timeouts so
long-poll and CLI-over-HTTP connections are not cut at nginx's 60s default.

### 7.2 Verify Jenkins under the path

```sh
curl -sS -o /dev/null -w 'jenkins       %{http_code}  -> %{redirect_url}\n' "http://$LB_IP/jenkins"
curl -sS -o /dev/null -w 'jenkins/login %{http_code}\n'                     "http://$LB_IP/jenkins/login"
```

Expect `301` to `http://<IP>/jenkins/` and `200` on the login page. A `403` on
`/jenkins/` is **correct** — it is Jenkins requiring auth, and it redirects to
`/jenkins/login?from=%2Fjenkins%2F`, prefix intact.

Confirm the assets that break under a bad prefix setup actually load:

```sh
curl -sSL "http://$LB_IP/jenkins/login" | grep -oE '(href|src)="/jenkins/[^"]*"' | head -3
```

Every generated URL must start with `/jenkins/`. If they start with `/static/`
instead, `jenkinsUriPrefix` did not take effect.

---

## 8. Reaching the UIs

Every URL is `http://<METALLB-IP>/<path>`. **No DNS, no `/etc/hosts`.**

```sh
export LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$LB_IP"
kubectl get ingress -A
```

Every row must show `HOSTS` = `*`. A hostname there means that release is still
host-bound and will not answer on the IP.

```sh
curl -sS -o /dev/null -w 'jenkins  %{http_code}\n' "http://$LB_IP/jenkins/login"
curl -sS -o /dev/null -w 'app      %{http_code}\n' "http://$LB_IP/app/healthz"
curl -sS -o /dev/null -w 'argocd   %{http_code}\n' "http://$LB_IP/argocd/api/version"
```

Then open them in a browser on macOS:

| Service | URL |
|---|---|
| Jenkins | `http://<LB_IP>/jenkins` |
| The app | `http://<LB_IP>/app` |
| Argo CD | `http://<LB_IP>/argocd` — see 8.3 |

### 8.1 Logging in

Both usernames are `admin`; both passwords are generated at install time and
kept in a Secret:

```sh
printf 'Argo CD   http://%s/argocd\n  user: admin\n  pass: %s\n' "$LB_IP" \
  "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
printf 'Jenkins   http://%s/jenkins\n  user: %s\n  pass: %s\n' "$LB_IP" \
  "$(kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-user}' | base64 -d)" \
  "$(kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)"
```

The `base64 -d` matters — Secret values are stored base64-encoded, so reading
the field without it gives you gibberish that will not log you in.

Argo CD's username is always `admin` and is not stored in the Secret; only the
password is. After logging in, change it under **User Info → Update Password**,
then delete the bootstrap Secret:

```sh
kubectl -n argocd delete secret argocd-initial-admin-secret
```

Jenkins keeps its Secret in use, so leave that one alone.

### 8.2 Reaching it from another machine

Nothing to configure on the client — there are no hostnames to resolve. If the
cluster runs on a different machine than your browser, the only requirement is
an IP route to the MetalLB pool. On a remote server that usually means an SSH
tunnel, since the pool lives on a Docker bridge network:

```sh
ssh -L 8080:<METALLB-IP>:80 user@server -N
# then browse http://localhost:8080/jenkins
```

Path routing survives this unchanged, which host-based routing would not: there
is no `Host:` header to preserve.

> Everything here is HTTP with no TLS, and step 5 turns TLS off inside the
> cluster on purpose. Do not expose it on a public IP.

### 8.3 Argo CD UI — known limitation

The Argo CD **API** works under `/argocd`:

```sh
curl -sS "http://$LB_IP/argocd/api/version"      # {"Version":"v3.5.1"}
```

The **web UI does not render** under a path prefix on Argo CD **v3.5.1**. It
serves an unrewritten `<base href="/">` regardless of
`ARGOCD_SERVER_BASEHREF`, so the UI's relative asset URLs resolve to `/main.js`
instead of `/argocd/main.js` and 404 — a blank white page.

Verify it yourself rather than taking this on trust:

```sh
curl -sS "http://$LB_IP/argocd/" | grep -o '<base href="[^"]*"'
```

If that prints `<base href="/argocd/">`, the upstream bug is fixed and the UI
works — delete this note. While it prints `<base href="/">`, use a port-forward
for the UI. This still needs no DNS:

```sh
kubectl -n argocd port-forward svc/argocd-server 8081:80
# browse http://localhost:8081
```

Two rejected alternatives, for the record: an nginx `sub_filter` would rewrite
the tag, but ingress-nginx refuses `configuration-snippet` unless the controller
is set to accept `Critical`-risk annotations cluster-wide — too much loosening
for one UI. Giving Argo CD its own LoadBalancer IP would also work, but breaks
the one-IP rule this architecture is built on.

## 9. Credentials

Four things: two cluster secrets, a signing keypair, and the Jenkins entries.
Every `read -rs` below reads with echo off, so no token reaches your shell
history or the process list.

> **No real token appears in this document.** Every credential below is a
> placeholder you replace at the moment you run the command. Pasting a live PAT
> into a markdown file puts it in git history, where `git rm` cannot reach it —
> the only fix at that point is to revoke the token.

### 9.1 Argo CD repository credential — required

Argo CD cannot clone a private repo without this, and the Application sits in
`ComparisonError / authentication required`. It is a **bootstrap** credential:
it cannot come from the chart, because Argo CD needs it to clone the repo that
holds the chart.

`read -rs` keeps the token out of your shell history and out of `ps` output, and
the heredoc is unquoted so `$GH_PAT` expands — the token exists only in this
shell's memory.

```sh
read -rs -p 'GitHub PAT (repo scope): ' GH_PAT && echo
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

Argo CD only clones, so a read-only `repo` PAT is enough here. Reusing the
write-scoped token Jenkins needs works, but means a single revoke breaks both —
two tokens is the better habit.

Re-running rotates the token in place. Check it in the UI: **Settings →
Repositories** at `http://<LB_IP>/argocd` — `CONNECTION STATUS` must read
`Successful`. `Failed` almost always means the `url` above does not match
`repoURL`.

### 9.2 Docker Hub pull secret — only if the image repo is private

Consumed by the **kubelet**, so it belongs in the namespace where the pod runs
(`default`), *not* `argocd`. Getting that wrong is the usual cause of
`ImagePullBackOff` with `pull access denied`.

`kubectl` builds the whole `.dockerconfigjson`, including the base64 `auth`
field, from a username and token — nothing to encode by hand.

```sh
read -rs -p 'Docker Hub access token: ' DOCKER_PAT && echo
kubectl create secret docker-registry dockerhub-pull \
  --namespace default \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=jahadulrakib \
  --docker-password="$DOCKER_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DOCKER_PAT
```

The `--dry-run | apply` pipe is what makes it re-runnable — plain
`kubectl create secret` fails with `AlreadyExists` on a rotation.

The chart only *references* this by name, never creates it, which keeps the
token out of git:

```yaml
# helm/values.yaml
imagePullSecrets:
  - name: dockerhub-pull
```

If the repo ends up public, skip this entirely — the kubelet pulls anonymously
and never reads the secret.

### 9.3 Jenkins credentials

The IDs must match exactly — the `Jenkinsfile` looks them up by ID. Type the
values straight into the Jenkins UI; do not stage them in a file first.

| ID | Kind | Username | Password / content |
|---|---|---|---|
| `github-token` | Username with password | `Jahadul-Rakib` | GitHub PAT, **write** `repo` scope |
| `dockerhub` | Username with password | `jahadulrakib` | Docker Hub access token, Read/Write |
| `cosign-key` | Secret text | — | contents of `abc_local_setup/cosign/cosign.key` |
| `cosign-key-password` | Secret text | — | contents of `abc_local_setup/cosign/cosign.password` |

Generate the keypair if you do not have one — it writes the three files this
table refers to, and the password is whatever you type at the prompt:

```sh
cd abc_local_setup/cosign && cosign generate-key-pair
```

> **Keep `cosign.key` and `cosign.password` out of git.** They are the private
> half of your supply-chain signature: anyone holding both can sign an image as
> you. Add them to `.gitignore` before the first commit.

**cosign-key:**

> **Paste the whole block, markers included.** Jenkins renders *Secret text* as
> a single-line password field, so a multi-line paste arrives with its newlines
> stripped and cosign rejects it:
>
> ```
> Error: signing [...]: reading key: invalid pem block
> ```
>
> The `Sign Image` stage repairs that case — it locates the BEGIN/END markers
> and rebuilds the PEM before handing it to cosign, so a flattened or CRLF paste
> still signs. What it cannot repair is a **truncated** paste (only the first
> line landing in the field); that fails with a message naming this credential.
> If you see it, re-copy from `abc_local_setup/cosign/cosign.key`.
>
> To sidestep the field entirely, use a **Secret file** credential with
> `cosign.key` uploaded, and change the binding in the `Jenkinsfile` from
> `string(...)` to `file(credentialsId: ..., variable: 'COSIGN_KEY_FILE')`,
> passing `--key "$COSIGN_KEY_FILE"` directly.

Copy it straight out of the file rather than reading it off a screen — the body
is one long base64 blob and a single dropped character makes the key undecryptable:

```sh
cat abc_local_setup/cosign/cosign.key
```

The shape you should see, with the base64 body elided:

```
-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----
<base64 body -- roughly 10 lines; never paste your real key into a file>
-----END ENCRYPTED SIGSTORE PRIVATE KEY-----
```

**NOTE:** `github-token` needs **write** `repo` scope — `Update GitOps` commits the image
tag back.

---

## 10. GPU support (cluster side)

Optional. Nothing else in this document depends on it.

GPU support splits in two, and this section is only the second half:

| Half | Where you do it | Covered by |
|---|---|---|
| Driver, containerd, NVIDIA Container Toolkit | on the machine with the card, over SSH | [gpu-node-setup.md](gpu-node-setup.md) steps 1–13 |
| Device plugin, labels, taints, scheduling | against the API server, `kubectl` and `helm` | **here** |

The split is the whole idea: the host owns the hardware, and Kubernetes only
ever learns about it second-hand. A device plugin running as a DaemonSet is what
turns a `/dev/nvidia0` on some node into a countable `nvidia.com/gpu` the
scheduler can allocate. So "the cluster side" is a real, self-contained job —
given a cluster whose nodes are already prepared, everything below is done
without ever logging into one.

**This kind cluster has no GPU.** Step 10.2 advertises a fake one. That is not a
toy: the scheduler treats a fake extended resource exactly like a real one, so
every selector, toleration, limit and failure message below behaves identically.
Only the compute is missing.

### 10.1 Which path are you on?

```sh
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu'
```

| Output | Meaning | Go to |
|---|---|---|
| a number | a device plugin is already running; node side is done | 10.4 |
| `<none>`, node **has** a card | nothing is advertising it | 10.3 |
| `<none>`, no card (this kind cluster) | nothing to advertise | 10.2 |

### 10.2 Advertise a fake GPU — no hardware

Kubernetes lets you PATCH an arbitrary extended resource into a node's status,
which is the documented way to advertise non-standard hardware. Pods asking for
`nvidia.com/gpu` then schedule and run:

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

GPU Feature Discovery is not running either, so add by hand the labels it would
have written — the chart selects on `nvidia.com/gpu.present`:

```sh
kubectl label node "$NODE" nvidia.com/gpu.present=true --overwrite
kubectl label node "$NODE" nvidia.com/gpu.count=2      --overwrite
```

> **Do not also install the GPU Operator or the device plugin on this cluster.**
> Both probe for real devices, find none and crash-loop, and the plugin
> overwrites the fake capacity above on the way down. The fake resource and a
> real plugin are alternatives, never both.

The patch survives until the node object is rebuilt; recreating the kind cluster
clears it. Skip to 10.4.

### 10.3 Install a device plugin — real hardware

Two options. **Install one, not both** — two plugins fight over the same devices
and the node flaps between advertising and withdrawing them.

| | GPU Operator | Standalone device plugin |
|---|---|---|
| Installs | driver, toolkit, plugin, GFD, DCGM metrics, MIG manager | the plugin, and that is all |
| Node labels | yes, via Node Feature Discovery | only with `gfd.enabled=true` |
| Footprint | ~8 pods per GPU node + an operator | one DaemonSet |
| Use when | a real or growing GPU fleet | one node, or a tight cluster |

The Operator is the production answer, and the one to name in an interview: it
makes GPU nodes reproducible and self-describing instead of hand-built.

```sh
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm search repo nvidia/gpu-operator --versions | head -5   # pin from this

helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --version <VERSION_FROM_ABOVE> \
  --set driver.enabled=false \
  --set toolkit.enabled=false \
  --wait --timeout 10m
```

> **Both `false` flags are load-bearing.** The Operator can install the driver
> and toolkit itself, in containers — but on a node prepared by
> `gpu-node-setup.md` steps 3 and 7 they are already there. Leaving them `true`
> makes it load a second kernel driver over the running one: the
> `driver-daemonset` crash-loops, `nvidia-smi` on the host starts failing, and
> running containers die with `Driver/library version mismatch`. Omit both flags
> only on a node where you deliberately skipped those steps.

Or the standalone plugin:

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

`gfd.enabled=true` is what writes the `nvidia.com/gpu.*` node labels. Without it
there are no labels, and the `nodeSelector` in 10.5 matches nothing — the pod
sits `Pending` on a cluster where the GPU is demonstrably present.

Watch it converge; the validator pods are noisy:

```sh
kubectl -n gpu-operator get pods -w
```

`nvidia-operator-validator` reaching `Completed`/`Running` is the verdict
everything downstream depends on. Then re-run 10.1 — the GPU column must show a
number.

Finally, prove it end to end, through all six layers:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
spec:
  restartPolicy: OnFailure
  nodeSelector:
    nvidia.com/gpu.present: "true"
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: cuda-vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

kubectl logs -f pod/cuda-vectoradd
kubectl delete pod cuda-vectoradd
```

`Test PASSED` is the whole stack working. This needs a real GPU — on the fake
capacity from 10.2 the pod schedules and then fails, because there is no device
to open.

### 10.4 Taint the node

Labels let GPU work *find* the node. A taint stops everything else *landing* on
it — otherwise the cluster's ordinary pods fill up your most expensive machine:

```sh
kubectl taint node "$NODE" nvidia.com/gpu=present:NoSchedule --overwrite
```

`NoSchedule`, not `NoExecute`: `NoExecute` evicts pods already running without
the toleration, which on a live node means kicking off whatever was there.

### 10.5 Send the app to it

The chart already carries the wiring — `gpu` in `helm/values.yaml`:

```sh
helm upgrade --install notes-app helm --set gpu.enabled=true
kubectl get pods -o wide          # lands on $NODE, Running
```

Three things flip together, and each one alone leaves the pod broken
differently:

| Rendered | Without it |
|---|---|
| `resources.limits."nvidia.com/gpu": 1` | runs on the GPU node with no GPU visible |
| `nodeSelector: nvidia.com/gpu.present: "true"` | `Pending` — "Insufficient nvidia.com/gpu" |
| toleration for the 10.4 taint | `Pending` — "node(s) had untolerated taint" |

Break it on purpose — this is the part worth having seen before someone asks:

```sh
helm upgrade notes-app helm --set gpu.enabled=true --set gpu.tolerations=null
kubectl describe pod -l app.kubernetes.io/name=notes-app | grep -A5 Events

helm upgrade notes-app helm --set gpu.enabled=true --set gpu.count=99
kubectl describe pod -l app.kubernetes.io/name=notes-app | grep -A5 Events
```

> The notes app is Flask and needs no GPU; enabling this makes it occupy one it
> will never use. The point is that the *scheduling* wiring is real and
> reviewable — on an actual GPU workload the values are identical and only the
> image changes.

### 10.6 Sharing one GPU — real hardware only

Without this, a second pod asking for a GPU on a single-GPU node stays `Pending`
forever, however idle the card is: one container gets one whole GPU, and `0.5`
is rejected. Time-slicing advertises *n* replicas of each physical GPU:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator      # nvidia-device-plugin for the standalone plugin
data:
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

helm upgrade gpu-operator nvidia/gpu-operator -n gpu-operator --reuse-values \
  --set devicePlugin.config.name=time-slicing-config \
  --set devicePlugin.config.default=any
```

**The new capacity is a lie the scheduler believes.** It is still one card with
one pool of VRAM — four pods each allocating 20 GB on a 40 GB card will OOM, and
the scheduler will have placed all four. Time-slicing multiplies *scheduling
slots*, not memory. MIG is the answer when isolation actually matters, on
A100/H100/A30 only. The GPU Operator manages it via `mig.strategy=single|mixed`
and a `MIG_CONFIGURATION` ConfigMap, and the resource name becomes e.g.
`nvidia.com/mig-1g.5gb`. Do not attempt it on hardware that lacks support.

### 10.7 Undo

```sh
helm upgrade notes-app helm                  # gpu.enabled back to false
kubectl taint node "$NODE" nvidia.com/gpu-
kubectl label node "$NODE" nvidia.com/gpu.present- nvidia.com/gpu.count-
```

The fake capacity from 10.2 needs the node object rebuilt, so
`kind delete cluster` is the only full reset.

### What this section cannot rehearse

Worth being straight about rather than pretending otherwise. On a cluster with
no GPU, the driver install, Secure Boot/MOK, the container toolkit, the plugin
actually finding devices, and time-slicing all need real hardware. What 10.2–10.5
*does* exercise is advertisement, selection, tolerations, resource limits and the
failure messages — which is most of what gets asked about, because it is where
most real mistakes are. Full troubleshooting table:
[gpu-node-setup.md](gpu-node-setup.md) Appendix C.

---

## 11. Pause and resume

kind nodes are ordinary Docker containers, so the cluster stops and starts like
one. There is no `kind pause`; `docker stop` is the whole mechanism.

```sh
# pause -- gives back roughly 3 GB
docker stop notes-app-control-plane notes-app-worker

# resume -- control-plane FIRST, so etcd and the API server are up before the
# worker's kubelet starts registering
docker start notes-app-control-plane
docker start notes-app-worker
```

`docker stop`, not `docker pause`. `pause` SIGSTOPs the processes and leaves
every page resident, so it returns no memory at all — on a 4-6 GB budget that
is the only resource worth reclaiming. `stop` frees the RAM and keeps the
container's disk.

Nothing needs re-running afterwards. Port mappings are fixed when the container
is created, not when it starts, so the API server keeps whatever host port it
was given and the kubeconfig stays valid:

```sh
docker inspect notes-app-control-plane \
  --format '{{range $p, $v := .NetworkSettings.Ports}}{{$p}} -> {{range $v}}{{.HostPort}}{{end}}
{{end}}'
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
```

The second line must match the `6443/tcp` mapping from the first. It will —
they are the same number before and after a stop.

Surviving the pause: etcd, so every object, Application and Secret; the
local-path PVCs, including Jenkins' 8 Gi home with its jobs and credentials;
images side-loaded with `kind load`; and the ingress on port 80.

Expect two to five minutes of churn on resume before everything is `Running`,
with restart counters climbing and transient `failed calling webhook` errors
while Kyverno's admission controller is still starting. Wait it out:

```sh
kubectl get pods -A | grep -vE '1/1 +Running|2/2 +Running|Completed'
```

> **The nodes may come back on their own.** kind sets `restart=on-failure`,
> which is exactly right in both directions: an explicit `docker stop` exits
> cleanly, so they stay down until you start them, but a Docker or OrbStack
> *daemon* shutdown kills them non-zero and they restart with the daemon. So
> after `orb stop && orb start`, or a Mac reboot, the cluster is already coming
> back before you ask for it.

Two neighbouring options:

- **Stop the whole VM** — `orb stop` on OrbStack, or quitting Docker Desktop.
  Returns more than the cluster's share, and right for when you are done with
  containers altogether rather than just this cluster.
- **Keep the API up but idle** — scale the expensive workloads instead. Jenkins
  is the single biggest consumer at ~700 MB:

  ```sh
  kubectl -n jenkins scale statefulset jenkins --replicas=0   # and back to 1
  ```

  Useful when you still want `kubectl` and the Argo CD UI. For a real pause,
  stopping the nodes is simpler and gives back more.

---

## 12. Teardown

Permanent, unlike step 11:

```sh
kind delete cluster --name notes-app
rm -f /tmp/kind-notes-app.yaml /tmp/argocd-values.yaml /tmp/jenkins-values.yaml
```

The Jenkins image is pulled from Docker Hub rather than built here, so there is
nothing local to `docker rmi` — it is just another entry in your image cache.

Everything lives in the cluster, so deleting it removes the lot.
---

## 13. Troubleshooting

Symptom → diagnose → cause → fix. Every command is copy/paste.

```sh
export LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

### 1. MetalLB controller not Ready

```sh
kubectl -n metallb-system get pods
kubectl -n metallb-system logs deploy/controller --tail=50
kubectl -n metallb-system describe deploy controller | sed -n '/Events:/,$p'
```

Usually the image is still pulling, or the webhook cert Secret has not been
created yet. It is also the pod that gets starved first on a loaded machine —
see item 17. Wait it out:

```sh
kubectl -n metallb-system wait --for=condition=Available deploy/controller --timeout=300s
```

### 2. MetalLB speaker not Ready

```sh
kubectl -n metallb-system get ds speaker
kubectl -n metallb-system logs ds/speaker --tail=50
```

Speakers are a DaemonSet and use **host networking**. If one node's speaker is
down, addresses that would be announced from that node go dark while the Service
still shows an `EXTERNAL-IP`. A speaker stuck `Pending` usually means a port
conflict on the host network (7946/tcp+udp for memberlist):

```sh
kubectl -n metallb-system describe pod -l component=speaker | grep -A5 Events
```

### 3. LoadBalancer EXTERNAL-IP stays `<pending>`

```sh
kubectl get svc -A | grep LoadBalancer
kubectl get ipaddresspools -n metallb-system
kubectl -n metallb-system logs deploy/controller --tail=30 | grep -i 'no available ips\|pool'
kubectl describe svc <name> | sed -n '/Events:/,$p'
```

Causes, in order of likelihood:

- **No IPAddressPool applied** — re-run the step 3.4 heredoc.
- **Pool exhausted.** The pool is 51 addresses; each LoadBalancer Service takes
  one. This architecture should only ever use **one**. Check for strays:
  `kubectl get svc -A | grep LoadBalancer`.
- **`autoAssign: false`** on the pool while the Service does not name it.

### 4. IP address conflict

Symptom: the IP works intermittently, or reaches the wrong thing entirely.

```sh
arp -n "$LB_IP"                       # which MAC claims it?
ping -c 2 "$LB_IP"
docker network inspect kind --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
```

Cause: the pool overlaps addresses Docker hands out to containers, so both a
container and MetalLB claim the address and ARP resolves to whichever answered
last. Fix: move the pool to the **high end** of the subnet, above anything
Docker will allocate, and re-apply. Verify no container already holds an address
in the pool range using the `docker network inspect` output above.

### 5. MetalLB IP assigned but unreachable from macOS

The failure this whole design has to get right, and the one that is invisible
from inside the cluster.

```sh
kubectl get svc -n ingress-nginx          # EXTERNAL-IP present?
ping -c 2 "$LB_IP"                        # from macOS
netstat -rn -f inet | grep 192.168        # is there a route?
kubectl -n metallb-system logs ds/speaker --tail=20 | grep -i announc
```

If the speaker logs show it announcing the address but macOS cannot ping it,
**the container network is not routed to the host**. That is a property of your
Docker runtime, not of MetalLB:

- **OrbStack** routes container IPs to macOS natively. This works.
- **Docker Desktop** does not route the bridge network to the host. The IP will
  be assigned and permanently unreachable. Options: switch to OrbStack, or fall
  back to `kubectl port-forward` for each service (which defeats the one-IP
  design), or run the browser inside the VM.

Never conclude MetalLB works because `kubectl get svc` shows an `EXTERNAL-IP`.
Curl it from the host.

### 6. kind Docker network problem

```sh
docker network inspect kind --format '{{json .IPAM.Config}}'
docker network ls | grep kind
docker ps --filter name=notes-app
```

If the subnet is not what the step 3.4 pool assumes, the pool is
outside the network and nothing routes. Recreating the kind cluster can allocate
a **different** subnet — always re-check this after `kind delete`/`create`, and
update the pool file to match.

### 7. ingress-nginx not receiving an EXTERNAL-IP

```sh
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.type}'; echo
```

If `.spec.type` is `NodePort`, the switch never happened:

```sh
helm upgrade ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
  --version 4.15.1 --reuse-values \
  --set controller.service.type=LoadBalancer \
  --set controller.hostPort.enabled=false --wait
```

Confirm hostPort is really gone, or the controller keeps binding node ports:

```sh
kubectl -n ingress-nginx get deploy ingress-nginx-controller \
  -o jsonpath='{.spec.template.spec.containers[0].ports}' | tr ',' '\n' | grep -i hostport
```

No output is correct.

### 8. Ingress returns 404

```sh
kubectl get ingress -A
curl -sS -o /dev/null -w '%{http_code}\n' "http://$LB_IP/"
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=30
```

`404` on `/` is **expected** — no rule claims the bare root.

`404` on a path that should work means no rule matched:

- **`HOSTS` is not `*`.** A host-bound rule never matches an IP request. This is
  the single most common cause after migrating from hostname routing. Fix the
  release's values so the hostname is empty (Argo CD additionally needs
  `global.domain: ""`).
- **Wrong `ingressClassName`** — must be `nginx`.
- The controller has not reloaded yet. It takes a few seconds; re-curl.

### 9. Jenkins returns 404 under /jenkins

```sh
kubectl -n jenkins get ingress jenkins -o jsonpath='{.spec.rules[0]}'; echo
kubectl -n jenkins get cm jenkins -o yaml | grep -i prefix
kubectl -n jenkins exec svc/jenkins -c jenkins -- printenv JENKINS_OPTS 2>/dev/null
```

Cause: `controller.jenkinsUriPrefix` is unset while the Ingress path is
`/jenkins`, so nginx forwards `/jenkins/...` and Jenkins — listening on `/` —
has no such route. Fix by setting the prefix (step 7), **not** by adding a
rewrite.

### 10. Jenkins redirects to the wrong URL

Symptom: logging in bounces you to `http://<IP>/login` or to an old hostname.

```sh
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' "http://$LB_IP/jenkins"
kubectl -n jenkins get cm jenkins -o yaml | grep -i jenkinsurl
```

Cause: `controller.jenkinsUrl` still points at the old hostname. Jenkins uses it
to build absolute redirects. Fix:

```sh
helm upgrade jenkins jenkins/jenkins -n jenkins --version 5.9.54 \
  --reuse-values \
  --set controller.jenkinsUrl="http://${LB_IP}/jenkins" --wait
```

Note the IP changes if the pool changes — re-run this after any pool edit.

### 11. Jenkins CSS/JS doesn't load

Symptom: unstyled HTML, browser console full of 404s.

```sh
curl -sSL "http://$LB_IP/jenkins/login" | grep -oE '(href|src)="[^"]*"' | head -5
```

Every URL must begin with `/jenkins/`. If they begin with `/static/`, Jenkins
does not know its prefix — `jenkinsUriPrefix` is unset or did not apply.

If the URLs are correct but still 404, you have added a `rewrite-target`
annotation that strips the prefix before Jenkins sees it. Remove it: Jenkins
wants the prefix left on.

```sh
curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  "http://$LB_IP/jenkins/static/$(curl -sSL "http://$LB_IP/jenkins/login" | grep -oE 'static/[a-f0-9]+' | head -1 | cut -d/ -f2)/jsbundles/simple-page.css"
```

### 12. Application doesn't work under a path prefix

The app is the mirror image of Jenkins, and the distinction is the important
part of this whole document:

| | Jenkins | notes-app |
|---|---|---|
| Backend expects | `/jenkins/...` | `/app/...` |
| Mechanism | `jenkinsUriPrefix` | `SCRIPT_NAME` env |
| Rewrite | **no** | **no** |

```sh
kubectl -n default get ingress -o jsonpath='{.items[0].spec.rules[0].http.paths[0].path}'; echo
kubectl -n default exec deploy/... -- printenv SCRIPT_NAME     # or use a pod name
curl -sS "http://$LB_IP/app/" | grep -oE 'action="[^"]*"'
```

`action="/app/add"` is correct. `action="/add"` means `SCRIPT_NAME` is not set —
the page renders, then every Add and Delete 404s.

### 13. NGINX rewrite problems

Do **not** apply `rewrite-target` reflexively. Decide per backend:

- Backend serves the prefix itself (Jenkins, Argo CD, gunicorn+`SCRIPT_NAME`)
  → **no rewrite**, `pathType: Prefix`.
- Backend serves at `/` and cannot be told otherwise → rewrite with a capture
  group, and `pathType: ImplementationSpecific` because the path is a regex:

```yaml
annotations:
  nginx.ingress.kubernetes.io/rewrite-target: /$2
  nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  rules:
    - http:
        paths:
          - path: /foo(/|$)(.*)
            pathType: ImplementationSpecific
```

A rewrite that strips the prefix from a backend that wanted it produces a page
that renders once and then 404s everything — the hardest variant to diagnose,
because the first request looks fine.

### 14. Jenkins startup/probe problems

```sh
kubectl -n jenkins get pods
kubectl -n jenkins describe pod jenkins-0 | sed -n '/Events:/,$p' | tail -15
kubectl -n jenkins logs jenkins-0 -c jenkins --tail=50
```

Under a context path the probes must move with it. The Jenkins chart handles
this automatically — it templates them as
`{{ default "" .Values.controller.jenkinsUriPrefix }}/login` — so probes follow
`jenkinsUriPrefix` with no extra work. If you hand-write probes anywhere, they
must carry the prefix, or kubelet gets a 404, marks the container unhealthy and
restarts it forever while the app is actually fine.

```sh
kubectl -n jenkins get statefulset jenkins \
  -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}'; echo
```

Must print `/jenkins/login`.

### 15. Jenkins init container CrashLoopBackOff

```sh
kubectl -n jenkins get pod jenkins-0 -o jsonpath='{.status.initContainerStatuses[*].name}'; echo
kubectl -n jenkins logs jenkins-0 -c init --tail=50
```

The `init` container installs plugins and needs egress to
`updates.jenkins.io`. With no internet it fails and the pod never starts. It
also fails if a plugin in `additionalPlugins` does not exist for the Jenkins
version. Check the log for the exact plugin name, and remember
`installPlugins` **replaces** the chart's pinned defaults while
`additionalPlugins` adds to them.

### 16. PVC / data problems

```sh
kubectl -n jenkins get pvc
kubectl -n jenkins get pv
kubectl get storageclass
```

The Jenkins PVC must stay `Bound` to the **same** volume across upgrades —
that is where job history and credentials live. Record it before any upgrade:

```sh
kubectl -n jenkins get pvc jenkins -o jsonpath='{.spec.volumeName}'; echo
```

`helm upgrade` never touches it. `helm uninstall` may, and
`kind delete cluster` destroys it along with everything else. A PVC stuck
`Pending` means no default StorageClass — on kind that is `standard`.

### 17. Pods crash-looping right after a `git push`

Not a networking problem, and easy to misread as one.

```sh
docker exec notes-app-worker uptime
kubectl -n argocd get pods
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```

A push triggers a Jenkins build: `docker build` plus a Trivy scan will drive the
load average well above the VM's CPU count. Probes with `timeoutSeconds: 1` —
which is the default, and what `argocd-repo-server` uses — start timing out, and
kubelet restarts healthy processes. The give-away is `exitCode: 143` (SIGTERM)
with `reason: Error` and a container lifetime that exactly matches
`initialDelaySeconds + periodSeconds × failureThreshold`.

It resolves itself when the build finishes. If it happens constantly, give the
VM more CPU or stop pushing while testing.

---

## 14. Later: moving to hostname routing

Nothing in this architecture has to change to adopt DNS later. MetalLB and
ingress-nginx stay exactly as they are; only the Ingress rules gain a host.

When you have real DNS pointing `jenkins.example.com`, `app.example.com` and
`argocd.example.com` at the LoadBalancer IP:

| Release | Change |
|---|---|
| notes-app | `ingress.hosts[0].host: app.example.com`, its `paths[0].path: /` |
| Jenkins | `controller.ingress.hostName: jenkins.example.com`, `path: /`, drop `jenkinsUriPrefix`, set `jenkinsUrl` to the hostname |
| Argo CD | `global.domain: argocd.example.com`, drop `server.rootpath` / `server.basehref`, `server.ingress.path: /` |

The chart in `helm` already supports this: `ingress.hosts` is a list of
`{host, paths}`, `host` is optional, and setting it adds a `host:` to that rule.
Edit it in `helm/values.yaml` — **not** with `--set`, which replaces the whole
list entry and drops its `paths` (the chart fails with a message saying so
rather than rendering a broken Ingress).

Dropping the prefix means dropping `SCRIPT_NAME` too: clear it in `config.env`
**and** change both probe paths from `/app/healthz` to `/healthz` in the same
commit. gunicorn returns 500 for any request path that does not start with
`SCRIPT_NAME`, so a half-done change CrashLoopBackOffs the pod.

Two things get simpler at that point: each app is back at `/`, so no prefix
handling is needed anywhere, and the Argo CD UI limitation in step 8.3
disappears, because `<base href="/">` is then correct.

**Do not do this for local development.** It reintroduces the DNS dependency
this setup exists to avoid.
