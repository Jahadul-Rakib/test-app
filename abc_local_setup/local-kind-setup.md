# Local setup from scratch (kind)

Builds the whole stack on a local kind cluster — ingress, Argo CD, Argo
Rollouts, Kyverno, **Jenkins**, credentials, and the app. Everything that ships
a Helm chart is installed with Helm. Every step is a command you can paste; no
files to create by hand.

Three web UIs at the end, all on port 80 through the ingress controller, and
every one of them created by its own Helm chart — no Ingress manifest is
applied by hand anywhere in this document:

| UI | URL |
|---|---|
| Argo CD — **canary control lives here** | http://argocd.localtest.me |
| Jenkins | http://jenkins.localtest.me |
| The app | http://notes.localtest.me |

There is no separate Rollouts URL. The rollout extension renders canary steps,
weights and the Promote/Abort buttons inside Argo CD itself. The Rollouts
dashboard still runs — it is the API the extension proxies to — it just does not
need its own ingress.

`*.localtest.me` resolves to `127.0.0.1` publicly, so there is nothing to add to
`/etc/hosts` — provided the browser and the cluster are on the same machine. On
a remote Ubuntu server they are not, and step 8.2 covers that.

Budget ~30 minutes, most of it image pulls.

### macOS or Ubuntu

Both are covered. Almost everything is byte-identical — kind, kubectl and helm
take the same flags on either, and every manifest, values file and `kubectl`
call below is shared. What differs is marked where it comes up:

| Area | Difference | Where |
|---|---|---|
| Tool install | `brew` vs. release binaries | step 0.1 / 0.2 |
| Port 80 | far likelier to be taken on a server | step 1 |
| Shell quoting | zsh globs `[0]`, bash does not | step 3 |
| Reaching the UIs | loopback vs. a remote host | step 8.2 |

Memory is the one prerequisite that is genuinely not the same:

- **macOS** — Docker Desktop runs a VM with a hard limit, and that limit is what
  bites. Raise it to **4 GB minimum, 6 GB comfortable** under Settings →
  Resources.
- **Ubuntu** — Docker Engine has no VM and no limit to raise; containers draw on
  host RAM directly. Just confirm the box has ~4 GB free with `free -h`. When
  you do run out, there is no friendly Docker error — the kernel OOM killer
  reaps a process and you see `Exit Code 137` in `kubectl describe`.

> **Bare-metal Ubuntu, or a GPU node?** This document builds a *kind* cluster —
> Kubernetes inside Docker, one machine, throwaway. For a real Ubuntu server
> joined to a real cluster, and for anything involving an NVIDIA GPU (driver,
> container toolkit, device plugin, node labels and taints), see
> **[gpu-node-setup.md](gpu-node-setup.md)**. Steps 4, 5 and 6 below — Argo
> Rollouts, Argo CD, Kyverno — are plain Helm installs and carry over unchanged.

Everything below fits in 4 GB as written; Kyverno in step 6 is the piece that
pushes it over, so it is opt-in. At 4 GB do not add nodes or re-enable the Argo
CD components switched off in step 5 — the first thing to fail is the API
server, with `TLS handshake timeout`.

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
NVIDIA driver and container toolkit, the device plugin, and the cluster-side
essentials a fresh `kubeadm` cluster does not ship (CNI, storage,
metrics-server, ingress). Come back for steps 4–6 here, which apply to any
cluster unchanged.

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
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
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

Two nodes: the control-plane carries ingress and publishes 80/443 to your host,
plus one worker. Each kind node costs roughly 400 MB, so a third is the easiest
thing to cut at 4 GB — the app's 4 replicas still spread across two.

> **Port 80 in use?** Cluster creation fails. Stop whatever holds it, or change
> both `hostPort: 80` and the URLs below to `8080`. On an Ubuntu server this is
> far likelier than on a Mac — apache2 or nginx often comes pre-installed and
> already owns the port. `sudo ss -lptn 'sport = :80'` names the process
> (`sudo lsof -iTCP:80 -sTCP:LISTEN` on macOS).

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

