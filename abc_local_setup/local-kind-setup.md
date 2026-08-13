# Local setup from scratch (kind)

Builds the whole stack on a local kind cluster — ingress, Argo CD, Argo
Rollouts, Kyverno, **Jenkins**, credentials, and the app. Everything that ships
a Helm chart is installed with Helm. Every step is a command you can paste; no
files to create by hand.

Four web UIs at the end, all on port 80 through the ingress controller:

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
`/etc/hosts`.

Budget ~30 minutes, most of it image pulls. Give Docker at least **8 GB** — three
kind nodes plus Argo CD, Jenkins, Kyverno and ingress-nginx will not fit in the
2 GB default.

---

## 0. Tools

Only four on the host — everything else runs in the cluster:

```sh
brew install kind kubectl helm
```

No `argocd` CLI and no `kubectl-argo-rollouts` plugin: syncing, promoting and
aborting are all done from the UIs. `trivy` and `cosign` are not needed here
either — they run inside the Jenkins pod, baked into its image in step 7.

The one exception is generating a signing keypair, which happens on your
machine. Only if you want image signing, and it must be cosign **v2** — v3
removed `--tlog-upload=false`, which the `Sign Image` stage depends on, and the
pipeline asserts the major version and fails fast:

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
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
  - role: worker
    image: kindest/node:v1.33.1
  - role: worker
    image: kindest/node:v1.33.1
EOF

kind create cluster --config /tmp/kind-notes-app.yaml
kubectl cluster-info --context kind-notes-app
kubectl get nodes
```

Three nodes: the control-plane carries ingress and publishes 80/443 to your
host; two workers so the app's 4 replicas actually spread and the canary steps
mean something.

> **Port 80 in use?** Cluster creation fails. Stop whatever holds it, or change
> both `hostPort: 80` and the URLs below to `8080`.

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
  --set 'controller.nodeSelector.ingress-ready=true' \
  --set 'controller.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'controller.tolerations[0].operator=Equal' \
  --set 'controller.tolerations[0].effect=NoSchedule' \
  --set controller.watchIngressWithoutClass=true \
  --set controller.replicaCount=1 \
  --wait
```

The single quotes are not optional on zsh (the macOS default) — unquoted
`tolerations[0]` is read as a glob and the command dies with `no matches found`.

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
applicationSet:
  replicas: 1
EOF

helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.3.3 \
  -f /tmp/argocd-values.yaml \
  --wait
```

Get the admin password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in at <http://argocd.localtest.me> as `admin` once step 8 publishes the
ingress. Change the password there, then delete
`argocd-initial-admin-secret`.

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
  # Audit = log failures only. Confirm it passes, THEN switch to Enforce --
  # under Enforce an unsigned image means pods are refused outright and the app
  # stops deploying.
  validationFailureAction: Audit
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
        - imageReferences:
            - "docker.io/jahadulrakib/notes-app:*"
          # Must match how Jenkins signs. The pipeline passes
          # --tlog-upload=false because rekor.sigstore.dev is unreachable from a
          # private network, so there is no transparency-log entry to check.
          # Omit this and every verification fails.
          ctlog:
            ignoreTlog: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE9pzDmp26walej+dJG0KmqP82X8EK
                      MbGDNyWjJNZhmYd2RUeNZeOYVHyYYcqCBkhNAu6TElNyVW+fC/RX8ON0hA==
                      -----END PUBLIC KEY-----
EOF

kubectl get clusterpolicy verify-notes-app
```

Kyverno needs egress to `docker.io`: signatures live in the registry beside the
image, so it fetches them to verify.

---

## 7. Jenkins

The stock Jenkins image has none of the tools the pipeline needs, so build one
that does and side-load it into the cluster.

```sh
cat <<'EOF' >/tmp/Dockerfile.jenkins
FROM jenkins/jenkins:lts-jdk21
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        docker.io git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

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

docker build -f /tmp/Dockerfile.jenkins -t jenkins-notes-app:local /tmp
kind load docker-image jenkins-notes-app:local --name notes-app
```

```sh
cat <<'EOF' >/tmp/jenkins-values.yaml
controller:
  image:
    # `kind load docker-image jenkins-notes-app:local` stores it in containerd
    # under its canonical name, docker.io/library/jenkins-notes-app. Spell it
    # out here or the kubelet looks for a different repo and pulls nothing.
    # An empty registry renders a leading slash and fails outright.
    registry: docker.io
    repository: library/jenkins-notes-app
    tag: local
    # Never reach out -- the image only exists on the nodes, side-loaded.
    pullPolicy: IfNotPresent

  # The chart defaults to 0, which leaves `agent any` in the Jenkinsfile
  # queued forever. Run builds on the controller instead of provisioning
  # dynamic agents -- simpler locally, and the tools are in this image.
  numExecutors: 2

  # Root so the container can use the mounted docker socket without fighting
  # group ownership. Local-only shortcut.
  runAsUser: 0
  fsGroup: 0

  jenkinsUrl: http://jenkins.localtest.me
  ingress:
    enabled: true
    ingressClassName: nginx
    hostName: jenkins.localtest.me

  installPlugins:
    - kubernetes:latest
    - workflow-aggregator:latest
    - git:latest
    - configuration-as-code:latest
    - docker-workflow:latest
    - pipeline-utility-steps:latest
    - junit:latest

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

Admin password:

```sh
kubectl -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

