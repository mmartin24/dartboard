#!/bin/bash
# 03-run-controller-crash-test.sh
#
# Same shape as 01-run-baseline-scale-test.sh, but kills the fleet-controller pod
# mid-rollout (after BundleDeployments exist, before they're ready). Two
# things measured:
#   - correctness: no duplicate BundleDeployments from the resync (final
#     count still matches $total_bd)
#   - performance: controller resync time -- wall-clock from the
#     controller pod becoming ready again to the gitrepo fully converged,
#     i.e. how long it takes Fleet to fully catch up on $total_bd
#     BundleDeployments after a cold restart. This is the one number in
#     this test that's actually a scalability measurement, not a
#     correctness check.
#
# Edit the values below directly before running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/results.sh"

# VER="0.16.0-rc.2"
VER="${VER:-$(cat "$SCRIPT_DIR/../VERSION")}" # shared across all scripts, see scripts/VERSION

clusters=${CLUSTERS:-$(kubectl get clusters.fleet.cattle.io -n fleet-default --no-headers 2>/dev/null | wc -l)} # registered Fleet Clusters; override with CLUSTERS=N
agents=$clusters
bundles=50
cluster_ready="$clusters/$clusters"
test_bd=$((clusters * bundles))
total_bd=$((agents + test_bd))
test_bd_ready="$test_bd/$test_bd"
bundles_per_cluster=$((1 + bundles))
bundle_ready="$bundles_per_cluster/$bundles_per_cluster"

gitrepo_name="scale-50-crash"
gitrepo_manifest="$SCRIPT_DIR/manifests/gitrepo-scale-50-bundles-crash.yaml"

results_init 03_controller_crash "$VER"
echo "Clusters: $clusters"
echo "Bundles: $bundles"
echo "Total BundleDeployments: $total_bd"
echo
emit_event "test parameters: clusters=$clusters bundles=$bundles total_bundledeployments=$total_bd"

### Create
render_manifest "$gitrepo_manifest" | kubectl apply -f - -n fleet-default
echo
emit_event "created gitrepo"

wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/repo-name=$gitrepo_name" 2>/dev/null | wc -l) != bundles )); do echo -n .; sleep 1; wait_check "bundles exist"; done
echo
emit_event "bundles exist"

wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -A bundledeployments | wc -l) != total_bd )); do echo -n .; sleep 10; wait_check "bundledeployments exist"; done
echo
emit_event "bundledeployments exist"

### Kill the controller mid-rollout
kubectl delete pod -n cattle-fleet-system -l app=fleet-controller
echo
emit_event "controller pod deleted"

wait_start
while [[ "$(kubectl get pods -n cattle-fleet-system -l app=fleet-controller -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)" != "true" ]]; do echo -n .; sleep 3; wait_check "controller pod ready again"; done
echo
emit_event "controller pod ready again"
resync_start=$(date +%s)

wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/repo-name=$gitrepo_name" | grep "$cluster_ready" | wc -l) != bundles )); do echo -n .; sleep 5; wait_check "bundles ready"; done
echo
emit_event "bundles ready"

wait_start
while ! kubectl get -n fleet-default gitrepo "$gitrepo_name" | grep -q "$test_bd_ready"; do echo -n .; sleep 5; wait_check "gitrepo ready"; done
echo
emit_event "gitrepo ready"
resync_seconds=$(($(date +%s) - resync_start))
emit_event "controller resync time: ${resync_seconds}s ($total_bd bundledeployments)"

wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -n fleet-default clusters | grep "$bundle_ready" | wc -l) != clusters )); do echo -n .; sleep 5; wait_check "clusters ready"; done
echo
emit_event "clusters ready"

### No duplicate BundleDeployments should have been created by the resync
final_bd_count=$(kubectl get --no-headers --chunk-size=0 -A bundledeployments | wc -l)
echo
emit_event "final bundledeployment count: $final_bd_count (expected $total_bd)"

### Delete
echo
echo "delete "
kubectl delete -n fleet-default gitrepo "$gitrepo_name"
echo

wait_start "$DELETE_TIMEOUT_SECONDS"
while (( $(kubectl get secrets --no-headers -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 | wc -l) != 0 )); do echo -n .; sleep 5; wait_check "secrets removed"; done
echo
emit_event "secrets removed"

if [[ "$final_bd_count" == "$total_bd" ]]; then
  results_summary pass "final bundledeployment count equals $total_bd (no duplicates from controller resync)" "final bundledeployment count: $final_bd_count"
else
  results_summary fail "final bundledeployment count equals $total_bd (no duplicates from controller resync)" "final bundledeployment count: $final_bd_count"
fi