## 3. Ingress controller

```sh
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version 4.15.1 \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=NodePort \
  --set-string 'controller.nodeSelector.ingress-ready=true' \
  --set 'controller.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'controller.tolerations[0].operator=Equal' \
  --set 'controller.tolerations[0].effect=NoSchedule' \
  --set controller.watchIngressWithoutClass=true \
  --set controller.replicaCount=1 \
  --wait
```

Two flag details that are not cosmetic. The single quotes are required on zsh
(the macOS default) — unquoted `tolerations[0]` is read as a glob and the
command dies with `no matches found` before helm is even reached. Ubuntu's bash
passes an unmatched glob through untouched, so the quotes are redundant there —
but harmless, which is why the command above is written once for both. And
`nodeSelector` must use
`--set-string`: with plain `--set`, helm types `true` as a boolean and the API
server rejects the Deployment with `cannot unmarshal bool into ... nodeSelector
of type string`.

Those flags matter. The stock chart asks for a `LoadBalancer` Service, which
never gets an external IP on kind and leaves the controller `<pending>` forever.
Instead it binds hostPort 80/443 on the node labelled `ingress-ready=true` — the
one whose ports kind published in step 1.

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://localhost      # 404 = up
```

`404` is success: nginx is answering and has no matching host yet.

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
cat <<'EOF' >/tmp/argocd-values.yaml
configs:
  params:
    # Plain HTTP. Otherwise the server serves a self-signed cert and every
    # port-forward, CLI call and ingress hop needs --insecure.
    server.insecure: true
  cm:
    # Poll git every 60s instead of the 180s default. GitHub cannot reach a
    # local cluster, so webhooks are out and polling is the only trigger.
    timeout.reconciliation: 60s
    timeout.reconciliation.jitter: 10s
    # Half two of the rollout extension: lets argocd-server proxy UI calls
    # through to the Rollouts dashboard API. Without the initContainer below
    # there is no UI to make those calls, and without this the UI has nothing
    # to call.
    extension.config: |
      extensions:
        - name: rollout
          backend:
            services:
              - url: http://argo-rollouts-dashboard.argo-rollouts.svc.cluster.local:3100

server:
  replicas: 1

  # The chart writes the Ingress itself -- no separate manifest to apply. It
  # reads `server.insecure` above to pick the backend port: true -> port 80
  # (plain HTTP, nginx terminates), false -> 443, which would need
  # ssl-passthrough enabled on the controller. Option 2 in the Argo CD docs.
  ingress:
    enabled: true
    ingressClassName: nginx
    hostname: argocd.localtest.me      # singular `hostname` since chart 7.x;
                                       # older docs show a `hosts:` list

  # Half one: an initContainer downloads the rollout extension bundle into
  # argocd-server, which is what actually renders canary steps, weights and the
  # Promote/Abort buttons inside the Argo CD UI. Without it a Rollout shows as
  # a generic resource with no controls.
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

# Not used by this setup, ~100-150 MB each. Turning them off is part of what
# keeps Argo CD inside a 4 GB budget. (applicationSet has no top-level
# `enabled` key in this chart, so it stays -- it is small.)
dex:
  enabled: false
notifications:
  enabled: false
EOF

helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.3.3 \
  -f /tmp/argocd-values.yaml \
  --wait
```

The UI is on http://argocd.localtest.me as soon as this finishes. Credentials
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

