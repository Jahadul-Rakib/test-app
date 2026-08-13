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
                   ▼                              ▼  helm/notes-app/values.yaml
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

## Repository layout

| Path | Purpose |
|---|---|
| `app.py`, `templates/` | The Flask app |
| `Dockerfile` | Runtime image |
| `Jenkinsfile` | The CI pipeline |
| `helm/notes-app/` | The chart Argo CD renders (a Rollout, not a Deployment) |
| `argocd/application.yaml` | Tells Argo CD what to watch |
| `abc_local_setup/cosign/cosign.*` | Signing keypair (see the note in the setup doc) |
| `abc_local_setup/local-kind-setup.md` | **Full setup, end to end** — cluster, addons, credentials |

## Setup

**`abc_local_setup/local-kind-setup.md`** builds the whole stack from scratch on
a local kind cluster — cluster, ingress, Argo CD, Argo Rollouts, Kyverno,
Jenkins, credentials and the app — as copy-paste commands.

Against a real cluster the same steps apply, minus the kind-specific ingress and
image side-loading.

## Canary deployment (Argo Rollouts)

The workload is a **Rollout**, not a Deployment. The Argo Rollouts
controller owns the ReplicaSets and steps a new image through a canary,
pausing at 25/50/75% — configured under `rollout.canary.steps` in
`helm/notes-app/values.yaml`.

### The replica-count trap

With `rollout.trafficRouting.enabled: false` (the default), **`setWeight` is
approximated by replica count**. At `replicaCount: 1` there is no such thing as
25% — the canary is one whole pod, which is 100% of your traffic. The steps
above are meaningless until you either raise `replicaCount` to at least 4, or
turn on traffic routing.

With `trafficRouting.enabled: true`, nginx splits real request percentages
regardless of replica count. That path needs `ingress.enabled: true`, because
Rollouts steers traffic by rewriting the stable Ingress, and it renders a second
`-canary` Service for nginx to split against.

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

> Both private files are **committed to this repo**, deliberately, so the demo
> is reproducible from a clone. Wrong for anything real: anyone with read access
> can sign images this cluster will trust.

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
| Validate Helm Chart | `helm lint` + `helm template` | Chart renders badly |
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
helm lint helm/notes-app
helm template notes-app helm/notes-app --set image=notes-app:latest
```

Enable the ingress with `--set ingress.enabled=true --set ingress.host=notes.local`.

## Routes

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | GET | The page |
| `/add` | POST | Add a note |
| `/delete/<idx>` | POST | Delete a note |
| `/healthz` | GET | Liveness/readiness probe |
