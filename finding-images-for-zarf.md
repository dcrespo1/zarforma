# Finding Images for Zarf Packages

Quick reference for figuring out which container images a Helm chart actually
needs, especially for operator-style charts (ECK, cert-manager, etc.) where
`zarf dev find-images` doesn't catch everything.

## 1. Start with the standard tool

```bash
zarf dev find-images
```

Run this from the directory containing your `zarf.yaml`. It templates each
chart and scans the rendered manifests for `image:` fields. Works great for
charts that deploy real `Deployment`/`StatefulSet`/`DaemonSet` resources
directly (e.g. `eck-operator`, `cert-manager`'s core controllers).

If you have custom values, wire them up first with `valuesFiles:` in the
component — `find-images` renders with whatever values your component
actually uses, so it only reports images you'll really need.

## 2. Know the blind spot: CRD-driven charts

Some charts don't deploy workloads directly — they create a **Custom
Resource** (e.g. `Elasticsearch`, `Kibana`, `Beat`), and an **operator**
running elsewhere reads that CR's `spec.version` and creates the actual
Pods dynamically, later, at reconcile time.

`find-images` is a static template scanner. It has nothing to find in these
cases — no error, just zero results for that component. Recognize this
pattern:

```bash
helm template <release> <chart> --version <ver> | grep -i "image:"
```

If this comes back empty for a chart you know deploys real workloads
eventually (Elasticsearch, Kibana, Logstash, Fleet Server, Agent, APM
Server, Beats), you're looking at the CRD-driven case.

## 3. Manually add the missing images

Check the chart's default stack version:

```bash
helm show values elastic/eck-stack --version <ver> | grep -A3 version
```

Then add the images by hand to your `zarf.yaml`, matching whatever version
you're setting in your values file:

```yaml
images:
  - docker.elastic.co/elasticsearch/elasticsearch:9.4.2
  - docker.elastic.co/kibana/kibana:9.4.2
  - docker.elastic.co/elastic-agent/elastic-agent:9.4.2 # covers agent + fleet-server
```

Leave a comment noting _why_ these are manual — future-you (or whoever
inherits the package) shouldn't rerun `find-images`, see it come back
empty, and assume something's broken.

## 4. Add cosign signatures (if you want them)

Cosign signature tags are deterministic: an image's digest `sha256:<hash>`
becomes a sibling tag `sha256-<hash>.sig` in the same repo.

```bash
# Get the sig reference directly
cosign triangulate docker.elastic.co/elasticsearch/elasticsearch:9.4.2

# Confirm it actually exists before trusting it
crane manifest docker.elastic.co/elasticsearch/elasticsearch:sha256-<hash>.sig
```

Note: `cosign tree` may fail against some registries (`MANIFEST_INVALID:
Schema 2 manifest not supported`) — `triangulate` still works, it's just
deprecated in favor of `oras discover`/`cosign tree` upstream. Use
`triangulate` + `crane manifest` as the reliable combo.

Only bother with signatures if you're actually verifying image provenance
downstream (e.g. Kyverno/policy-controller cosign verification). Otherwise
skip — they're not required for the images to run.

## 5. Confirm you didn't miss anything

The most reliable check is a live, connected deploy — let the operator
actually reconcile, then ask Kubernetes what it pulled:

```bash
zarf package deploy zarf-package-*.tar.zst --confirm

kubectl get pods -n <namespace> -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
```

Diff that list against your `zarf.yaml`'s `images:` block. Anything missing
is a gap — usually a conditionally-created image (e.g. an ACME solver pod,
an init container) that only appears once a specific feature is enabled.

Re-run this check any time you enable a new feature or integration in the
chart's values (new Fleet integration packages, new Beat types, etc.) —
each can pull in images that were invisible until that feature turned on.

## TL;DR checklist

- [ ] `zarf dev find-images` first — free wins for standard workloads
- [ ] `helm template ... | grep image:` — if empty, it's CRD-driven
- [ ] Check chart defaults / your values file for the version being deployed
- [ ] Manually add images, tagged to match that version, with a comment explaining why
- [ ] (Optional) add cosign `.sig` tags via `triangulate` + `crane manifest`
- [ ] Connected deploy + `kubectl` image diff to catch anything still missing
