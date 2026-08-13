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
| `argocd/repo-secret.sh` | Credential Argo CD clones with |
| `docs/kubernetes/dockerhub-pull-secret.sh` | Credential the kubelet pulls with |
| `docs/kubernetes/kyverno-verify-image.yaml` | Signature enforcement policy |
| `docs/kubernetes/cosign.pub` | Public signing key (safe in git) |
| `docs/credentials.md` | Every credential, where it lives and why |

## Setup

### 1. Jenkins credentials

Manage Jenkins → Credentials → System → Global:

| ID | Kind | Contents |
|---|---|---|
| `github-token` | Username with password | GitHub user + PAT with **write** `repo` scope |
| `dockerhub` | Username with password | Docker Hub user + access token |
| `cosign-key` | Secret file | `docs/kubernetes/cosign.key` (optional, signing) |
| `cosign-key-password` | Secret text | the key's password (optional, signing) |

The IDs must match exactly — the `Jenkinsfile` looks them up by ID.

The agent needs `docker`, `helm`, `git`, and `trivy` on `PATH`, plus `cosign` if
you enable signing.

### 2. Create the job

A Pipeline job pointed at this repo, script path `Jenkinsfile`. Polling is
declared in the file itself (`pollSCM('* * * * *')`), so no trigger config is
needed in the UI.

### 3. Cluster credentials

```sh
./argocd/repo-secret.sh                  # required — Argo CD clones with this
./kubernetes/dockerhub-pull-secret.sh    # only if the image repo is private
```

Both prompt for their token with echo disabled and build the manifest
themselves. Nothing sensitive is committed. Details in `docs/credentials.md`.

### 4. Argo CD polling interval

Not a field on the Application — it is cluster-wide, and defaults to 180s:

```sh
kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"timeout.reconciliation":"60s","timeout.reconciliation.jitter":"10s"}}'
kubectl -n argocd rollout restart statefulset/argocd-application-controller
```

The restart is required — the controller reads that value only at startup.

### 5. Deploy

```sh
kubectl apply -f argocd/application.yaml
kubectl -n argocd get application notes-app -w
```

From here every push to `main` flows through on its own.

### 6. Check egress first

Every step above assumes the cluster can reach the internet outbound. Confirm
before debugging anything else:

```sh
kubectl -n argocd run nettest --rm -it --restart=Never \
  --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' https://registry-1.docker.io/v2/
```

`401` means success (the endpoint requires auth; you reached it). A timeout
means no egress, and you would need an internal registry and git mirror instead.

## Canary deployment (Argo Rollouts)

The workload is a **Rollout**, not a Deployment. The Argo Rollouts controller
owns the ReplicaSets and steps a new image through a canary instead of
replacing everything at once.

### Install the controller

Argo CD cannot sync the chart without the CRDs — it fails with
`no matches for kind "Rollout"`.

```sh
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

The kubectl plugin is what you drive rollouts with — `kubectl rollout` does not
work on a Rollout:

```sh
kubectl krew install argo-rollouts        # or brew install argoproj/tap/kubectl-argo-rollouts
kubectl argo rollouts get rollout notes-app --watch
kubectl argo rollouts promote notes-app
kubectl argo rollouts abort notes-app
```

For the Argo CD UI to render rollout progress, install the rollout extension
into Argo CD separately (`argo-rollouts` extension in `argocd-cm`).

### Steps

Configured in `helm/notes-app/values.yaml`:

```yaml
rollout:
  canary:
    steps:
      - setWeight: 25
      - pause: {duration: 60s}
      - setWeight: 50
      - pause: {duration: 60s}
      - setWeight: 75
      - pause: {duration: 60s}
```

There is no trailing `setWeight: 100` — full promotion is implicit once the
last step finishes. Use `- pause: {}` with no duration to hold indefinitely
until someone runs `promote`, which turns the canary into a manual gate.

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

Two halves that are easy to conflate:

| | Key | Used by |
|---|---|---|
| **CI** — signs | `docs/kubernetes/cosign.key` (private) | Jenkins, `Sign Image` stage |
| **CD** — verifies | `docs/kubernetes/cosign.pub` (public) | Kyverno, at admission |

Signing alone enforces nothing. Until Kyverno is installed with the public key,
the signature is just provenance metadata.

### Generating the keypair

A keypair is already generated. All three files sit in `docs/kubernetes/`:

| File | In git? | Goes to |
|---|---|---|
| `docs/kubernetes/cosign.key` | **no** — gitignored | Jenkins credential `cosign-key` |
| `docs/kubernetes/cosign.password` | **no** — gitignored | Jenkins credential `cosign-key-password` |
| `docs/kubernetes/cosign.pub` | **yes** — public | Embedded in the Kyverno policy |

`.gitignore` blocks the two private ones, so `git status` will not list them —
that is deliberate, not a sign they are missing. Confirm with:

```sh
ls -l kubernetes/cosign.key kubernetes/cosign.password
git check-ignore -v kubernetes/cosign.key kubernetes/cosign.password
```

Move them into Jenkins and your password manager, then delete the local copies.
Nothing in the pipeline reads them from disk.

To regenerate:

```sh
cosign generate-key-pair          # prompts for a password
```

Confirm a key and public key are a matching pair:

```sh
cosign public-key --key kubernetes/cosign.key   # equals kubernetes/cosign.pub
```

> **Install cosign v2.x on the Jenkins agent, not v3.** The `Sign Image` stage
> passes `--tlog-upload=false`, which v3 removed — it errors and demands a
> `--signing-config` with no transparency log service instead. This keypair was
> signed and verified end-to-end on v2.6.5.

### Wiring the private key into Jenkins (CI)

1. Manage Jenkins → Credentials → Add → **Secret file**, upload `docs/kubernetes/cosign.key`,
   ID `cosign-key`.
2. Add → **Secret text**, paste the contents of `docs/kubernetes/cosign.password`,
   ID `cosign-key-password`.
3. Fill both IDs into the `Jenkinsfile` `environment` block:

   ```groovy
   COSIGN_CREDENTIALS_ID = 'cosign-key'
   COSIGN_PASSWORD_CREDENTIALS_ID = 'cosign-key-password'
   ```

4. Move `docs/kubernetes/cosign.password` into your password manager and delete the
   local file. Keep `docs/kubernetes/cosign.key` somewhere safe — anyone holding it
   can sign images your cluster will trust.

The `Sign Image` stage is gated on **both** IDs being non-empty, so it stays
skipped until you fill in both.

### Wiring the public key into Kyverno (CD)

`docs/kubernetes/kyverno-verify-image.yaml` already has the public key embedded:

```sh
helm repo add kyverno https://kyverno.github.io/kyverno
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
kubectl apply -f kubernetes/kyverno-verify-image.yaml
```

It ships as `validationFailureAction: Audit` — failures are logged, nothing is
blocked. Confirm it passes, then switch to `Enforce`. Under `Enforce` a mismatch
means pods are refused and the app stops deploying.

Two things this depends on:

- **Kyverno needs egress to `docker.io`** — signatures live in the registry
  beside the image.
- **`ctlog.ignoreTlog: true` must stay.** Jenkins signs with
  `--tlog-upload=false` because `rekor.sigstore.dev` is unreachable from a
  private network. If signing skips the transparency log and verification
  demands one, every check fails. This is the most common way keyed cosign
  breaks in private networks.

Check by hand before installing anything — this is what the policy does:

```sh
cosign verify --key kubernetes/cosign.pub --insecure-ignore-tlog \
  docker.io/jahadulrakib/notes-app:<sha>
```

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