Confirm the tools actually made it in:

```sh
kubectl -n jenkins exec deploy/jenkins -c jenkins -- \
  sh -c 'docker version --format "{{.Server.Version}}"; helm version --short; trivy --version | head -1; cosign version | grep GitVersion; git --version'
```

Then in the UI: create a **Pipeline** job pointed at this repo with script path
`Jenkinsfile`. Polling is declared in the file itself, so no trigger config is
needed here. Credentials come next, in step 9.4.

---

## 8. Ingress for the Argo CD UI

Jenkins got its ingress from the chart above. Argo CD needs one manifest. The
Rollouts dashboard deliberately gets none — the extension reaches it in-cluster.

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.localtest.me
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF
```

```sh
for h in argocd jenkins; do
  printf '%-10s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' http://$h.localtest.me)"
done
```

`200` or `302` from each means the UIs are reachable.

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

### 9.3 Cosign keypair — optional, for image signing

Two halves that are easy to conflate: **Jenkins signs** with the private key,
**Kyverno verifies** with the public one. Signing alone enforces nothing.

A keypair already exists in `cosign/` — `cosign.key` and
`cosign.password` — and its public half is written into the step 6 policy
verbatim, so signing works out of the box. Only regenerate if you want your own:

```sh
cd abc_local_setup/cosign
cosign generate-key-pair        # prompts for a password -- keep it
cd -
```

Print the public half of whatever key you have:

```sh
cosign public-key --key abc_local_setup/cosign/cosign.key
```

If you regenerated, **paste that output into the step 6 policy** — over the
existing `-----BEGIN PUBLIC KEY-----` block, at the same indentation — and
re-apply it. The policy carries the key literally, so nothing picks up a new one
on its own and every verification would keep failing against the old key.

Manual check that a signature verifies, without Kyverno in the way:

```sh
cat <<'EOF' >/tmp/cosign.pub
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE9pzDmp26walej+dJG0KmqP82X8EK
MbGDNyWjJNZhmYd2RUeNZeOYVHyYYcqCBkhNAu6TElNyVW+fC/RX8ON0hA==
-----END PUBLIC KEY-----
EOF

cosign verify --key /tmp/cosign.pub --insecure-ignore-tlog \
  docker.io/jahadulrakib/notes-app:<sha>
```

> **These keys are committed to the repo, on purpose.** `cosign.key` and
> `cosign.password` are tracked in git — not ignored — so this demo is
> reproducible from a clone with nothing to set up out of band.
>
> That is fine for a throwaway demo key and wrong everywhere else: anyone with
> read access to the repo can sign images this cluster will trust. For anything
> real, generate a fresh pair, keep the private half in the Jenkins credential
> store only, and add both filenames to `.gitignore`.

### 9.4 Jenkins credentials

At <http://jenkins.localtest.me> → **Manage Jenkins → Credentials → System →
Global**. The IDs must match exactly — the `Jenkinsfile` looks them up by ID:

| ID | Kind | Username | Password / content |
|---|---|---|---|
| `github-token` | Username with password | `Jahadul-Rakib` | `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` |
| `dockerhub` | Username with password | `jahadulrakib` | `dckr_pat_getuazgIuPPCJFgRfkJQ5_mjRQQ` |
| `cosign-key` | Secret file | — | upload `abc_local_setup/cosign/cosign.key` |
| `cosign-key-password` | Secret text | — | contents of `abc_local_setup/cosign/cosign.password` |

`github-token` needs **write** `repo` scope — the `Update GitOps` stage commits
the image tag back.

The two cosign entries are optional. The `Sign Image` stage is gated on both
`COSIGN_CREDENTIALS_ID` and `COSIGN_PASSWORD_CREDENTIALS_ID` being non-empty in
the `Jenkinsfile` `environment` block, so it stays skipped until you set them:

```groovy
COSIGN_CREDENTIALS_ID = 'cosign-key'
COSIGN_PASSWORD_CREDENTIALS_ID = 'cosign-key-password'
```

---

## 10. Deploy the app

```sh
kubectl apply -f argocd/application.yaml
kubectl -n argocd get application notes-app -w
```

> **The image does not exist yet.** `docker.io/jahadulrakib/notes-app` is created
> by the first Jenkins run, so until then pods sit in `ErrImagePull`. To try the
> stack without Jenkins, build and side-load — `imagePullPolicy: IfNotPresent`
> means the kubelet uses the loaded copy and never reaches out:
>
> ```sh
> docker build -t docker.io/jahadulrakib/notes-app:latest .
> kind load docker-image docker.io/jahadulrakib/notes-app:latest --name notes-app
> kubectl -n default delete pod -l app.kubernetes.io/name=notes-app
> ```
>
> Deleting the pods is the plugin-free way to pick up the side-loaded image —
> they are recreated immediately and `IfNotPresent` finds it locally. The
> Rollouts UI has a **Restart** button that does the same thing.

Publish the app on the ingress too:

```sh
helm template notes-app helm/notes-app \
  --set ingress.enabled=true --set ingress.host=notes.localtest.me | kubectl apply -f -