# docker buildx -- the Build stage sets DOCKER_BUILDKIT=1, and without this
# plugin the build dies with "BuildKit is enabled but the buildx component is
# missing or broken". The docker-cli package does not carry it.
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
cat <<'EOF' >/tmp/jenkins-values.yaml
controller:
  image:
    # Pulled from Docker Hub. Public, so no imagePullSecret -- contrast with
    # the app's own image in step 9.2. Registry and repository are split here
    # because the chart joins them itself; an empty registry renders a leading
    # slash and fails outright.
    registry: docker.io
    repository: jahadulrakib/jenkins-devops-kubernetes
    tag: lts-jdk21
    # The tag is immutable in practice, so pull once per node and stop asking.
    pullPolicy: IfNotPresent

  # The chart defaults to 0, which leaves `agent any` in the Jenkinsfile
  # queued forever. Run builds on the controller instead of provisioning
  # dynamic agents -- simpler locally, and the tools are in this image.
  numExecutors: 2

  # Root so the container can use the mounted docker socket without fighting
  # group ownership. Local-only shortcut.
  #
  # BOTH are required: the chart sets containerSecurityContext.runAsUser to
  # 1000, which overrides the pod-level runAsUser. Set only the pod-level one
  # and the container still starts as uid 1000, with "permission denied" on
  # the socket.
  runAsUser: 0
  fsGroup: 0
  containerSecurityContext:
    runAsUser: 0
    runAsGroup: 0
    readOnlyRootFilesystem: false
    allowPrivilegeEscalation: false

  jenkinsUrl: http://jenkins.localtest.me
  ingress:
    enabled: true
    ingressClassName: nginx
    hostName: jenkins.localtest.me

  # `installPlugins` is left unset ON PURPOSE. Setting it REPLACES the chart's
  # four defaults -- kubernetes, workflow-aggregator, git,
  # configuration-as-code -- rather than adding to them, and those defaults
  # ship pinned to versions tested against this chart release.
  # `additionalPlugins` layers on top and keeps the pins.
  #
  # There is no setup wizard here (the chart disables it), so nothing arrives
  # by itself: this list plus the four defaults is exactly what gets installed.
  additionalPlugins:
    # REQUIRED. Backs options { timestamps() }. Without it the pipeline dies
    # with `Invalid option type "timestamps"` before any stage runs.
    - timestamper:latest

    # withCredentials() in the Push, Sign and Update GitOps stages. It already
    # arrives transitively via workflow-aggregator -> pipeline-model-definition,
    # but it is load-bearing enough here to name rather than inherit.
    - credentials-binding:latest

    # Not used by the current Jenkinsfile -- it shells out to `docker` and
    # never calls the docker.* DSL or readYaml/readJSON. Kept because both are
    # what you reach for first when editing the pipeline.
    - docker-workflow:latest
    - pipeline-utility-steps:latest

    # Suggested-set essentials worth having on any Jenkins:
    - ws-cleanup:latest              # cleanWs(); the PVC is only 8Gi
    - github:latest                  # commit/branch links back to the repo
    - antisamy-markup-formatter:latest   # stops raw HTML in descriptions
    - build-timeout:latest           # wall-clock kill for wedged builds

# No dynamic Kubernetes agents. The chart ships a default pod template, and
# `agent any` in the Jenkinsfile will happily schedule onto it -- a bare
# inbound-agent image with no docker, helm, trivy or cosign, so the build dies
# with `docker: not found`. Turning this off leaves the controller as the only
# executor, which is where the tooling lives.
agent:
  enabled: false

persistence:
  storageClass: standard
  size: 8Gi
  # Host docker socket, passed through by the kind extraMount in step 1.
  volumes:
    - name: docker-sock
      hostPath:
        path: /var/run/docker.sock
  mounts:
    - name: docker-sock
      mountPath: /var/run/docker.sock
EOF

helm install jenkins jenkins/jenkins \
  --namespace jenkins --create-namespace \
  --version 5.9.54 \
  -f /tmp/jenkins-values.yaml \
  --wait --timeout 10m
```

---

## 8. Reaching the UIs

**Check Ingresses:**

```sh
kubectl get ingress -A
```

### 8.1 Logging in

Both usernames are `admin`; both passwords are generated at install time and
kept in a Secret. Print them:

```sh
# Argo CD -- http://argocd.localtest.me
echo "user: admin"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# Jenkins -- http://jenkins.localtest.me
kubectl -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-user}' | base64 -d; echo
kubectl -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

