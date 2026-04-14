# Container Migration Workshop
## Dockerfiles → docker-compose → Kubernetes

> **The app:** *ShipIt Todos* — a three-tier web app with a **Postgres** database,
> a **Python/Flask REST API**, and an **Nginx** frontend.  Small enough to understand
> completely, realistic enough that every pattern transfers to production.

```
┌──────────────┐    HTTP     ┌──────────────┐    SQL     ┌──────────────┐
│   Frontend   │ ──────────► │     API      │ ─────────► │  Database    │
│  Nginx :80   │             │  Flask :5000 │            │  Postgres    │
└──────────────┘             └──────────────┘            │  :5432       │
                                                          └──────────────┘
```

---

## How to use this workshop

Each stage is self-contained.  Work through them in order or jump to any stage.
Every file has inline comments that explain *why*, not just *what*.

| Stage | What you learn | Directory |
|-------|---------------|-----------|
| 0 | Write good Dockerfiles (multi-stage, non-root, layer caching) | `stage-0-dockerfiles/` |
| 1 | Run containers manually — understand what compose automates | `stage-1-docker-run/` |
| 2 | Condense into docker-compose | `stage-2-compose/` |
| 3 | Translate compose to basic Kubernetes manifests | `stage-3-k8s-basic/` |
| 4 | Harden for production (Ingress, HPA, StatefulSet) | `stage-4-k8s-production/` |

---


**Goal:** understand the baseline images before we orchestrate them.

### 0.1  Inspect the API Dockerfile

Open [stage-0-dockerfiles/api/Dockerfile](stage-0-dockerfiles/api/Dockerfile).

```
# Multi-stage build
FROM python:3.12-slim AS builder   ← installs deps
    …
FROM python:3.12-slim              ← copies only the installed packages
```

**Why multi-stage?**  The builder stage needs build tools (gcc, pip).
The final stage needs none of that — the image is 3× smaller and has a
much smaller attack surface.

**Checkpoint:** Build the image and inspect its layers.

```bash
docker build -t shipit-api:latest ./stage-0-dockerfiles/api
docker images shipit-api           # notice the size
docker history shipit-api          # see each layer
```

**What to look for:**
- Two `FROM` lines = two stages.
- `COPY --from=builder` transfers artifacts without carrying the builder's filesystem.
- `USER appuser` — the process runs as non-root inside the container.

---

### 0.2  Inspect the Frontend Dockerfile

Open [stage-0-dockerfiles/frontend/Dockerfile](stage-0-dockerfiles/frontend/Dockerfile).

```bash
docker build -t shipit-frontend:latest ./stage-0-dockerfiles/frontend
```

Note the `nginx.conf` uses `${BACKEND_HOST}` — a **template variable**.
The nginx official image automatically runs `envsubst` on `*.template` files
at startup, substituting environment variables.  This is how we avoid
hard-coding the backend address into the image.

```bash
# See the substitution in action.
# We run the entrypoint (which runs envsubst) and then read the rendered output.
# Passing a custom CMD replaces nginx, so we need --entrypoint to keep the
# envsubst step and just add the cat after it.
docker run --rm -e BACKEND_HOST=my-api-service \
  --entrypoint /bin/sh shipit-frontend \
  -c "/docker-entrypoint.d/20-envsubst-on-templates.sh && cat /etc/nginx/conf.d/default.conf"
```

---

## Stage 1 — Running Containers by Hand

**Goal:** do manually what compose will later automate — feel the pain.

### 1.1  The networking problem

Containers are isolated by default.  They cannot reach each other unless
they share a **Docker network**.

```bash
# Without a shared network, containers cannot resolve each other by name
docker run --rm --name box-a alpine ping box-b   # fails — box-b is not on the same network
# ping: bad address 'box-b'
# --rm ensures the exited container is removed automatically, freeing the name
# (Docker names must be at least 2 characters: [a-zA-Z0-9][a-zA-Z0-9_.-])

# With a shared custom network, Docker's embedded DNS resolves container names
docker network create demo-net
docker run -d --network demo-net --name box-a alpine sleep 3600
docker run --rm  --network demo-net alpine ping -c3 box-a   # works
docker rm -f box-a && docker network rm demo-net 
# Sequence is important. Cannot remove a network with active endpoints(containers in use).
```

### 1.2  Run ShipIt manually

