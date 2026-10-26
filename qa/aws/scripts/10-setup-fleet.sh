#!/bin/bash

set -euo pipefail
# ./default_config/open-tunnels-to-upstream-server-0.sh
# export KUBECONFIG="$PWD/default_config/upstream.yaml"
# sleep 5

# kubectl config use-context upstream

kubectl create ns fleet-default || true

# export VER='0.12.7'
# VER="0.12.9-beta.2"
# VER="0.13.0"
# VER="0.13.2-rc.2"
# VER="0.14.1-beta.3"
# VER="0.13.4"
# VER="0.13.5-beta.1"
# VER="0.14.0-beta.1"
# VER="0.13.7-alpha.2"
# VER="0.13.9-rc.4"
# VER="0.14.2-beta.1"
# VER="0.14.3-rc.1"
# VER="0.14.3-rc.2"
# VER="0.14.3-rc.3"
# VER="0.14.4-beta.2"
# VER="v0.14.4-rc.1"
# VER="0.14.5-beta.5"
# VER="0.15.0-alpha.4"
# VER="0.15.0-alpha.5"
# VER="0.15.0-alpha.9"
# VER="0.15.0-alpha.10"
# VER="0.15.0-beta.1"
# VER="0.15.0-beta.2"
# VER="0.15.0-beta.4"
# VER="0.15.0-rc.1"
# VER="v0.15.0-rc.6"
# VER="v0.15.0"
# VER="0.15.1-beta.4"
# VER="0.15.3-rc.1"
# VER="0.16.0"
VER="$(cat "$(dirname "$0")/VERSION")" # shared across all scripts, see scripts/VERSION


VER=${VER#v}

helm -n cattle-fleet-system upgrade --install --create-namespace --wait fleet-crd \
  https://github.com/rancher/fleet/releases/download/v"$VER"/fleet-crd-"$VER".tgz

node=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath="{.items[*].status.addresses[?(@.type=='Hostname')].address}" | tr ' ' '\n' | shuf -n 1)
kubectl label node "$node" role=agent

cpnode=$(kubectl get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath="{.items[*].status.addresses[?(@.type=='Hostname')].address}" | tr ' ' '\n' | head -1 )

ca=$( kubectl config view --flatten -o jsonpath='{.clusters[?(@.name == "upstream")].cluster.certificate-authority-data}' | base64 -d )
helm -n cattle-fleet-system upgrade --install --create-namespace --wait \
  --set bootstrap.enabled=false \
  --set controller.reconciler.workers.gitrepo=100 \
  --set controller.reconciler.workers.bundle=200 \
  --set controller.reconciler.workers.bundledeployment=200 \
  --set controller.reconciler.workers.cluster=100 \
  --set apiServerCA="$ca" \
  --set apiServerURL="https://$cpnode.ec2.internal:6443" \
  --set nodeSelector.role=agent \
  fleet \
  https://github.com/rancher/fleet/releases/download/v"$VER"/fleet-"$VER".tgz

kubectl -n cattle-fleet-system rollout status deploy/fleet-controller