Or both at once:

```sh
printf 'Argo CD   http://argocd.localtest.me\n  user: admin\n  pass: %s\n' \
  "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
printf 'Jenkins   http://jenkins.localtest.me\n  user: %s\n  pass: %s\n' \
  "$(kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-user}' | base64 -d)" \
  "$(kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)"
```

The `base64 -d` matters — Secret values are stored base64-encoded, so reading
the field without it gives you gibberish that will not log you in.

Argo CD's username is always `admin` and is not stored in the Secret; only the
password is. After logging in, change it under **User Info → Update Password**,
then delete the bootstrap Secret, which Argo CD does not need again:

```sh
kubectl -n argocd delete secret argocd-initial-admin-secret
```

Jenkins keeps its Secret in use, so leave that one alone.

### 8.2 Reaching a remote Ubuntu server

Skip this on a laptop, macOS or Ubuntu, where the browser and the cluster share
a machine.

The hostnames above work because `*.localtest.me` resolves to `127.0.0.1`. On a
headless server that is the *server's* loopback, so the `curl` checks pass over
SSH while your laptop's browser gets nothing. The ingress is fine; the name just
points at the wrong machine.

Fix it on the laptop, not on the server — one line, and every URL in this
document keeps working unchanged:

```sh
# on your LAPTOP, with the server's IP
echo "203.0.113.10  argocd.localtest.me jenkins.localtest.me notes.localtest.me" \
  | sudo tee -a /etc/hosts
```

A local `/etc/hosts` entry beats public DNS, so this overrides the `127.0.0.1`
answer for those three names only. `Host:` still arrives as
`argocd.localtest.me`, which is what nginx routes on — anything that rewrites
the Host header, a plain `http://<server-ip>` included, lands on the default
backend and 404s.

Two alternatives:

- **SSH tunnel**, if you cannot edit `/etc/hosts` or the server is firewalled.
  Port 80 locally needs root, and the hostnames still have to resolve to
  `127.0.0.1`, which `localtest.me` already does:

  ```sh
  sudo ssh -L 80:localhost:80 user@203.0.113.10 -N
  ```

- **`sslip.io`**, to skip client-side config entirely — `argocd.203.0.113.10.sslip.io`
  resolves to that IP for everyone. It means changing the hostname in three
  places (`server.ingress.hostname` in step 5, `controller.ingress.hostName` and
  `jenkinsUrl` in step 7, `ingress.host` in `helm/notes-app/values.yaml`) and
  depending on a public resolver.

Whichever you pick, open port 80 if a firewall is running — a cloud provider's
security group counts as one too:

```sh
sudo ufw allow 80/tcp        # only if `sudo ufw status` says active
```

> Everything here is HTTP with no auth in front of it, and step 5 turns TLS off
> inside the cluster on purpose. Do not expose that on a public IP. Bind the
> server to a private network, or use the SSH tunnel, which keeps the whole
> stack on loopback.

---

## 9. Credentials

Four things: two cluster secrets, a signing keypair, and the Jenkins entries.
Every `read -rs` below reads with echo off, so no token reaches your shell
history or the process list.

### 9.1 Argo CD repository credential — required

Argo CD cannot clone a private repo without this, and the Application sits in
`ComparisonError / authentication required`. It is a **bootstrap** credential:
it cannot come from the chart, because Argo CD needs it to clone the repo that
holds the chart.

```sh
kubectl apply -f - <<'EOF'
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
  password: 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
EOF
```

Argo CD only clones, so a read-only `repo` PAT is enough here — the token above
is the same write-scoped one Jenkins uses, which is fine for a demo but means a
single revoke breaks both.

