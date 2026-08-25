# notes-app

A single-page notes app (Flask), deployed to a private Kubernetes cluster by
Jenkins and Argo CD. Notes live in memory and reset on restart.

## Architecture

The cluster sits in a private network with **no inbound route**. That single
constraint shapes the whole design: nothing outside can reach the cluster, so
every step is *pull*-based rather than push-based.

```
  you ──push──► GitHub (private repo)
                   │
                   │  Jenkins polls every 60s (no inbound route for webhooks)
                   ▼
              ┌─────────────────────────────────────────────┐
              │ Jenkins                                     │
              │   Checkout → Build → Scan → Validate Chart  │
              │            → Push → Sign → Update GitOps    │
              └─────────────────────────────────────────────┘
                   │                              │
       push image  │                              │  commit new tag into
                   ▼                              ▼  helm/values.yaml
             Docker Hub                        GitHub
                   │                              │
                   │                              │  Argo CD polls every 60s
                   │                              ▼
    ╔══════════════│══════════════════════════════════════════════════════╗
    ║  PRIVATE     │           ┌──────────┐                               ║
    ║  CLUSTER     │           │ Argo CD  │ renders chart, applies it     ║
    ║              │           └────┬─────┘                               ║
    ║              │                ▼                                     ║
    ║              │           Rollout ──► canary + stable pods          ║
    ║              │                            ▲                         ║
    ║              └──kubelet pulls image───────┘                         ║
    ║                                                                     ║
    ║              Kyverno (optional) rejects unsigned images at          ║
    ║              admission, before the pod is created                   ║
    ╚═════════════════════════════════════════════════════════════════════╝
```

**Why Jenkins does not deploy.** An earlier version ran `helm upgrade` from
Jenkins, which needs a route to the Kubernetes API server — impossible here.
Instead Jenkins commits the new image tag to `values.yaml`, and Argo CD, running
*inside* the cluster, pulls that change. Jenkins never touches the cluster.

**Why webhooks are not used.** GitHub cannot reach Jenkins, and cannot reach
Argo CD. Both poll instead, each on a 60s interval. Worst case from `git push`
to a running pod is roughly 4–6 minutes, most of it the actual build.

**Why image tags are git SHAs.** A workload is only re-applied when its spec
changes. With a mutable tag like `latest` the rendered manifest is byte-identical
every build, Argo CD sees no diff, and nothing ever redeploys. Immutable tags are
what make GitOps work at all.

### The loop guard

Jenkins writes to the repo that Jenkins watches, which would trigger Jenkins
forever. The write-back commit is stamped `[ci skip]`, and every stage carries
`when { not { changelog "${CI_SKIP_PATTERN}" } }`, so that build does nothing.

## Local access: one IP, path-based routing

No DNS and no `/etc/hosts` entry are required. MetalLB assigns a single
LoadBalancer IP to ingress-nginx, which routes on path:

```
  browser ──► http://<METALLB-IP>/jenkins ──┐
              http://<METALLB-IP>/app       ├─► MetalLB ─► ingress-nginx ─┬─► Jenkins
              http://<METALLB-IP>/argocd  ──┘      (one IP)               ├─► notes-app
                                                                         └─► Argo CD
```

```sh
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo
```

Each backend handles its prefix differently, and the distinction matters:
Jenkins serves `/jenkins` itself via `jenkinsUriPrefix`; the app serves `/app`
via gunicorn's `SCRIPT_NAME`. **Neither uses an nginx rewrite** — both want the
prefix left on. Details and the full setup are in
`abc_local_setup/local-kind-setup.md` step 3 (MetalLB) and steps 7–8.

## Repository layout

| Path | Purpose |
|---|---|
| `app.py`, `templates/` | The Flask app |
| `Dockerfile` | Runtime image |
| `Jenkinsfile` | The CI pipeline |
| `helm/` | Generic app chart Argo CD renders — `workload.kind: Rollout` by default |
| `argocd/application.yaml` | Tells Argo CD what to watch |
| `k3s-lab/README.md` | **3-node K3s on OrbStack** — cluster, addons, Jenkins + Argo CD, end to end |
| `abc_local_setup/cosign/cosign.*` | Signing keypair (see the note in the setup doc) |
| `abc_local_setup/local-kind-setup.md` | **Full setup, end to end** — cluster, addons, credentials |
| `abc_local_setup/gpu-node-setup.md` | **Bare-metal Ubuntu GPU node** — driver, containerd, toolkit, `kubeadm join` |

## Setup

Three documents, one per target:

**`k3s-lab/README.md`** builds a **3-node K3s cluster on OrbStack** with every
bundled K3s add-on replaced by the production equivalent — Calico, CoreDNS,
MetalLB, ingress-nginx, OpenEBS — then layers Argo Rollouts, Argo CD and Jenkins
on top. Its CI builds with **Kaniko**, not a mounted Docker socket, because a
containerd cluster has no socket to mount. Start here for a multi-node target.

