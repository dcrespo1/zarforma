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

---

## Zarf CLI Reference

Zarf operates on individual packages — each `zarf.yaml` defines one deployable unit. The lifecycle is: **create → inspect → (publish) → deploy**.

### Package Build

```bash
# Build a package from a zarf.yaml in the current directory
zarf package create .

# Build from a specific directory
zarf package create packages/cert-manager/

# Build with a custom output directory
zarf package create packages/cert-manager/ --output packages/cert-manager/

# Build without confirming prompts (useful in CI)
zarf package create . --confirm

# Set the log level for verbose output during build
zarf package create . --log-level debug
```

Zarf pulls all declared images and chart tarballs at build time and bundles them into a `zarf-package-<name>-<arch>-<version>.tar.zst` file.

### Package Inspection

```bash
# List all components, images, and charts in a built package
zarf package inspect zarf-package-cert-manager-amd64-0.0.1.tar.zst

# Inspect using the shorthand alias (just the package name, no path needed if in same dir)
zarf package inspect cert-manager

# Show only the SBOMs (software bill of materials) embedded in the package
zarf package inspect zarf-package-cert-manager-amd64-0.0.1.tar.zst --sbom

# Extract the SBOM to a local directory for review
zarf package inspect zarf-package-cert-manager-amd64-0.0.1.tar.zst --sbom-out ./sbom-output/
```

### Package Deploy (standalone, without UDS)

You can deploy individual Zarf packages directly without wrapping them in a UDS bundle. This is useful for iterating on a single package before bundling.

```bash
# Deploy a package interactively
zarf package deploy zarf-package-cert-manager-amd64-0.0.1.tar.zst

# Deploy without prompts
zarf package deploy zarf-package-cert-manager-amd64-0.0.1.tar.zst --confirm

# Deploy only specific components within the package
zarf package deploy zarf-package-cert-manager-amd64-0.0.1.tar.zst --components cert-manager

# Pass Helm overrides at deploy time
zarf package deploy zarf-package-cert-manager-amd64-0.0.1.tar.zst \
  --set cert-manager.installCRDs=true

# Deploy with a specific kubeconfig context
zarf package deploy zarf-package-cert-manager-amd64-0.0.1.tar.zst \
  --kubeconfig ~/.kube/config --kube-context k3d-zarforma
```

### Package Publish (OCI registry)

If you have an OCI-compatible registry available (e.g., a Harbor or Zarf-internal registry), you can publish packages for later retrieval.

```bash
# Publish a built package to an OCI registry
zarf package publish zarf-package-cert-manager-amd64-0.0.1.tar.zst \
  oci://127.0.0.1:31999/zarforma

# Pull a published package back down
zarf package pull oci://127.0.0.1:31999/zarforma/cert-manager:0.0.1

# Publish directly from source (build + push in one step)
zarf package publish packages/cert-manager/ oci://127.0.0.1:31999/zarforma
```

### Other Useful Zarf Commands

```bash
# List all Zarf packages deployed to the cluster
zarf package list

# Remove a deployed package
zarf package remove cert-manager --confirm

# View Zarf's internal state (registry credentials, git credentials, etc.)
zarf tools get-creds

# Run the Zarf internal registry UI (useful for browsing pushed images)
zarf tools registry catalog

# Directly interact with the internal registry
zarf tools registry ls 127.0.0.1:31999

# Log in to the internal Zarf registry manually
zarf tools registry login 127.0.0.1:31999 \
  --username zarf-push \
  --password $(zarf tools get-creds | grep "Registry Push Password" | awk '{print $NF}')

# Lint a zarf.yaml before building
zarf dev lint packages/cert-manager/

# Generate a schema for zarf.yaml (useful for IDE validation)
zarf dev generate-config
```

---

## UDS CLI Reference

UDS CLI operates one level above Zarf — it assembles multiple Zarf packages into a single **bundle** and manages their lifecycle together. The lifecycle is: **create → inspect → (publish) → deploy**.

### Bundle Create

```bash
# Create a bundle from a uds-bundle.yaml in the bundle/ directory
uds create bundle/

# Create and output to a specific directory
uds create bundle/ --output bundle/

# Create without confirmation prompts
uds create bundle/ --confirm

# Set architecture explicitly (default: host arch)
uds create bundle/ --architecture amd64

# Verbose output during create
uds create bundle/ --log-level debug
```

The output is a `uds-bundle-<name>-<arch>-<version>.tar.zst` tarball containing all referenced Zarf packages.

### Bundle Deploy

```bash
# Deploy a bundle interactively
uds deploy bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst

# Deploy without prompts
uds deploy bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst --confirm

# Deploy only specific packages within the bundle
uds deploy bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst \
  --packages cert-manager,ingress-nginx

# Pass Zarf variable overrides at deploy time
uds deploy bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst \
  --set cert-manager.INSTALL_CRDS=true

# Deploy from an OCI reference instead of a local tarball
uds deploy oci://127.0.0.1:31999/zarforma/bundle:0.0.1 --confirm
```

### Bundle Inspect