```bash
cd stage-1-docker-run
./run.sh
```

Look at [stage-1-docker-run/run.sh](stage-1-docker-run/run.sh) while it executes.
Count the number of flags needed just for the database:

```
docker run -d
  --name shipit-db
  --network shipit-net         ← manual network wiring
  --volume shipit-pgdata:…     ← manual volume attachment
  --env POSTGRES_DB=todos      ← repeated env vars
  --env POSTGRES_USER=postgres
  --env POSTGRES_PASSWORD=…
  --restart unless-stopped     ← manual restart policy
  postgres:16-alpine
```

That is *one* of three services.  And there is **no dependency ordering** —
if you start the API before postgres is ready, it crashes.

**Checkpoint — things to notice:**

```bash
# Services communicate using container names as hostnames.
# The API image (python:3.12-slim) has no curl/wget, so use a Python one-liner
# to open a raw TCP socket to the postgres port:
docker exec shipit-api python -c \
  "import socket; s=socket.create_connection(('shipit-db',5432),timeout=3); print('connected to shipit-db:5432'); s.close()"

# You can see the network
docker network inspect shipit-net

# Logs
docker logs -f shipit-api
```

Open http://localhost:8080 — the app is running.

```bash
# When done:
./teardown.sh
```

**If Add Todo still fails:**
- Make sure you rebuilt both images after the latest workshop edits.
- The frontend now uses `/api` by default, so browser requests stay on the Nginx proxy path.
- If the API returns `relation "todos" does not exist`, rebuild the API image so the schema init runs on startup.

**Pain points of raw `docker run`:**
| Problem | Manifestation |
|---------|--------------|
| No dependency ordering | API crashes if DB isn't ready |
| Startup order is a script, not a declaration | Easy to get wrong |
| Env vars repeated or hardcoded in the script | Error-prone, no single source of truth |
| No health-aware restarts | Dead container stays dead until you notice |
| Scaling = copy-paste the `docker run` line | Not scalable |

---

## Stage 2 — docker-compose

**Goal:** replace the shell script with a declarative, reproducible definition.

### 2.1  The compose file

Open [stage-2-compose/docker-compose.yaml](stage-2-compose/docker-compose.yaml).

Every `docker run` flag maps to a compose key:

| `docker run` flag | compose equivalent |
|-------------------|--------------------|
| `--name` | service name (also the DNS hostname) |
| `--network` | automatic per-project network |
| `--volume name:path` | `volumes:` + top-level `volumes:` |
| `--env KEY=VAL` | `environment:` |
| `--restart unless-stopped` | `restart: unless-stopped` |
| `--publish host:container` | `ports:` |
| *(none)* | `healthcheck:` |
| *(none)* | `depends_on: condition: service_healthy` |

The biggest win: **dependency ordering with health checks**.

```yaml
api:
  depends_on:
    db:
      condition: service_healthy   # waits until pg_isready passes
```

### 2.2  Sensitive values — .env files

```bash
cp stage-2-compose/.env.example stage-2-compose/.env
# edit .env to set DB_PASSWORD
```

Compose automatically loads `.env` and substitutes `${DB_PASSWORD}` in the YAML.
This means **secrets never live in the committed file**.

### 2.3  Run it

```bash
cd stage-2-compose
docker compose up --build
```

Watch the startup order in the logs — `db` starts first, becomes healthy,
then `api` starts, then `frontend`.

**Checkpoint commands:**

```bash
docker compose ps                           # service status + health
docker compose logs -f api                  # follow api logs
docker compose exec db psql -U postgres todos -c "SELECT * FROM todos;"
docker compose restart api                  # rolling restart of one service

# Scale api to 3 replicas (stateless services only!)
docker compose up --scale api=3 -d
docker compose ps
```

**How scaling works:** The API publishes no host port (removed from compose YAML) so multiple replicas can coexist.
The frontend reaches the API via Docker DNS (internal hostname `api`), and external clients hit the frontend proxy at `http://localhost:8080/api`.
Try adding a few todos—requests are load-balanced across the 3 API containers.

**Troubleshooting Stage 2:**

If the API container fails to become healthy with error `dependency failed to start: container shipit-api-1 is unhealthy`:

