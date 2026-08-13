# Credentials

**None of these go in `argocd/application.yaml`.** An Argo CD `Application` is a
pointer to a git path — it holds no secrets and has no field for them. Each
credential below lives somewhere else because a different component consumes it.

| Credential | Who uses it | Where it lives | Needed? |
|---|---|---|---|
| Git (repo read) | Argo CD, to clone the chart | Secret in `argocd` ns | **Yes** — repo is private |
| Git (repo write) | Jenkins, for the tag write-back | Jenkins credential `github-token` | **Yes** — already set up |
| Docker registry (push) | Jenkins, to push the image | Jenkins credential `dockerhub` | **Yes** — already set up |
| Docker registry (pull) | kubelet, to pull the image | Secret in `default` ns | Only if the image is private |
| Cosign private key | Jenkins, to sign | Jenkins credentials | Optional |
| Cosign public key | Admission controller, to verify | Separate controller | Optional |

---

## 1. Git credential for Argo CD — required

Without this, the Application shows `ComparisonError` and
`authentication required`, because Argo CD cannot clone a private repo.

This is a **bootstrap** credential: Argo CD needs it to clone the repo that
contains the chart, so a chart template could never deliver it — that would be
circular. Applied by hand, before `application.yaml`:

```sh
./argocd/repo-secret.sh
```

It prompts for the token with echo disabled and fills in everything else — the
`secret-type: repository` label and the key names Argo CD expects. Export
`ARGOCD_REPO_TOKEN` first to run it non-interactively. Re-running rotates the
token in place.

Use a PAT with **read-only** `repo` scope. Argo CD only clones; keep it distinct
from the write-scoped token Jenkins uses so either can be revoked alone.

If you have the argocd CLI and are logged in, this does the equivalent:

```sh
argocd repo add https://github.com/Jahadul-Rakib/test-app.git \
  --username Jahadul-Rakib --password <TOKEN>
```

Two things that silently break the clone: the `secret-type: repository` label
being absent (Argo CD ignores the Secret entirely), and `REPO_URL` not matching
`spec.source.repoURL` in `application.yaml` exactly — trailing `.git`, `https://`
scheme, and all.

Verify:

```sh
kubectl -n argocd get secret notes-app-repo \
  -o jsonpath='{.metadata.labels}'
argocd repo list          # if you have the CLI; STATUS should be Successful
```

---

## 2. Docker pull secret

Applied by hand ahead of the Helm release. The chart only **references** it by
name and never creates it, which keeps the token out of git — Argo CD renders
the chart straight from the repo, so a token in `values.yaml` would be
committed in plaintext.

```sh
./kubernetes/dockerhub-pull-secret.sh
```

It prompts for the token with echo disabled, then hands the username and token
to `kubectl create secret docker-registry`, which builds the whole
`.dockerconfigjson` — including the base64 `auth` field — on its own. Nothing to
encode by hand. Export `DOCKERHUB_TOKEN` first to run it non-interactively.

The generated manifest is piped through `kubectl apply`, so the script both
creates the secret and rotates the token on later runs. (`kubectl create secret`
by itself would fail with `AlreadyExists`.)

The chart's side is just the reference in `helm/notes-app/values.yaml`:

```yaml
imagePullSecrets:
  - name: dockerhub-pull
```

Note the namespace: **`default`**, where the pod runs — *not* `argocd`. It is
consumed by the kubelet on behalf of your pod. Putting it in `argocd` is the
usual cause of `ImagePullBackOff` with `pull access denied`.

`docker.io/jahadulrakib/notes-app` does not exist yet, so its visibility is
undecided. If it ends up **public** the kubelet pulls anonymously and this
Secret is never read — you can skip it entirely.

Verify:

```sh
kubectl -n default get secret dockerhub-pull
kubectl -n default get pod -l app.kubernetes.io/name=notes-app
```

---

## 3. Cosign — optional

Two halves that are easy to conflate: Jenkins **signs** with the private key,
and something in the cluster **verifies** with the public key. Signing alone
proves nothing until something checks the signature.

### Generating the keypair

Install cosign first — it is not on this machine:

```sh
brew install cosign                       # macOS
# Linux:
#   curl -sSLO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
#   sudo install -m 755 cosign-linux-amd64 /usr/local/bin/cosign
```

Generate the pair. You are prompted for a password that encrypts `kubernetes/cosign.key`
— choose it yourself and store it in your password manager; it is needed again
as a Jenkins credential below:

```sh
cosign generate-key-pair
# cosign.key  private, password-encrypted  -> CI (Jenkins signs with it)
# cosign.pub  public                       -> CD (cluster verifies with it)
```

Run this **outside the repo**, or move `kubernetes/cosign.key` out immediately. A leaked
private key lets anyone sign images that your cluster will then trust. The
`.gitignore` blocks `kubernetes/cosign.key` as a backstop, but do not rely on it.

### Signing (Jenkins / CI side)

Add both to Jenkins (Manage Jenkins → Credentials):

| Kind | Content | ID |
|---|---|---|
| Secret file | `kubernetes/cosign.key` | `cosign-key` |
| Secret text | the password you just chose | `cosign-key-password` |

Then set them in the `Jenkinsfile` `environment` block:

```groovy
COSIGN_CREDENTIALS_ID = 'cosign-key'
COSIGN_PASSWORD_CREDENTIALS_ID = 'cosign-key-password'
```

The `Sign Image` stage is gated on **both** being non-empty, so it stays
skipped until you fill in both. Keep `kubernetes/cosign.key` out of git — only
`kubernetes/cosign.pub` is safe to commit.

### Verifying (cluster / CD side)

**Argo CD cannot do this.** It has no image-signature verification of any kind.
Do not go looking for a field in `application.yaml` — there isn't one.

What Argo CD *does* have is `spec.signatureKeys` on an **AppProject**, which
verifies **GPG signatures on git commits** — a completely different thing from
cosign signatures on container images. They are easy to confuse. Commit signing
answers "who wrote this manifest"; image signing answers "who built this
image".

Image verification happens at **admission**, when the pod is created. Argo CD
applies the Rollout, the API server calls an admission webhook, and that
webhook rejects the pod if the image is unsigned. Two implementations:
Sigstore policy-controller, or Kyverno. Kyverno shown here.

```sh
helm repo add kyverno https://kyverno.github.io/kyverno
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
```

The public key is passed **inline in the policy** — it is public, so committing
it is fine. `kubernetes/kyverno-verify-image.yaml` already has this filled in
with the real key:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-notes-app
spec:
  validationFailureAction: Audit     # switch to Enforce once it passes
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
          # Must match how Jenkins signed. The pipeline passes
          # --tlog-upload=false, so there is no transparency-log entry to
          # check; leaving this out makes every verification fail.
          ctlog:
            ignoreTlog: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      <paste the contents of cosign.pub here>
                      -----END PUBLIC KEY-----
```

Start with `validationFailureAction: Audit`. Under `Enforce`, a mismatch means
pods are refused outright and the app stops deploying — verify it passes in
audit mode first, then switch.

Two things this needs in a private network:

- **Registry egress from the cluster.** Signatures are stored in the registry
  next to the image, so Kyverno must reach `docker.io` to fetch them. Same
  prerequisite as the kubelet pulling the image.
- **No Rekor.** The pipeline signs with `--tlog-upload=false` because
  `rekor.sigstore.dev` is unreachable, so the policy must set
  `ignoreTlog: true`. Signing and verifying have to agree on this or every
  check fails.

Before any of that, verify by hand — this is the same check the policy makes:

```sh
cosign verify --key kubernetes/cosign.pub --insecure-ignore-tlog \
  docker.io/jahadulrakib/notes-app:<sha>
```

---

## Summary of what to create

Both cluster Secrets are applied by hand with `kubectl`, never rendered by the
chart, so no token is ever committed.

| Secret | Created by | Namespace |
|---|---|---|
| `notes-app-repo` | `argocd/repo-secret.sh` | `argocd` |
| `dockerhub-pull` | `kubernetes/dockerhub-pull-secret.sh` | `default` |

Both prompt for their token with echo disabled and build the manifest
themselves. On a fresh cluster, in order:

```sh
./argocd/repo-secret.sh                  # required
./kubernetes/dockerhub-pull-secret.sh    # only if the image repo is private
kubectl apply -f argocd/application.yaml
```

From here Argo CD syncs on its own. The chart creates no Secrets — it only
references `dockerhub-pull` by name via `imagePullSecrets`.

Optional, only if you want signing:

- `kubernetes/cosign.key` + its password as Jenkins credentials, and the two
  `COSIGN_*_CREDENTIALS_ID` values filled in (section 3)

Already in place, nothing to do:

- Jenkins `github-token` (write) and `dockerhub` (push)