Re-running rotates the token in place. Check it in the UI: **Settings →
Repositories** at <http://argocd.localtest.me> — `CONNECTION STATUS` must read
`Successful`. `Failed` almost always means the `url` above does not match
`repoURL`.

### 9.2 Docker Hub pull secret — only if the image repo is private

Consumed by the **kubelet**, so it belongs in the namespace where the pod runs
(`default`), *not* `argocd`. Getting that wrong is the usual cause of
`ImagePullBackOff` with `pull access denied`.

`kubectl` builds the whole `.dockerconfigjson`, including the base64 `auth`
field, from a username and token — nothing to encode by hand.

```sh
kubectl create secret docker-registry dockerhub-pull \
  --namespace default \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=jahadulrakib \
  --docker-password=dckr_pat_getuazgIuPPCJFgRfkJQ5_mjRQQ \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run | apply` pipe is what makes it re-runnable — plain
`kubectl create secret` fails with `AlreadyExists` on a rotation.

The chart only *references* this by name, never creates it, which keeps the
token out of git:

```yaml
# helm/notes-app/values.yaml
imagePullSecrets:
  - name: dockerhub-pull
```

If the repo ends up public, skip this entirely — the kubelet pulls anonymously
and never reads the secret.

### 9.3 Jenkins credentials

The IDs must match exactly — the `Jenkinsfile` looks them up by ID:

| ID | Kind | Username | Password / content                         |
|---|---|---|--------------------------------------------|
| `github-token` | Username with password | `Jahadul-Rakib` | `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` |
| `dockerhub` | Username with password | `jahadulrakib` | `dckr_pat_getuazgIuPPCJFgRfkJQ5_mjRQQ`     |
| `cosign-key` | Secret text | — | in below.....                              |
| `cosign-key-password` | Secret text | — | `jBSXFSWcBmTGn2tfVAA9fUtuRrofq3cCW1c1vDBQ` |


**cosign-key:**

```
-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----
eyJrZGYiOnsibmFtZSI6InNjcnlwdCIsInBhcmFtcyI6eyJOIjo2NTUzNiwiciI6
OCwicCI6MX0sInNhbHQiOiJJUmpFeTNWeGNUUG5McTRJaFdQMVo2cHR3NjRYWlBQ
cDNmdWxSNmVvWmVNPSJ9LCJjaXBoZXIiOnsibmFtZSI6Im5hY2wvc2VjcmV0Ym94
Iiwibm9uY2UiOiJHWGN3dFlhSW11Qld6eHdRN3U5eFdrc2NEa1llc1VtdyJ9LCJj
aXBoZXJ0ZXh0IjoiK1V1M24wbE05UlFRVk1YTmhoSkc0eWJmUUxFTzIxNndWQzRn
N0V5ekFlSlZubWpiRzZtN0FVamVXZDlvTzFXK2JZcE5XOGJNWE5naTBWeUR6N1J0
SWREaEJickg3TTRkWXNWWE4vZVRvdWliQ3NET1ljdUhYcHlKNEk3K2dPMmtiRVA3
ekVic3ZBVjh6T3lSeWNubFFWK0ErMkpKT09SV2FqTWxseXVMaGxYMWRyT2cvVEFU
TWtBZ1pJcmZpWnRXcVhPeVh5TmJhR3JEdXc9PSJ9
-----END ENCRYPTED SIGSTORE PRIVATE KEY-----
```

**NOTE:** `github-token` needs **write** `repo` scope — `Update GitOps` commits the image
tag back.


## 10. Pause and resume

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

## 11. Teardown

Permanent, unlike step 10:

```sh
kind delete cluster --name notes-app
rm -f /tmp/kind-notes-app.yaml /tmp/argocd-values.yaml /tmp/jenkins-values.yaml
```

The Jenkins image is pulled from Docker Hub rather than built here, so there is
nothing local to `docker rmi` — it is just another entry in your image cache.

Everything lives in the cluster, so deleting it removes the lot.