- **Root cause:** The `compose.yaml` health check uses `wget` to probe the API, but the `python:3.12-slim` base image does not include `wget` or `curl`.
- **Solution:** The compose file has been updated to use a Python socket connection instead:
  ```yaml
  healthcheck:
    test: ["CMD", "python", "-c", "import socket; s=socket.create_connection(('localhost',5000),timeout=3); s.close()"]
  ```
  This is guaranteed to work since Python is always available in the image.
- **What was tested:** After this fix, `docker compose up --build` succeeds, and the API responds to `POST /api/todos` and `GET /api/todos` requests.

**What compose does NOT solve:**
- Runs on **one host** only — no multi-node distribution
- No automatic **rescheduling** if the host dies
- No **rolling updates** with zero downtime
- No CPU/memory enforcement
- No built-in **service discovery** across hosts
- Not designed for production workloads with SLAs

```bash
docker compose down   # clean up before moving on
```

---

## Stage 3 — Kubernetes (Basic)

**Goal:** translate every compose concept to its Kubernetes equivalent.

### The mental model shift

```
docker-compose concept          Kubernetes equivalent
─────────────────────────────────────────────────────
service (name + image + config) Deployment + ConfigMap + Secret
"DNS by service name"           Service (ClusterIP)
--publish host:container        Service (NodePort or LoadBalancer)
volumes:                        PersistentVolumeClaim
depends_on: condition: healthy  initContainer + readinessProbe
restart: unless-stopped         built-in (pods always restart)
healthcheck:                    readinessProbe + livenessProbe
.env file                       Secret + ConfigMap
--scale api=3                   spec.replicas: 3
```

### 3.1  Pre-flight

You need a local Kubernetes cluster.  Choose one:

```bash
# Option A — kind (Kubernetes in Docker, recommended)
brew install kind

# For Ubuntu/Linux
# For AMD64 / x86_64
[ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
# For ARM64
[ $(uname -m) = aarch64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-arm64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Standard local cluster
kind create cluster --name shipit

# Optional: recreate with external NodePort mapping (host TCP 30800)
# kind delete cluster --name shipit
# kind create cluster --config stage-3-k8s-basic/kind-nodeport.yaml

# Option B — minikube
brew install minikube
minikube start

# Option C — k3s on EC2/Ubuntu (Linux-friendly alternative)
curl -sfL https://get.k3s.io | sh -
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Verify
kubectl cluster-info
kubectl get nodes

# EC2 note: if you want external access, open Security Group inbound rules
# for the ports you expose (for example 80, 443, or 30800).
```

#### About KinD
The Kind control plane (API server) runs on a randomized high port like 44663 on your host machine to avoid conflicts with existing services when mapping Docker container ports. Internally, the container still uses port 6443, but Kind maps this to a unique port on your host for access. 
Port Mapping: Kind uses kubeadm to create clusters. When creating the control plane node, it assigns a random or specific port on your host, mapping it to the container's 6443 API port.
Conflict Avoidance: Using a randomized port prevents issues if you already have a service (or another Kubernetes cluster) running on 6443 on your local machine.
Verification: You can find the specific mapped port by running docker ps to see the control plane container configuration. 

If you require a specific port, you can define it in the extraPortMappings section of the Kind YAML configuration file.

For this workshop, use stage-3-k8s-basic/kind-nodeport.yaml to map host port 30800 to the KinD node. Then open TCP 30800 in your VM/EC2 Security Group if you want external access via your public IP.
####

Build the application images (skip if you already tagged them with `:latest` in Stage 0):

# From ~/container-migration-workshop
```bash
docker build -t shipit-api:latest     ./stage-0-dockerfiles/api
docker build -t shipit-frontend:latest ./stage-0-dockerfiles/frontend
```

> **Why `:latest`?**  The K8s manifests reference `shipit-api:latest` and
> `shipit-frontend:latest`.  If you built without an explicit tag in Stage 0 the
> images default to `:latest` anyway, but being explicit avoids surprises.

