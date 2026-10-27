#!/bin/bash

set -euo pipefail
# ./default_config/open-tunnels-to-upstream-server-0.sh
# export KUBECONFIG="$PWD/default_config/upstream.yaml"
# sleep 5

# kubectl config use-context upstream

kubectl create ns fleet-default || true

VER="${VER:-$(cat "$(dirname "$0")/../../VERSION")}" # shared across all scripts, see qa/VERSION



VER=${VER#v}

# helm's own chart downloader has been flaky against GitHub's release-asset
# CDN redirects in testing (fails with a plain "EOF" mid-download, even
# though the asset itself is fine) -- curl it ourselves and hand helm a
# local file instead.
chart_dir="$(mktemp -d)"
trap 'rm -rf "$chart_dir"' EXIT
curl -fL -o "$chart_dir/fleet-crd-$VER.tgz" \
  "https://github.com/rancher/fleet/releases/download/v$VER/fleet-crd-$VER.tgz"
curl -fL -o "$chart_dir/fleet-$VER.tgz" \
  "https://github.com/rancher/fleet/releases/download/v$VER/fleet-$VER.tgz"

helm -n cattle-fleet-system upgrade --install --create-namespace --wait fleet-crd \
  "$chart_dir/fleet-crd-$VER.tgz"

node=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath="{.items[*].status.addresses[?(@.type=='Hostname')].address}" | tr ' ' '\n' | shuf -n 1)
kubectl label node "$node" role=agent

cpnode=$(kubectl get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath="{.items[*].status.addresses[?(@.type=='Hostname')].address}" | tr ' ' '\n' | head -1 )

# --minify keeps only the current context's cluster entry, so this works
# regardless of what the cluster is named in the kubeconfig (k3d names it
# "k3d-<project>-upstream", not "upstream" like the AWS flow's kubeconfig).
ca=$( kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d )
helm -n cattle-fleet-system upgrade --install --create-namespace --wait \
  --set bootstrap.enabled=false \
  --set controller.reconciler.workers.gitrepo=100 \
  --set controller.reconciler.workers.bundle=200 \
  --set controller.reconciler.workers.bundledeployment=200 \
  --set controller.reconciler.workers.cluster=100 \
  --set apiServerCA="$ca" \
  --set apiServerURL="https://$cpnode:6443" \
  --set nodeSelector.role=agent \
  fleet \
  "$chart_dir/fleet-$VER.tgz"

kubectl -n cattle-fleet-system rollout status deploy/fleet-controller
