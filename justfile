# zarforma justfile
# https://github.com/casey/just

# List available commands
default:
    @just --list

# ── Cluster ──────────────────────────────────────────────────────────────────

# Create the k3d cluster
[group('cluster')]
cluster-up:
    k3d cluster create --config cluster/k3d-config.yaml

# Destroy the k3d cluster
[group('cluster')]
cluster-down:
    k3d cluster delete zarforma

# Nuke and recreate the cluster
[group('cluster')]
cluster-reset: cluster-down cluster-up

# ── Packages ─────────────────────────────────────────────────────────────────

# Build a single package (e.g. just build-package kube-prometheus-stack)
[group('packages')]
build-package name:
    zarf package create packages/{{name}} -o packages/{{name}} --confirm

# Build all packages
[group('packages')]
build-all:
    for dir in packages/*/; do zarf package create "$dir" -o "$dir" --confirm || exit 1; done

# Inspect a built package
[group('packages')]
inspect-package name:
    zarf package inspect definition packages/{{name}}/zarf-package-*-amd64-*.tar.zst

# ── Bundle ───────────────────────────────────────────────────────────────────

# Build the UDS bundle
[group('bundle')]
bundle:
    uds create bundle --confirm

# ── Deploy ───────────────────────────────────────────────────────────────────

# Deploy the bundle to the current cluster context
[group('deploy')]
deploy:
    uds deploy bundle/uds-bundle-zarforma-amd64-*.tar.zst --confirm

# Full workflow: build all packages, bundle, and deploy
[group('deploy')]
up: build-all bundle deploy

# Full workflow from scratch: reset cluster, build, bundle, deploy
[group('deploy')]
full-reset: cluster-reset build-all bundle deploy

# ── Utilities ────────────────────────────────────────────────────────────────

# Show all pods across all namespaces
[group('utils')]
pods:
    kubectl get pods -A

# Verify images are being served from the Zarf internal registry
[group('utils')]
verify-airgap:
    kubectl get pods -A -o yaml | grep "image:" | sort -u

# Get the Grafana admin password and open Grafana in one shot
[group('utils')]
grafana-login:
    @echo "Username: admin"
    @echo "Password: $(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)"
    @echo "Opening http://localhost:3000 ..."
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# ── Elastic ──────────────────────────────────────────────────────────────────

# Show all ECK-managed custom resources at a glance
[group('elastic')]
elastic-status:
    @echo "── Elasticsearch ──"
    kubectl get elasticsearch -n elastic-stack
    @echo "\n── Kibana ──"
    kubectl get kibana -n elastic-stack
    @echo "\n── Fleet Server ──"
    kubectl get fleetserver -n elastic-stack
    @echo "\n── Elastic Agent ──"
    kubectl get agent -n elastic-stack
    @echo "\n── Logstash ──"
    kubectl get logstash -n elastic-stack
    @echo "\n── Beats ──"
    kubectl get beat -n elastic-stack

# Show every ECK CR's full health/phase detail (wider columns, not just NAME/HEALTH)
[group('elastic')]
elastic-describe:
    kubectl get elasticsearch,kibana,fleetserver,agent,logstash,beat -n elastic-stack -o wide

# Watch ECK resources reconcile in real time (useful right after deploy)
[group('elastic')]
elastic-watch:
    kubectl get elasticsearch,kibana,fleetserver,agent,logstash,beat -n elastic-stack -w

# Pods only, for the elastic-stack + elastic-system namespaces
[group('elastic')]
elastic-pods:
    kubectl get pods -n elastic-stack -n elastic-system 2>/dev/null || (kubectl get pods -n elastic-stack; kubectl get pods -n elastic-system)

# Tail the ECK operator logs (most useful place to look when a CR is stuck reconciling)
[group('elastic')]
elastic-operator-logs:
    kubectl logs -n elastic-system -l control-plane=elastic-operator -f --tail=100

# Get the elastic superuser password (default ECK-generated secret)
[group('elastic')]
elastic-password:
    kubectl get secret elasticsearch-es-elastic-user -n elastic-stack -o jsonpath='{.data.elastic}' | base64 -d && echo

# Get the elastic password and open Kibana in one shot
[group('elastic')]
kibana-login:
    @echo "Password: $(kubectl get secret elasticsearch-es-elastic-user -n elastic-stack -o jsonpath='{.data.elastic}' | base64 -d)"
    @echo "Username: elastic"
    @echo "Opening https://localhost:5601 ..."
    kubectl port-forward -n elastic-stack svc/kibana-kb-http 5601:5601

# Port-forward Elasticsearch to localhost:9200 (curl with -k, self-signed cert)
[group('elastic')]
elasticsearch:
    kubectl port-forward -n elastic-stack svc/elasticsearch-es-http 9200:9200

# ── SBOM ─────────────────────────────────────────────────────────────────────

# Extract SBOMs for a single package (e.g. just sbom eck-stack)
[group('sbom')]
sbom name:
    zarf package inspect sbom packages/{{name}}/zarf-package-*-amd64-*.tar.zst --output sboms/{{name}}

# Extract SBOMs for every package
[group('sbom')]
sbom-all:
    for dir in packages/*/; do \
        name=$(basename "$dir"); \
        tarball=$(ls packages/"$name"/zarf-package-*-amd64-*.tar.zst 2>/dev/null | head -n1); \
        if [ -n "$tarball" ]; then \
            echo "── Extracting SBOMs: $name ──"; \
            zarf package inspect sbom "$tarball" --output sboms/"$name" || exit 1; \
        else \
            echo "── Skipping $name (no built package found — run 'just build-package $name' first) ──"; \
        fi; \
    done
    
[group('sbom')]
sbom-fresh: build-all sbom-all