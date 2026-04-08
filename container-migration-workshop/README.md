# Container Migration Workshop

> **Dockerfiles → docker-compose → Kubernetes**  — a hands-on, progressive workshop.

Open [WORKSHOP.md](WORKSHOP.md) to start.

## Quick start

```bash
# Prerequisites: docker, kubectl, kind or minikube

# Stage 1 — manual docker run
cd stage-1-docker-run && ./run.sh

# Stage 2 — docker compose
cd stage-2-compose && docker compose up --build

# Stage 3 — basic Kubernetes
kind create cluster --name shipit
kubectl apply -f stage-3-k8s-basic/manifests/namespace.yaml
kubectl apply -f stage-3-k8s-basic/manifests/db/
kubectl apply -f stage-3-k8s-basic/manifests/api/
kubectl apply -f stage-3-k8s-basic/manifests/frontend/
```

## Directory layout

```
container-migration-workshop/
├── WORKSHOP.md                        ← full interactive guide (start here)
├── stage-0-dockerfiles/
│   ├── api/        Dockerfile, app.py, requirements.txt
│   └── frontend/   Dockerfile, index.html, nginx.conf
├── stage-1-docker-run/
│   ├── run.sh      Start all containers manually
│   └── teardown.sh Remove all containers
├── stage-2-compose/
│   ├── docker-compose.yaml
│   └── .env.example
├── stage-3-k8s-basic/
│   └── manifests/
│       ├── namespace.yaml
│       ├── db/     secret, pvc, deployment, service
│       ├── api/    configmap, deployment, service
│       └── frontend/ deployment, service
└── stage-4-k8s-production/
    └── manifests/
        ├── ingress.yaml
        ├── db/     statefulset, service
        ├── api/    service, hpa
        └── frontend/ service, hpa
```