```bash
# Inspect a bundle — lists all included packages and their components
uds inspect bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst

# Inspect with SBOM extraction
uds inspect bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst --sbom

# Inspect an OCI-referenced bundle (no need to pull first)
uds inspect oci://127.0.0.1:31999/zarforma/bundle:0.0.1
```

### Bundle Publish

```bash
# Publish a bundle to an OCI registry
uds publish bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst \
  oci://127.0.0.1:31999/zarforma

# Pull a published bundle back down
uds pull oci://127.0.0.1:31999/zarforma/bundle:0.0.1
```

### Bundle Remove

```bash
# Remove all packages in a deployed bundle
uds remove bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst --confirm

# Remove only specific packages from the bundle
uds remove bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst \
  --packages kyverno --confirm
```

### Other Useful UDS Commands

```bash
# List all UDS bundles (and their Zarf packages) currently deployed in the cluster
uds bundle list

# Run UDS with a specific kubeconfig context
uds deploy bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst \
  --kubeconfig ~/.kube/config --kube-context k3d-zarforma

# Check UDS and Zarf version compatibility
uds version
zarf version
```

---

## Air-Gap Workflow: End to End

This section walks the complete lifecycle from a connected machine (where images are pulled) through to a fully disconnected deploy. In production air-gap scenarios there is a "high side" (connected) and "low side" (disconnected) — this workflow simulates both on localhost using k3d.

### Phase 1 — Connected: Build Everything

On the connected machine (or your dev workstation with internet access):

```bash
# 1. Initialize Zarf — pulls the init package which seeds the internal registry
#    and git server into the cluster. This is a one-time bootstrap step.
zarf init

# If you want to pre-pull the init package for offline use later:
zarf tools download-init
# Outputs: zarf-init-amd64-<version>.tar.zst

# 2. Build all Zarf packages (pulls images + charts from the internet)
just build-all
# Equivalent to running for each package:
#   zarf package create packages/<name>/ --output packages/<name>/ --confirm

# 3. Assemble the UDS bundle (no network calls — packages are already local)
just bundle
# Equivalent to:
#   uds create bundle/ --confirm
```

At this point you have a single self-contained tarball:

```
bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst
```

Everything needed to deploy — all images, Helm charts, and manifests — is inside that tarball. No further internet access is required.

### Phase 2 — Transfer to the "Low Side"

In a real air-gap this step involves physical media (USB, tape, CD) or a one-way data diode transfer. Locally you can simulate the boundary by clearing your Docker image cache and disabling network access before deploying:

```bash
# Simulate transfer — copy only the artifacts that would cross the air gap
cp bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst /path/to/transfer/

# In a real scenario you would also transfer the Zarf init package:
cp zarf-init-amd64-<version>.tar.zst /path/to/transfer/
```

The only files that need to cross the boundary are:

| File                                          | Purpose                                              |
| --------------------------------------------- | ---------------------------------------------------- |
| `zarf-init-amd64-<version>.tar.zst`           | Bootstraps the Zarf internal registry and git server |
| `uds-bundle-zarforma-amd64-<version>.tar.zst` | All application packages                             |

### Phase 3 — Disconnected: Bootstrap and Deploy

On the disconnected machine (or after severing internet on localhost for testing):

```bash
# 1. Bring up the cluster (k3d itself doesn't need internet after initial install)
just cluster-up
# Equivalent to:
#   k3d cluster create zarforma --config k3d-config.yaml

# 2. Initialize Zarf from the local init package (no internet call)
zarf init --components=git-server \
  --registry-push-password=<pw> \
  --registry-push-username=zarf-push \
  --confirm

# Or if you downloaded the init package separately:
zarf init --zarf-cache /path/to/zarf-init-amd64-<version>.tar.zst --confirm

# 3. Deploy the UDS bundle — all images are injected from the tarball
#    into the Zarf internal registry at 127.0.0.1:31999
just deploy
# Equivalent to:
#   uds deploy bundle/uds-bundle-zarforma-amd64-0.0.1.tar.zst --confirm
```

### Phase 4 — Verify the Air Gap

After deploying, confirm that no pods are referencing external registries:

```bash
# All images should show 127.0.0.1:31999 as the registry
kubectl get pods -A -o yaml | grep "image:" | sort -u

# The just recipe wraps this:
just verify-airgap

# Spot-check the internal registry contents directly
zarf tools registry ls 127.0.0.1:31999

# Confirm no external DNS lookups are happening (if you have network policy)
kubectl get networkpolicy -A
```

Every image should have a reference like:

```
127.0.0.1:31999/<name>:<tag>-zarf-<hash>
```

The `-zarf-<hash>` suffix is Zarf's content-addressable tag appended at inject time. If you see any image without this suffix, it was pulled from an external registry and the air gap is not fully closed.

### Updating a Package in an Air-Gapped Environment

```bash
# 1. On the connected side: bump the version in zarf.yaml, rebuild, rebundle
zarf package create packages/cert-manager/ --output packages/cert-manager/ --confirm
uds create bundle/ --confirm

# 2. Transfer the new bundle tarball across the boundary

# 3. On the disconnected side: redeploy — Zarf diffs and only re-pushes changed layers
uds deploy bundle/uds-bundle-zarforma-amd64-0.0.2.tar.zst --confirm
```

---

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