**`abc_local_setup/local-kind-setup.md`** builds the whole stack from scratch on
a local kind cluster — cluster, ingress, Argo CD, Argo Rollouts, Kyverno,
Jenkins, credentials and the app — as copy-paste commands. Its **step 10** is
the GPU *cluster side* on its own: device plugin or GPU Operator, node labels,
taints and scheduling, against a cluster that already exists. It runs on kind
with no GPU by advertising a fake one, so the scheduling behaviour is real.

**`abc_local_setup/gpu-node-setup.md`** takes a bare-metal Ubuntu server with an
NVIDIA card and turns it into a Kubernetes node that can run GPU containers:
driver, containerd, NVIDIA Container Toolkit, `kubeadm join`. **13 steps, one
command block each**, plus appendices for k3s, the essentials a fresh `kubeadm`
cluster lacks (CNI, storage, metrics-server, ingress, DCGM), and troubleshooting.

The two split along a hard line — the node side needs SSH and real hardware, the
cluster side needs only a kubeconfig:

| Half | Doc |
|---|---|
| Driver, containerd, toolkit, join | `gpu-node-setup.md` steps 1–13 |
| Device plugin, labels, taints, scheduling | `local-kind-setup.md` step 10 |

Against a real cluster the kind steps apply minus the kind-specific ingress and
image side-loading; the Argo CD, Argo Rollouts and Kyverno installs carry over
verbatim.

## Reusable chart (copy-paste, no dependency)

`helm/` is a **generic app chart**. Nothing under `templates/` names an app: the
name comes from `nameOverride`, the image from `image`, the ports and probe paths
from values. To deploy a different app you copy `values.yaml` and edit it — you do
not touch a template.

| File | Renders |
|---|---|
| `helm/templates/workload.yaml` | Deployment, Rollout, StatefulSet or DaemonSet — `workload.kind` picks |
| `helm/templates/service.yaml` | stable Service, plus headless (StatefulSet) and canary (traffic routing) |
| `helm/templates/ingress.yaml` | multi-host, multi-path, optional TLS |
| `helm/templates/configmap.yaml` | env + files ConfigMaps |
| `helm/templates/secret.yaml` | env + files Secrets |
| `helm/templates/serviceaccount.yaml`, `hpa.yaml`, `pdb.yaml` | one optional resource each |
| `helm/templates/extra.yaml` | arbitrary manifests from `extraManifests` |

```sh
cp -r helm ../other-project/helm
# then edit ../other-project/helm/values.yaml -- nameOverride, image, ports, probes
```

**Pass data, get a resource.** Nothing is created "just in case":

| Resource | Created when |
|---|---|
| workload | always |
| Service / headless / canary | `service.enabled` / `kind: StatefulSet` / `workload.canary.trafficRouting` |
| Ingress | `ingress.enabled` |
| ConfigMap env / files | `config.env` / `config.files` non-empty |
| Secret env / files | `secrets.env` / `secrets.files` non-empty |
| ServiceAccount | `serviceAccount.create` |
| HPA / PDB | `autoscaling.enabled` / `podDisruptionBudget.enabled` |
| anything else | `extraManifests` non-empty |

Three properties make a single template file safe to lift out on its own:

- **No `_helpers.tpl`.** Each template opens with the same four-line preamble
  computing `$name`, `$fullname`, `$selector` and `$labels`. The repetition is the
  point: any one file can be dropped into another chart and still render. Change
  the naming rule and you change it in every file — `grep '$fullname :='`.
- **No chart-specific names.** Every value derives from `.Chart` / `.Release` /
  `nameOverride`, so a copy picks up the new chart's name automatically.
- **Every values block is optional.** Each is read through a `| default` guard, so
  a chart whose `values.yaml` omits `gpu`, `config`, `secrets` or `workload`
  entirely still renders. Without those guards a missing block fails with
  `nil pointer evaluating interface {}.enabled`, the usual reason a copied
  template explodes in its new home.

`workload.yaml` hashes `configmap.yaml` and `secret.yaml` **by path** into
`checksum/config` and `checksum/secret`. Rename either file in a destination chart
and update those two paths, or config changes silently stop restarting pods.

## Configuration and scheduling

`helm/values.yaml` is sectioned and commented end to end. The blocks beyond the
app itself:

- **`config`** — renders `templates/configmap.yaml`. `config.env` becomes
  environment variables via `envFrom` (the app reads `APP_TITLE`/`APP_ENV` and
  echoes both from `/healthz`); `config.files` becomes files mounted at
  `config.mountPath`. Two ConfigMaps, because `envFrom` would otherwise turn a
  file body into an environment variable. The pod template hashes the rendered
  ConfigMap into a `checksum/config` annotation — without it a config edit
  changes nothing in the pod spec, so no rollout is triggered and the pods keep
  serving the old values.
- **`secrets`** — same two shapes, and ships empty. A Kubernetes Secret is
  base64, which is encoding, not encryption: anything put here is committed to
  git. Real credentials belong in a Secret created elsewhere and referenced with
  `extraEnvFrom`.
- **`nodeSelector` / `tolerations` / `affinity` / `topologySpreadConstraints` /
  `runtimeClassName`** — generic placement, empty by default and omitted from the
  rendered pod spec.
