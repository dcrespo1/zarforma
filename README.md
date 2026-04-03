# Zarforma

A local air-gapped Kubernetes environment using [Zarf](https://zarf.dev) and [UDS](https://github.com/defenseunicorns/uds-cli) for offline-compatible application management.

Inspired by [Terraforma](https://github.com/dcrespo1/terraforma), this project swaps the GitOps/ArgoCD model for a Zarf + UDS bundle workflow — the goal is to simulate and explore what it takes to manage an air-gapped Kubernetes environment locally.

## Goals

- Learn the Defense Unicorns ecosystem (Zarf + UDS CLI)
- Understand air-gapped package lifecycle end to end
- Maintain a toggle-able local platform stack via UDS bundle composition

## How it works

1. Each application lives in `packages/` as a `zarf.yaml` — all images and Helm charts are declared explicitly so Zarf can bundle them at build time
2. `uds create bundle/` assembles all packages into a single `uds-bundle-zarforma-amd64-*.tar.zst` tarball
3. That tarball is fully self-contained — no internet access required at deploy time
4. `uds deploy` pushes everything into the cluster via the Zarf internal registry at `127.0.0.1:31999`

## Prerequisites

| Tool                                                           | Install                                |
| -------------------------------------------------------------- | -------------------------------------- |
| [zarf](https://docs.zarf.dev/getting-started/install/)         | `brew install zarf` or grab the binary |
| [uds-cli](https://github.com/defenseunicorns/uds-cli/releases) | grab the binary from releases          |
| [k3d](https://k3d.io/#installation)                            | `brew install k3d`                     |
| [kubectl](https://kubernetes.io/docs/tasks/tools/)             | `brew install kubectl`                 |
| [helm](https://helm.sh/docs/intro/install/)                    | `brew install helm`                    |
| [just](https://github.com/casey/just#installation)             | `brew install just`                    |

## Structure

```
zarforma/
  packages/
    kube-prometheus-stack/   # Prometheus, Grafana, Alertmanager
    cert-manager/            # TLS certificate management
    ingress-nginx/           # Ingress controller
    kyverno/                 # Policy engine
  bundle/
    uds-bundle.yaml          # Toggle packages on/off here
  justfile                   # Task runner
```

## Quickstart

```bash
# 1. Spin up a local k3d cluster
just cluster-up

# 2. Build all packages
just build-all

# 3. Create the UDS bundle
just bundle

# 4. Deploy
just deploy
```

Or do it all at once from a clean state:

```bash
just full-reset
```

## Toggling packages

Edit `bundle/uds-bundle.yaml` and comment out any package you don't want deployed:

```yaml
packages:
  - name: kube-prometheus-stack
    path: ../packages/kube-prometheus-stack
    ref: 0.0.1
  # - name: kyverno          # comment out to disable
  #   path: ../packages/kyverno
  #   ref: 0.0.1
```

Then rebuild and redeploy the bundle:

```bash
just bundle
just deploy
```

## Adding a new package

1. Create a folder under `packages/`:

```
packages/my-app/
  zarf.yaml
  values.yaml   # optional helm overrides
```

2. Write the `zarf.yaml`:

```yaml
kind: ZarfPackageConfig
metadata:
  name: my-app
  version: 0.0.1

components:
  - name: my-app
    required: true
    charts:
      - name: my-app
        url: https://my-chart-repo.github.io/charts
        version: 1.0.0
        namespace: my-app
    images:
      - docker.io/myorg/my-app:1.0.0
```

3. Get the full image list for the chart:

```bash
helm repo add my-repo https://my-chart-repo.github.io/charts
helm template my-app my-repo/my-app --version 1.0.0 | grep "image:" | sort -u
```

> ⚠️ The `helm template` output may not catch every image (sidecars, init containers, operator-injected images). Also run:
>
> ```bash
> helm show values my-repo/my-app --version 1.0.0 | grep -A3 "repository:"
> ```

4. Build the package:

```bash
just build-package my-app
```

5. Add it to `bundle/uds-bundle.yaml` and rebuild:

```bash
just bundle
just deploy
```

## Useful commands

```bash
just pods              # show all pods
just verify-airgap     # confirm all images are served from 127.0.0.1:31999
just grafana           # port-forward Grafana to localhost:3000
just inspect-package kube-prometheus-stack  # inspect a built package
```

## Air-gap verification

After deploying, confirm no images are being pulled from external registries:

```bash
kubectl get pods -A -o yaml | grep "image:" | sort -u
```

Every image should show `127.0.0.1:31999` as the registry with a `-zarf-<hash>` tag suffix.

## Notes

- Built package tarballs (`*.tar.zst`) are excluded from git via `.gitignore`
- The UDS bundle tarball is also excluded — only source `zarf.yaml` files are committed
- This project uses the upstream Zarf init package from `ghcr.io/zarf-dev/packages/init` — no custom init required