Load the images into the local cluster (Kubernetes does not share Docker's image cache):

```bash
# kind
kind load docker-image shipit-api:latest     --name shipit
kind load docker-image shipit-frontend:latest --name shipit

# minikube
minikube image load shipit-api:latest
minikube image load shipit-frontend:latest

# k3s (alternative image import path)
docker save shipit-api:latest | sudo k3s ctr images import -
docker save shipit-frontend:latest | sudo k3s ctr images import -
```

### 3.2  Apply all manifests

```bash
# Apply in dependency order (or use --recursive)
kubectl apply -f stage-3-k8s-basic/manifests/namespace.yaml
kubectl apply -f stage-3-k8s-basic/manifests/db/
kubectl apply -f stage-3-k8s-basic/manifests/api/
kubectl apply -f stage-3-k8s-basic/manifests/frontend/
```

Watch everything come up:

```bash
kubectl get pods -n shipit --watch
# Press Ctrl+C to stop watching (non-zero exit on interrupt is expected).
```

### 3.3  Deep-dive: the compose → k8s translation

#### Service DNS

In compose, service `api` is reachable as `http://api:5000`.
In Kubernetes it is `http://api.shipit.svc.cluster.local:5000`, or just `http://api:5000`
when called from **within the same namespace**.

#### Secrets

Open [stage-3-k8s-basic/manifests/db/secret.yaml](stage-3-k8s-basic/manifests/db/secret.yaml).

```yaml
data:
  password: c3VwZXJzZWNyZXQ=    # base64 — NOT encryption!
```

```bash
# Decode a secret value:
kubectl get secret db-credentials -n shipit -o jsonpath='{.data.password}' | base64 -d
echo
```

Secrets are injected into pods in two ways:

```yaml
# 1. As individual env vars (used in api Deployment)
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: password

# 2. As a volume (useful for TLS certs, SSH keys)
volumes:
  - name: tls
    secret:
      secretName: my-tls-cert
```

#### readinessProbe vs livenessProbe

Open [stage-3-k8s-basic/manifests/api/deployment.yaml](stage-3-k8s-basic/manifests/api/deployment.yaml).

| Probe | Failing means… | Kubernetes action |
|-------|----------------|-------------------|
| `readinessProbe` | "not ready to serve traffic yet" | Remove pod from Service endpoints |
| `livenessProbe` | "broken, needs restart" | Kill and restart the pod |

Use `readinessProbe` to handle slow startup.
Use `livenessProbe` to recover from deadlocks.

#### initContainers replace depends_on

```yaml
initContainers:
  - name: wait-for-db
    image: postgres:16-alpine
    command: ["sh", "-c", "until pg_isready -h db; do sleep 2; done"]
```

The main container does not start until *all* initContainers exit with code 0.

### 3.4  Checkpoint commands

```bash
# Status
kubectl get pods -n shipit
kubectl get svc  -n shipit
kubectl describe pod -n shipit -l app=api   # detailed events + conditions

# Logs
kubectl logs -n shipit -l app=api --tail=50 -f
kubectl logs -n shipit -l app=api --all-containers --prefix

# Connect to the DB from your laptop
kubectl port-forward -n shipit svc/db 5432:5432 &
psql -h localhost -U postgres -d todos
# Check database for todos
SELECT id, title, done FROM todos ORDER BY id;
# If psql is missing on Ubuntu/Debian, install the actual client binary:
sudo apt install postgresql-client

# In one command
PGPASSWORD=supersecret psql -h localhost -U postgres -d todos -c "SELECT id, title, done FROM todos ORDER BY id;"

# Hit the API directly
kubectl port-forward -n shipit svc/api 5000:5000 &
curl http://localhost:5000/todos

# CRUD workflow from CLI (curl)
# Create
curl -s -X POST http://localhost:5000/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"Write Kubernetes docs"}'

# Read (list)
curl -s http://localhost:5000/todos

# Update (replace <TODO_ID> with an id from the list)
curl -s -X PATCH http://localhost:5000/todos/<TODO_ID> \
  -H "Content-Type: application/json" \
  -d '{"done":true}'

# Delete
curl -i -X DELETE http://localhost:5000/todos/<TODO_ID>

# Optional: verify the API health endpoint
curl -s http://localhost:5000/health

# Stop the background port-forward when done
pkill -f "kubectl port-forward -n shipit svc/api 5000:5000"

# Access the frontend
# kind: use the NodePort
kubectl get svc frontend -n shipit             # note the NodePort (e.g. 30800)
# minikube:
minikube service frontend -n shipit --url

# Scale up/down (instant, unlike docker-compose which needed --scale flag)
kubectl scale deployment api -n shipit --replicas=4
kubectl get pods -n shipit -l app=api --watch

# Rolling update (change the image tag)
kubectl set image deployment/api api=shipit-api:v2 -n shipit
kubectl rollout status deployment/api -n shipit
kubectl rollout undo deployment/api -n shipit   # rollback if needed
```

### 3.4.1  CRUD API calls with Postman

Use `http://localhost:5000` as the base URL (keep `kubectl port-forward -n shipit svc/api 5000:5000` running).

Quick start import: `stage-3-k8s-basic/postman/ShipIt-CRUD.postman_collection.json`

1. Create a Postman Collection named `ShipIt API`.
2. Add request `Create Todo`:
  - Method: `POST`
  - URL: `http://localhost:5000/todos`
  - Body -> raw -> JSON:
    ```json
    {"title":"Ship v1.0"}
    ```
3. Add request `List Todos`:
  - Method: `GET`
  - URL: `http://localhost:5000/todos`
4. Add request `Update Todo`:
  - Method: `PATCH`
  - URL: `http://localhost:5000/todos/{{todoId}}`
  - Body -> raw -> JSON:
    ```json
    {"done": true}
    ```
5. Add request `Delete Todo`:
  - Method: `DELETE`
  - URL: `http://localhost:5000/todos/{{todoId}}`
6. Run `Create Todo` and copy the returned `id` into a collection variable named `todoId`.
7. Run `List Todos`, `Update Todo`, and `Delete Todo` to complete the CRUD cycle.

## Fix for failed rollouts
# On KinD, local Docker images are not automatically visible to the cluster; kind load docker-image is required.
Use this flow:

Build the new tag
docker build -t shipit-api:v2 ./stage-0-dockerfiles/api

If using KinD, load it into the cluster
kind load docker-image shipit-api:v2 --name shipit

Update deployment
kubectl set image deployment/api api=shipit-api:v2 -n shipit
kubectl rollout status deployment/api -n shipit

If needed, rollback
kubectl rollout undo deployment/api -n shipit
#

### 3.5  Explore the internal network

```bash
# Shell into a pod and test service discovery
kubectl exec -it -n shipit deploy/api -- sh

# Inside the pod:
python -c "import socket; s=socket.create_connection(('db',5432),timeout=3); print('db:5432 reachable'); s.close()"
python -c "import urllib.request; print(urllib.request.urlopen('http://api:5000/health', timeout=3).read().decode())"
env | grep DB_                 # see injected env vars
cat /etc/resolv.conf           # kube-dns config
```

---

## Stage 4 — Kubernetes (Production)

**Goal:** make it real — Ingress, autoscaling, StatefulSet, proper secrets.

### 4.1  Replace NodePort with Ingress

NodePort is fine for development but exposes random high ports and doesn't
support TLS or host-based routing.

An **Ingress** is an HTTP(S) reverse proxy managed by an Ingress Controller.
It lets you route `example.com/api` to one service and `example.com/` to another.

```
Internet → LoadBalancer Service → Ingress Controller → Ingress rules → ClusterIP Services
```

Install the nginx Ingress Controller:

```bash
# kind
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s

# minikube
minikube addons enable ingress

# k3s (ingress controller is Traefik by default)
# After applying the Ingress manifest below, switch its class to traefik:
# kubectl patch ingress shipit -n shipit --type merge -p '{"spec":{"ingressClassName":"traefik"}}'
```

Apply the production manifests:

```bash
# Replace the basic Services with ClusterIP versions
kubectl apply -f stage-4-k8s-production/manifests/frontend/service.yaml
kubectl apply -f stage-4-k8s-production/manifests/api/service.yaml

# Apply the Ingress
kubectl apply -f stage-4-k8s-production/manifests/ingress.yaml

# k3s only (Traefik default ingress class)
kubectl patch ingress shipit -n shipit --type merge -p '{"spec":{"ingressClassName":"traefik"}}'

# Add to /etc/hosts for local DNS resolution
echo "127.0.0.1 shipit.local" | sudo tee -a /etc/hosts
```

```bash
# kind: forward ingress to an unprivileged local port (works without sudo)
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80 &
# Then open: http://shipit.local:8080

# Optional: bind local port 80 (requires root)
# sudo kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 80:80

# minikube:
minikube tunnel &

# k3s on EC2:
# Traefik typically exposes host ports 80/443 via the default ServiceLB.
# Open TCP 80 in your EC2 Security Group, then test with Host header:
# curl -H 'Host: shipit.local' http://<EC2_PUBLIC_IP>
```

#### EC2 / remote VM access (browser on your laptop)

If your Kubernetes commands run on a remote VM (for example EC2) but your browser runs on your laptop, add the host entry and open the URL on your **laptop**, not the VM.

```bash
# 1) On the VM: keep port-forward running
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80
```

```bash
# 2) On your laptop: create an SSH tunnel to the VM
ssh -L 8080:127.0.0.1:8080 ubuntu@<EC2_PUBLIC_IP>
```

```bash
# 3) On your laptop: map shipit.local to localhost
echo "127.0.0.1 shipit.local" | sudo tee -a /etc/hosts
```

Then open `http://shipit.local:8080` in your laptop browser.

Quick verification:

```bash
# On the VM (proves ingress route works)
curl -H 'Host: shipit.local' http://127.0.0.1:8080

# On the laptop (proves DNS + tunnel)
curl http://shipit.local:8080
```

Open http://shipit.local:8080 (or http://shipit.local if you used sudo on port 80) — traffic now flows through the Ingress.

#### Ingress simulation: watch one request cross all layers

Run these in separate terminals to observe the request path in real time.

```bash
# Terminal A: ingress controller logs (edge router)
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller -f --tail=20
```

```bash
# Terminal B: frontend logs (Nginx app container)
kubectl logs -n shipit -l app=frontend -f --tail=20
```

```bash
# Terminal C: api logs (Flask backend)
kubectl logs -n shipit -l app=api -f --tail=20
```

```bash
# Terminal D: send traffic through ingress host routing
curl -i http://shipit.local:8080/
curl -i http://shipit.local:8080/api/health
curl -s -X POST http://shipit.local:8080/api/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"ingress test"}'
curl -s http://shipit.local:8080/api/todos
```

What this proves:
- Ingress Controller accepts traffic for `Host: shipit.local`.
- Ingress forwards `/` to the `frontend` Service.
- Frontend Nginx proxies `/api/*` to the `api` Service.
- API handles CRUD calls while the browser only talks to one public entrypoint.

### 4.2  Horizontal Pod Autoscaler

Open [stage-4-k8s-production/manifests/api/hpa.yaml](stage-4-k8s-production/manifests/api/hpa.yaml).

```yaml
spec:
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70   # scale up when avg CPU > 70%
```

```bash
kubectl apply -f stage-4-k8s-production/manifests/api/hpa.yaml
kubectl apply -f stage-4-k8s-production/manifests/frontend/hpa.yaml

# Watch autoscaling decisions
kubectl get hpa -n shipit --watch
```

#### HPA simulation: force scale-up, then watch scale-down

HPA needs metrics. If `TARGETS` shows `<unknown>`, install metrics-server first:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl wait -n kube-system --for=condition=available deploy/metrics-server --timeout=120s
```

Open three terminals:

```bash
# Terminal A: watch HPA decisions
kubectl get hpa -n shipit --watch
```

```bash
# Terminal B: watch replica count change
kubectl get deploy -n shipit api frontend -w
```

```bash
# Terminal C: generate concurrent traffic through ingress for ~2 minutes
seq 1 10000 | xargs -I{} -P 80 curl -s -o /dev/null http://shipit.local:8080/api/todos
```

Optional deeper visibility:

```bash
kubectl top pods -n shipit
kubectl describe hpa api -n shipit
kubectl describe hpa frontend -n shipit
```

Expected behavior:
- CPU rises above target (`api` target 70%, `frontend` target 60%).
- HPA increases replicas within min/max bounds.
- After load stops, utilization drops and HPA scales back down gradually.

This demonstrates HPA's purpose: match capacity to demand automatically, instead of manually scaling deployments.

### 4.3  Database: Deployment → StatefulSet

Open [stage-4-k8s-production/manifests/db/statefulset.yaml](stage-4-k8s-production/manifests/db/statefulset.yaml).

Key differences from a Deployment:

```yaml
kind: StatefulSet
spec:
  serviceName: db            # ties pods to the headless Service
  volumeClaimTemplates:      # each replica gets its own PVC (vs shared)
    - metadata:
        name: pgdata
      spec:
        resources:
          requests:
            storage: 10Gi
```

Pod names are now **deterministic**: `db-0`, `db-1` — not random hashes.
This matters for primary/replica setups where `db-0` is always the primary.

```bash
kubectl delete deployment db -n shipit          # remove the Deployment version
kubectl apply -f stage-4-k8s-production/manifests/db/
kubectl get pods -n shipit -l app=db --watch    # watch db-0 come up
```

### 4.4  Secret management in production

The base64 Secret in the YAML file is **not secure** for production.
Options from least to most mature:

| Approach | Pros | Cons |
|----------|------|------|
| Sealed Secrets (Bitnami) | Simple, GitOps-friendly | Cluster-specific keys |
| External Secrets Operator | Syncs from Vault/AWS SSM/GCP SM | Needs external secret store |
| CSI Secrets Store Driver | Mounts secrets as files, no etcd exposure | More complex setup |
| Vault Agent Injector | Full Vault power | Heavy operational overhead |

Quick Sealed Secrets example:
```bash
# Ubuntu / Debian (x86_64)
sudo apt update
sudo apt install -y curl jq tar

KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r '.tag_name' | sed 's/^v//')
curl -LO "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
kubeseal --version
# Seal a secret (safe to commit)
kubectl create secret generic db-credentials \
  --from-literal=username=postgres \
  --from-literal=password=supersecret \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > sealed-db-credentials.yaml
