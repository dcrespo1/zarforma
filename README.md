# Zarforma

A local air-gapped Kubernetes environment using [Zarf](https://zarf.dev) and [UDS](https://github.com/defenseunicorns/uds-cli) for offline-compatible application management.

Inspired by [Terraforma](https://github.com/dcrespo1/terraforma), this project swaps the GitOps/ArgoCD model for a Zarf + UDS bundle workflow — the goal is to simulate and explore what it takes to manage an air-gapped Kubernetes environment locally.

## Goals

- Learn the Defense Unicorns ecosystem (Zarf + UDS CLI)
- Understand air-gapped package lifecycle end to end
- Maintain a toggle-able local platform stack via UDS bundle composition

## How it works

1. Each application lives in `packages/` as a `zarf.yaml` — all images and Helm charts are declared explicitly so Zarf can bundle them at build time
2. `just bundle` (`uds create bundle --confirm`) assembles all packages into a single `uds-bundle-zarforma-amd64-*.tar.zst` tarball
3. That tarball is fully self-contained — no internet access required at deploy time
4. `just deploy` (`uds deploy`) pushes everything into the cluster via the Zarf internal registry

## Prerequisites

| Tool                                                           | Install                                                              |
| -------------------------------------------------------------- | -------------------------------------------------------------------- |
| [zarf](https://docs.zarf.dev/getting-started/install/)         | `brew install zarf` or grab the binary                               |
| [uds-cli](https://github.com/defenseunicorns/uds-cli/releases) | grab the binary from releases                                        |
| [k3d](https://k3d.io/#installation)                            | `brew install k3d`                                                   |
| [kubectl](https://kubernetes.io/docs/tasks/tools/)             | `brew install kubectl`                                               |
| [helm](https://helm.sh/docs/intro/install/)                    | `brew install helm`                                                  |
| [just](https://github.com/casey/just#installation)             | `brew install just`                                                  |
| [crane](https://github.com/google/go-containerregistry)        | `go install github.com/google/go-containerregistry/cmd/crane@latest` |
| [cosign](https://docs.sigstore.dev/cosign/installation/)       | for verifying image signatures                                       |

> Running in WSL? `explorer.exe <file>.html` or `wslview <file>.html` (via `apt install wslu`) will open SBOM/compare HTML files in your Windows browser. See [Viewing SBOMs](#viewing-sboms) below.

## Structure

```
zarforma/
  k3d-config.yaml           # Multi-node k3d cluster definition (1 server, 2 agents)
  justfile                  # Task runner (grouped: cluster, packages, bundle, deploy, utils, elastic, sbom)
  packages/
    cert-manager/
      zarf.yaml
      custom-values.yaml
      vendor-values.yaml
    elk/                     # ECK Operator + Elasticsearch/Kibana/Fleet/Agent
      zarf.yaml
      eck-operator-vendor-values.yaml
      eck-stack-custom-values.yaml
      eck-stack-vendor-values.yaml
    kube-prom-stack/
      zarf.yaml
  bundle/
    uds-bundle.yaml          # Toggle packages on/off here
  sboms/                     # Generated via `just sbom-all` (gitignored)
```

## Quickstart

```bash
# 1. Spin up a local multi-node k3d cluster (1 server, 2 agents — see k3d-config.yaml)
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

## Multi-node cluster

The cluster is defined declaratively in `k3d-config.yaml` rather than passed as flags, so node counts are version-controlled:

```yaml
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: zarforma
servers: 1
agents: 2
```

`just cluster-up` runs `k3d cluster create --config k3d-config.yaml`. Multi-node matters here specifically for validating DaemonSet behavior (e.g. `eck-agent` in the ECK package), which a single-node cluster can't meaningfully exercise.

## Toggling packages

Edit `bundle/uds-bundle.yaml` and comment out any package you don't want deployed, or use `uds deploy`'s `--packages` flag at deploy time without editing the bundle definition at all:

```bash
# Deploy only a subset without touching uds-bundle.yaml
uds deploy bundle/uds-bundle-zarforma-amd64-*.tar.zst --packages cert-manager,eck-stack --confirm
```

To disable a package permanently, comment it out in `bundle/uds-bundle.yaml`:

```yaml
packages:
  - name: init
    repository: ghcr.io/zarf-dev/packages/init
    ref: v0.74.1
  - name: kube-prometheus-stack
    path: ../packages/kube-prom-stack
    ref: 0.0.1
  - name: cert-manager
    path: ../packages/cert-manager
    ref: 0.0.1
  # - name: eck-stack          # comment out to disable
  #   path: ../packages/elk
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
        valuesFiles:
          - values.yaml
    images:
      - docker.io/myorg/my-app:1.0.0
```

3. Find the images the chart actually needs:

```bash
zarf dev find-images
```

> ⚠️ **CRD-driven / operator-style charts (like ECK, and to a lesser extent cert-manager) won't fully resolve this way.** If the chart creates a Custom Resource that an operator reconciles later (rather than a `Deployment`/`StatefulSet` directly), `find-images` will report zero or partial results — not an error, just nothing to find, because the image reference doesn't exist anywhere in the rendered templates. Confirm with:
>
> ```bash
> helm template <release> <repo>/<chart> --version <ver> | grep -i "image:"
> ```
>
> If that's empty too, you'll need to add the images manually based on the chart's default/configured stack version. See `packages/elk/zarf.yaml` for a real example, and the full writeup in `docs/finding-images.md`.

4. (Optional) Add cosign signature artifacts alongside each image:

```bash
cosign triangulate docker.io/myorg/my-app:1.0.0
crane manifest docker.io/myorg/my-app:sha256-<digest>.sig   # confirm it exists before adding it
```

5. Build the package:

```bash
just build-package my-app
```

6. Add it to `bundle/uds-bundle.yaml` and rebuild:

```bash
just bundle
just deploy
```

---

## Justfile Reference

Recipes are grouped (`just --list` shows them clustered): `cluster`, `packages`, `bundle`, `deploy`, `utils`, `elastic`, `sbom`.

### Cluster

```bash
just cluster-up      # k3d cluster create --config k3d-config.yaml
just cluster-down     # k3d cluster delete zarforma
just cluster-reset    # down + up
```

### Packages

```bash
just build-package <name>    # zarf package create packages/<name> -o packages/<name> --confirm
just build-all                # builds every package in packages/, output stays local to each dir
just inspect-package <name>   # zarf package inspect definition on the built tarball
```

### Bundle / Deploy

```bash
just bundle          # uds create bundle --confirm
just deploy           # uds deploy bundle/uds-bundle-zarforma-amd64-*.tar.zst --confirm
just up                # build-all + bundle + deploy
just full-reset        # cluster-reset + build-all + bundle + deploy
```

### SBOM

```bash
just sbom <name>       # extract SBOMs for one package into sboms/<name>/
just sbom-all           # extract SBOMs for every built package (skips any that aren't built yet)
```

Extracted SBOMs include both `.json` (Syft format) and `sbom-viewer-*.html` (browsable dashboard) files per image, plus a `compare.html` tool for diffing two SBOM `.json` files against each other — useful for seeing exactly what changed between image versions during an upgrade.

### Utilities

```bash
just pods                # kubectl get pods -A
just verify-airgap        # confirm all images are served from the Zarf internal registry
just grafana               # port-forward Grafana to localhost:3000
just grafana-login          # print Grafana admin password + port-forward in one shot
```

### Elastic (ECK)

```bash
just elastic-status          # quick view of all ECK-managed CRs (Elasticsearch, Kibana, Fleet, Agent, Logstash, Beats) **beep-boop**
just elastic-describe         # same, with -o wide
just elastic-watch             # watch ECK resources reconcile live, useful right after deploy
just elastic-pods               # pods in elastic-stack + elastic-system
just elastic-operator-logs       # tail the ECK operator — the place to look when a CR is stuck
just elastic-password             # print the elastic superuser password
just kibana-login                  # print elastic credentials + port-forward Kibana (https://localhost:5601)
just elasticsearch                  # port-forward Elasticsearch to localhost:9200
```

---

## Viewing SBOMs

```bash
# Extract SBOMs for a package (or use `just sbom <name>`)
zarf package inspect sbom packages/elk/zarf-package-eck-stack-amd64-*.tar.zst --output sboms/eck-stack
```

Then open any `sbom-viewer-*.html` for a browsable, searchable table of every package/library in that image — no CLI knowledge required. The dropdown in the top-right switches between every image extracted alongside it.

To compare two SBOMs (e.g. before/after bumping an image version), open `compare.html` and load two `.json` files into the Old File / New File pickers.

**On WSL**, HTML files need to be opened via the Windows side:

```bash
explorer.exe sbom-viewer-<image>.html
# or
wslview compare.html
```

For CVE scanning against an SBOM (not just inventory viewing), pipe the `.json` into [Grype](https://github.com/anchore/grype):

```bash
grype sbom:./sboms/eck-stack/docker.elastic.co_elasticsearch_elasticsearch_9.4.2.json
```

To scan an image _live_ out of the Zarf internal registry (rather than the build-time snapshot):

```bash
zarf connect registry &
zarf tools sbom scan registry:127.0.0.1:<port>/<image>:<tag>
```

---

## Zarf CLI Reference

Zarf operates on individual packages — each `zarf.yaml` defines one deployable unit. The lifecycle is: **create → inspect → (publish) → deploy**.

### Package Build

```bash
zarf package create packages/cert-manager -o packages/cert-manager --confirm
```

> The `-o`/`--output` flag matters — without it, the tarball lands in your current working directory, not next to the `zarf.yaml`. `just build-package`/`just build-all` handle this correctly.

### Fast iteration without a full build

```bash
zarf dev deploy packages/elk    # deploys straight from source, skipping the create step
zarf dev lint packages/elk       # validate schema before building
```

### Package Inspection

```bash
zarf package inspect definition packages/elk/zarf-package-eck-stack-amd64-*.tar.zst
zarf package inspect sbom packages/elk/zarf-package-eck-stack-amd64-*.tar.zst --output ./sboms
```

### Package Deploy (standalone, without UDS)

```bash
zarf package deploy packages/elk/zarf-package-eck-stack-amd64-*.tar.zst --confirm
zarf package deploy packages/elk/zarf-package-eck-stack-amd64-*.tar.zst --confirm --components eck-operator
```

### Other Useful Zarf Commands

```bash
zarf package list                       # packages deployed to the cluster
zarf package remove <name> --confirm     # remove a deployed package
zarf tools get-creds                      # registry/git credentials for Zarf-managed services
zarf connect registry                      # port-forward to the Zarf internal registry
zarf tools monitor                          # launches k9s against the connected cluster
zarf tools sbom scan registry:<host>/<image>  # live SBOM scan of an image already in a registry
zarf tools gen-key                           # generate a cosign keypair for signing your own packages
```

Run with `-l debug` on any command when something completes without error but the result looks wrong (e.g. an empty images list) — this is what surfaced the CRD-driven blind spot on the ECK package.

---

## UDS CLI Reference

UDS CLI operates one level above Zarf — it assembles multiple Zarf packages into a single **bundle** and manages their lifecycle together.

### Bundle Create / Deploy

```bash
uds create bundle --confirm
uds deploy bundle/uds-bundle-zarforma-amd64-*.tar.zst --confirm
uds deploy bundle/uds-bundle-zarforma-amd64-*.tar.zst --packages cert-manager,eck-stack --confirm
```

### Bundle Inspect / Remove

```bash
uds inspect bundle/uds-bundle-zarforma-amd64-*.tar.zst
uds remove bundle/uds-bundle-zarforma-amd64-*.tar.zst --confirm
uds remove bundle/uds-bundle-zarforma-amd64-*.tar.zst --packages eck-stack --confirm
```

---

## Notes

- Built package tarballs (`packages/*/zarf-package-*.tar.zst`), the UDS bundle tarball (`bundle/uds-bundle-*.tar.zst`), and generated SBOMs (`sboms/`) are all excluded from git — only source `zarf.yaml`/values files are committed.
- This project uses the upstream Zarf init package from `ghcr.io/zarf-dev/packages/init` — no custom init required.
- For CRD-driven charts (ECK being the primary example here), image discovery requires a manual step beyond `zarf dev find-images` — see the [Adding a new package](#adding-a-new-package) section above.
