#!/bin/bash
# 01-run-baseline-scale-test.sh
#
# Baseline: one GitRepo with 50 bundles to all clusters, then delete.
# Results are written as JSON lines via lib/results.sh (see there for what
# emit_event does).
#
# Edit the values below directly before running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/results.sh"

# VER="0.16.0-rc.2"
VER="${VER:-$(cat "${SCRIPT_DIR%/*}/../../VERSION")}" # shared across all scripts, see qa/VERSION

clusters=${CLUSTERS:-$(kubectl get clusters.fleet.cattle.io -n fleet-default --no-headers 2>/dev/null | wc -l)} # registered Fleet Clusters; override with CLUSTERS=N
agents=$clusters
bundles=50
cluster_ready="$clusters/$clusters"
test_bd=$((clusters * bundles))
total_bd=$((agents + test_bd))
test_bd_ready="$test_bd/$test_bd"
bundles_per_cluster=$((1 + bundles))
bundle_ready="$bundles_per_cluster/$bundles_per_cluster"

gitrepo_name="scale-50-single"
gitrepo_manifest="$SCRIPT_DIR/manifests/gitrepo-scale-50-bundles-baseline.yaml"

results_init 01_baseline_scale "$VER"
echo "Clusters: $clusters"
echo "Agents: $agents"
echo "Bundles: $bundles"
echo "Total BundleDeployments: $total_bd"
echo
emit_event "test parameters: clusters=$clusters bundles=$bundles total_bundledeployments=$total_bd"

### Create
created_at=$(date +%s)
render_manifest "$gitrepo_manifest" | kubectl apply -f - -n fleet-default
echo
emit_event "created gitrepo for $bundles bundles"

wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/repo-name=$gitrepo_name" 2>/dev/null | wc -l) != bundles )); do echo -n .; sleep 1; wait_check "bundles exist"; done
echo
emit_event "bundles exist"

wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -A bundledeployments | wc -l) != total_bd )); do echo -n .; sleep 10; wait_check "bundledeployments exist"; done
echo
emit_event "bundledeployments exist"

wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/repo-name=$gitrepo_name" | grep "$cluster_ready" | wc -l) != bundles )); do echo -n .; sleep 5; wait_check "bundles ready"; done
echo
emit_event "bundles ready"

wait_start
while ! kubectl get -n fleet-default gitrepo "$gitrepo_name" | grep -q "$test_bd_ready"; do echo -n .; sleep 5; wait_check "gitrepo ready"; done
echo
emit_event "gitrepo ready"
emit_metric gitrepo_created_to_ready_seconds "$(( $(date +%s) - created_at ))" s

wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -n fleet-default clusters | grep "$bundle_ready" | wc -l) != clusters )); do echo -n .; sleep 5; wait_check "clusters ready"; done
echo
emit_event "clusters ready"

### Delete
echo
echo "delete "
deleted_at=$(date +%s)
kubectl delete -n fleet-default gitrepo "$gitrepo_name"
echo

wait_start "$DELETE_TIMEOUT_SECONDS"
while (( $(kubectl get secrets --no-headers -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 | wc -l) != 0 )); do echo -n .; sleep 5; wait_check "secrets removed"; done
echo
emit_event "secrets removed"
emit_metric delete_to_secrets_removed_seconds "$(( $(date +%s) - deleted_at ))" s

results_summary pass \
  "all $bundles bundles ready on $clusters clusters ($test_bd_ready bundledeployments), secrets removed after delete" \
  "all $bundles bundles reached ready, gitrepo reported $test_bd_ready, secrets removed"