```

Proof it works (end-to-end in your cluster):
```bash
# 1) Install controller (safe to run again; it will be configured/applied)
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.6/controller.yaml
kubectl wait -n kube-system --for=condition=available deploy/sealed-secrets-controller --timeout=120s

# 2) Ensure kubeseal uses the same active cluster context
KCFG=$(mktemp)
kubectl config view --raw > "$KCFG"
export KUBECONFIG="$KCFG"

# 3) Seal -> apply -> read back the unsealed Secret value
kubectl -n shipit create secret generic kubeseal-proof \
  --from-literal=token=proof-from-kubeseal \
  --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml \
  | kubectl apply -f -

kubectl -n shipit get secret kubeseal-proof -o jsonpath='{.data.token}' | base64 -d; echo
# Expected output: proof-from-kubeseal

# 4) Cleanup proof artifacts
kubectl -n shipit delete sealedsecret kubeseal-proof --ignore-not-found=true
rm -f "$KCFG"
```

Troubleshooting:
- If you see `error: invalid configuration: no configuration has been provided`, `kubeseal` cannot find your kubeconfig.
- Fix: export a kubeconfig file before running `kubeseal`:
  ```bash
  KCFG=$(mktemp)
  kubectl config view --raw > "$KCFG"
  export KUBECONFIG="$KCFG"
  ```
  Then re-run the seal command.

---

## Concept Map: Everything in One View

```
DOCKER RUN               COMPOSE                  KUBERNETES
──────────────           ─────────────────        ─────────────────────────────
docker build             build: context:          (you build and push to registry)
--name foo               services.foo:            Deployment.metadata.name: foo
--network mynet          (automatic)              Service (ClusterIP)
--env K=V                environment: K: V        ConfigMap.data.K + envFrom
--env SECRET=x           ${VAR} in .env           Secret + secretKeyRef
--volume name:/path      volumes: name:/path      PVC + volumeMount
--publish 8080:80        ports: "8080:80"         Service (NodePort/LoadBalancer)
--restart unless-stopped restart: unless-stopped  (default pod policy)
(none)                   healthcheck:             readinessProbe + livenessProbe
(none)                   depends_on: healthy      initContainer
--scale (n/a)            --scale api=3            spec.replicas: 3
(none)                   (none)                   HPA (auto-scale by CPU/memory)
(none)                   (none)                   Ingress (HTTP routing + TLS)
docker volume create     volumes: (top-level)     PersistentVolumeClaim
docker network create    (automatic)              Namespace + NetworkPolicy
```

---

## Clean Up

```bash
# Remove everything
kubectl delete namespace shipit

# Delete local cluster
kind delete cluster --name shipit
# or
minikube delete
```

---

## What's Next?

| Topic | Tool / Concept |
|-------|---------------|
| Package Kubernetes manifests | Helm charts, Kustomize |
| CI/CD pipeline | GitHub Actions → build → push → `kubectl rollout` |
| Observability | Prometheus + Grafana, Loki for logs |
| Service mesh | Istio or Linkerd (mTLS, traffic splitting, tracing) |
| GitOps | ArgoCD or Flux — cluster state = git repo |
| Multi-cluster | Cluster API, crossplane |