```

For a durable version, set `ingress.enabled: true` and
`ingress.host: notes.localtest.me` in `helm/notes-app/values.yaml` and let Argo
CD sync it.

---

## 11. Watch a canary

All of it happens in the Argo CD UI. Open <http://argocd.localtest.me>, the
`notes-app` Application, then the **Rollout** resource. The extension from
step 5 renders each step, the current weight, and both ReplicaSets side by side,
with the controls you need:

| Button | Does |
|---|---|
| **Promote** | Skip the current pause and move to the next step |
| **Promote-Full** | Skip every remaining step, go straight to 100% |
| **Abort** | Send all traffic back to stable |
| **Restart** | Recreate pods on the current revision |

If those controls are missing and the Rollout renders as a plain resource, the
extension did not install — see the troubleshooting note at the end.

A canary holds at 25%, 50% and 75% for 60s each. With traffic routing off (the
default) those weights are approximated by **replica count** — at 4 replicas
they land on 1, 2 and 3 pods.

Plain kubectl works for watching, since Rollout is just a CRD:

```sh
kubectl -n default get rollout notes-app-notes-app -w
kubectl -n default describe rollout notes-app-notes-app | tail -30
```

For real percentage-based splitting instead of pod-count approximation, set
`rollout.trafficRouting.enabled=true` **and** `ingress.enabled=true`. Rollouts
then steers by rewriting the stable Ingress and renders a `-canary` Service.

> A paused canary shows the Application as **Progressing**, not Degraded. That
> is Argo CD's Rollout health check working, not a stuck sync.

---

## 12. Verify

```sh
kubectl get nodes
for ns in ingress-nginx argo-rollouts argocd kyverno jenkins default; do
  echo "== $ns"; kubectl -n $ns get pods --no-headers 2>/dev/null | awk '{print "   "$1, $3}'
done
kubectl -n argocd get application notes-app
kubectl -n default get rollout,svc,pods
```

Then eyeball the four UIs:

```sh
for h in argocd rollouts jenkins notes; do
  printf '%-10s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' http://$h.localtest.me)"
done
```

---

## 13. Teardown

```sh
kind delete cluster --name notes-app
docker rmi jenkins-notes-app:local
rm -f /tmp/kind-notes-app.yaml /tmp/argocd-values.yaml /tmp/jenkins-values.yaml /tmp/Dockerfile.jenkins
```

Everything lives in the cluster, so deleting it removes the lot.

---

## Troubleshooting

**`no matches for kind "Rollout"`** — Argo Rollouts missing or installed after
the Application. Do step 4, then hit **Sync** on the app in the Argo CD UI.

**ingress-nginx `Pending`** — it only schedules on the node labelled
`ingress-ready=true`. `kubectl get nodes --show-labels`; if absent, the cluster
was created without the step 1 config.

**Jenkins build fails `docker: not found` or cannot reach the daemon** — the
socket passthrough is broken. Check the extraMount in step 1 exists, and that
the pod sees it: `kubectl -n jenkins exec deploy/jenkins -c jenkins -- ls -l /var/run/docker.sock`.

**Jenkins job queues forever** — `controller.numExecutors` is 0. The chart
defaults to 0 and `agent any` has nowhere to run.

**`ImagePullBackOff`** — either the Docker Hub repo does not exist yet (step 10)
or it is private and `dockerhub-pull` is missing from the `default` namespace.
It must live where the **pod** runs, not in `argocd`.

**`ComparisonError` / `authentication required`** — repo credential missing,
mislabelled, or its URL does not match `repoURL`. Argo CD only reads secrets
carrying `argocd.argoproj.io/secret-type: repository`.

**Canary stalls, traffic snaps back to stable** — Argo CD reverted the Service
selector Rollouts rewrote. `argocd/application.yaml` carries `ignoreDifferences`
on `/spec/selector` plus `RespectIgnoreDifferences=true` to prevent exactly
this; confirm both are present.

**Docker Hub rate limits** — nodes pull independently of your host login.
Side-load with `kind load docker-image` if you hit them.

**Rollout shows as a plain resource, no Promote/Abort buttons** — the extension
needs both halves. Check the initContainer ran and the proxy config landed:

```sh
kubectl -n argocd get deploy argocd-server \
  -o jsonpath='{.spec.template.spec.initContainers[*].name}'; echo
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.extension\.config}'; echo
kubectl -n argo-rollouts get svc argo-rollouts-dashboard
```

A missing `rollout-extension` initContainer usually means a second top-level
`server:` key in the values file silently overrode the first.

**Pods `Pending` on memory** — raise Docker's memory limit to 8 GB.
