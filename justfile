# zarforma justfile
# https://github.com/casey/just

# List available commands
default:
    @just --list

# ── Cluster ──────────────────────────────────────────────────────────────────

# Create the k3d cluster
cluster-up:
    k3d cluster create zarforma

# Destroy the k3d cluster
cluster-down:
    k3d cluster delete zarforma

# Nuke and recreate the cluster
cluster-reset: cluster-down cluster-up

# ── Packages ─────────────────────────────────────────────────────────────────

# Build a single package (e.g. just build-package kube-prometheus-stack)
build-package name:
    zarf package create packages/{{name}} --confirm

# Build all packages
build-all:
    for dir in packages/*/; do zarf package create "$dir" --confirm; done

# Inspect a built package
inspect-package name:
    zarf package inspect definition packages/{{name}}/zarf-package-{{name}}-amd64-*.tar.zst

# ── Bundle ───────────────────────────────────────────────────────────────────

# Build the UDS bundle
bundle:
    uds create bundle --confirm

# ── Deploy ───────────────────────────────────────────────────────────────────

# Deploy the bundle to the current cluster context
deploy:
    uds deploy bundle/uds-bundle-zarforma-amd64-*.tar.zst --confirm

# Full workflow: build all packages, bundle, and deploy
up: build-all bundle deploy

# Full workflow from scratch: reset cluster, build, bundle, deploy
full-reset: cluster-reset build-all bundle deploy

# ── Utilities ────────────────────────────────────────────────────────────────

# Show all pods across all namespaces
pods:
    kubectl get pods -A

# Verify images are being served from the Zarf internal registry
verify-airgap:
    kubectl get pods -A -o yaml | grep "image:" | sort -u

# Port-forward Grafana to localhost:3000
grafana:
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
