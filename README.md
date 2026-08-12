# notes-app

A single-page notes app (Flask). Notes live in memory and reset on restart.

## Run locally

```bash
pip install -r requirements.txt
python app.py          # http://localhost:8080
```

## Docker

```bash
docker build -t notes-app:latest .
docker run -p 8080:8080 notes-app:latest
```

## Helm

```bash
helm lint helm/notes-app
helm upgrade --install notes helm/notes-app \
  --set image.repository=notes-app --set image.tag=latest
```

Enable the ingress with `--set ingress.enabled=true --set ingress.host=notes.local`.

## Jenkins

`Jenkinsfile` builds the image, lints the chart, pushes to a registry, and runs
`helm upgrade --install`. It expects two Jenkins credentials:

- `dockerhub` — username/password for the registry
- `kubeconfig` — secret file with the cluster kubeconfig

Set `REGISTRY` in the `environment` block to your own org.

## Routes

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | GET | The page |
| `/add` | POST | Add a note |
| `/delete/<idx>` | POST | Delete a note |
| `/healthz` | GET | Liveness/readiness probe |