- **`gpu`** — off by default, and vendor-agnostic. `gpu.vendor` (`nvidia`, `amd`,
  `intel`) selects the resource name and node label; anything set explicitly
  overrides the preset. Enabling it adds the GPU to the container **limits**
  (extended resources are limits-only and whole devices only), merges the vendor
  node selector, and appends the toleration for the GPU taint. All three are
  required: the limit alone leaves the pod `Pending`, and the selector alone
  leaves it running without a GPU. Details in `local-kind-setup.md` step 10.5 and
  `gpu_node_setup/k3s_gpu_node_setup.md`.
- **`serviceAccount` / `autoscaling` / `podDisruptionBudget` /
  `extraManifests`** — all off or empty by default.

## Canary deployment (Argo Rollouts)

The workload is a **Rollout**, not a Deployment — `workload.kind` in
`helm/values.yaml`, which also accepts `Deployment`, `StatefulSet` and
`DaemonSet`. The Argo Rollouts controller owns the ReplicaSets and steps a new
image through a canary, pausing at 25/50/75% — configured under
`workload.canary.steps`.

### The replica-count trap

With `workload.canary.trafficRouting: false` (the default), **`setWeight` is
approximated by replica count**. At `workload.replicaCount: 1` there is no such
thing as 25% — the canary is one whole pod, which is 100% of your traffic. The
steps above are meaningless until you either raise `workload.replicaCount` to at
least 4, or turn on traffic routing.

With `workload.canary.trafficRouting: true`, nginx splits real request
percentages regardless of replica count. That path needs `ingress.enabled: true`,
because Rollouts steers traffic by rewriting the stable Ingress, and it renders a
second `-canary` Service for nginx to split against.

### Why `ignoreDifferences` is in application.yaml

During a canary the Rollouts controller **rewrites the Service selectors** to
steer traffic. Argo CD sees that as drift and, with `selfHeal: true`, reverts it
mid-rollout — traffic snaps back to stable and the canary stalls. So:

```yaml
ignoreDifferences:
  - group: ""
    kind: Service
    jsonPointers: [/spec/selector]
syncOptions:
  - RespectIgnoreDifferences=true
```

Both halves are required. `ignoreDifferences` alone only hides the drift from
the diff view; a sync would still apply the desired selector and clobber it.
`RespectIgnoreDifferences=true` makes sync honour the ignore list too.

A paused canary reports the Application as **Progressing**, not Degraded — Argo
CD ships a health check for Rollouts, so that is expected, not a stuck sync.

## Image signing

Jenkins **signs** with the private key; Kyverno **verifies** with the public one
at admission. Signing alone enforces nothing — Argo CD has no image-signature
verification of its own.

The keypair lives in `abc_local_setup/cosign/`, and its public half is written
verbatim into the Kyverno policy in the setup doc.

> **`cosign.key` and `cosign.password` are still tracked in this repo**, so the
> demo is reproducible from a clone — and so anyone with read access can sign
> images this cluster will trust. Before this is anything but a demo: `git rm
> --cached` both, add them to `.gitignore`, and generate a fresh keypair, because
> the old one stays reachable in git history. No other credential appears
> anywhere in these documents; every token is read at the prompt with `read -rs`
> or looked up by Jenkins credential ID.

**Install cosign v2.x on the Jenkins agent, not v3.** The `Sign Image` stage
passes `--tlog-upload=false`, which v3 removed, and the stage asserts the major
version and fails fast. The Kyverno policy sets `ctlog.ignoreTlog: true` to
match — if signing skips the transparency log and verification demands one,
every check fails.

## Pipeline stages

| Stage | Does | Fails the build when |
|---|---|---|
| Checkout | Clean clone of `main`, derives the SHA tag | — |
| Build Image | `docker build` with OCI labels | Build error |
| Scan Image | Trivy vuln + secret scan, emits SBOM | HIGH/CRITICAL found |
| Validate Helm Chart | `helm lint` + `helm template`, default **and** `gpu.enabled=true` | Chart renders badly |
| Push Image | Pushes the SHA tag, retries 3× | Registry unreachable |
| Sign Image | cosign signature + SBOM attachment | Signing fails (skipped if unconfigured) |
| Update GitOps | Commits the tag to `values.yaml`, retries 3× | 3 failed pushes |

There is **no test stage** — nothing verifies the app works before it reaches
production. Argo CD auto-syncs with `selfHeal`, so a broken commit deploys
itself.

## Run locally

```bash
pip install -r requirements.txt
python app.py          # http://localhost:8080
```

```bash
docker build -t notes-app:latest .
docker run -p 8080:8080 notes-app:latest
```

```bash
helm lint helm
helm template notes-app helm --set image=notes-app:latest
```

The ingress is on by default at `/app` with no host. To pin a hostname, edit
`ingress.hosts[0].host` in `helm/values.yaml` — not with `--set`, which replaces
the whole list entry and drops its `paths` (the chart fails with a message saying
so rather than rendering a broken Ingress).

## Routes

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | GET | The page |
| `/add` | POST | Add a note |
| `/delete/<idx>` | POST | Delete a note |
| `/healthz` | GET | Liveness/readiness probe |
