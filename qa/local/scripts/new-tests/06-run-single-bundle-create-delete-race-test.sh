#!/bin/bash
# 06-run-single-bundle-create-delete-race-test.sh
#
# NOTE: in practice this is a HEALTHCHECK, not a real race exerciser. The
# Bundle only exists for a few seconds and no BundleDeployments have been
# created yet when the delete lands, so there's nothing partially-applied
# for GC to trip over -- clean teardown here isn't a surprising result. Kept
# as a cheap smoke test (create -> delete before BDs exist -> no orphaned
# Bundle/BundleDeployments/secrets, controller still healthy), not as
# evidence of race-condition coverage. A real race would need to delete
# *after* BundleDeployments exist and are actively rolling out.
#
# Originally written for the "create 1 bundle and delete a bundle" race from
# developer feedback -- not covered by 05 (which only ever deletes a
# fully-converged, fully-ready GitRepo). This test creates a single,
# dedicated, lightweight bundle (scalability-performance/single-race/one --
# not part of the shared scale-50-bundles set, so it can't interfere with
# 02's mutations there), then deletes it as soon as the Bundle resource
# exists -- before BundleDeployments are even created.
#
# Edit the values below directly before running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/results.sh"

# VER="0.16.0-rc.2"
VER="${VER:-$(cat "$SCRIPT_DIR/../VERSION")}" # shared across all scripts, see scripts/VERSION

clusters=${CLUSTERS:-$(kubectl get clusters.fleet.cattle.io -n fleet-default --no-headers 2>/dev/null | wc -l)} # registered Fleet Clusters; override with CLUSTERS=N
bundles=1

gitrepo_name="single-race"
gitrepo_manifest="$SCRIPT_DIR/manifests/gitrepo-single-race.yaml"

results_init 06_single_bundle_create_delete_race "$VER"
echo "Clusters: $clusters"
echo "Bundles: $bundles"
echo
emit_event "test parameters: clusters=$clusters bundles=$bundles"

### Create
render_manifest "$gitrepo_manifest" | kubectl apply -f - -n fleet-default
echo
emit_event "created gitrepo"

# Deliberately weak gate: only wait for the Bundle resource to exist, NOT
# for its BundleDeployments or readiness -- the delete below needs to land
# while creation is still in flight, not after it's settled.
wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/repo-name=$gitrepo_name" 2>/dev/null | wc -l) != bundles )); do echo -n .; sleep 1; wait_check "bundle exists (BundleDeployments not necessarily created yet)"; done
echo
emit_event "bundle exists (BundleDeployments not necessarily created yet)"

### Delete immediately -- overlapping the still-in-flight create
kubectl delete -n fleet-default gitrepo "$gitrepo_name" --wait=false
echo
emit_event "deleted gitrepo immediately after bundle creation (deliberately racing the create)"

wait_start "$DELETE_TIMEOUT_SECONDS"
while (( $(kubectl get secrets --no-headers -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 | wc -l) != 0 )); do echo -n .; sleep 2; wait_check "secrets removed"; done
echo
emit_event "secrets removed"

### Correctness checks: no leftover Bundle, no leftover BundleDeployments,
### and the fleet-controller is still up (the race didn't crash it).
leftover_bundles=$(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/repo-name=$gitrepo_name" 2>/dev/null | wc -l)
leftover_bd=$(kubectl get --no-headers --chunk-size=0 -A bundledeployments -l "fleet.cattle.io/repo-name=$gitrepo_name" 2>/dev/null | wc -l)
controller_ready=$(kubectl get pods -n cattle-fleet-system -l app=fleet-controller -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
emit_event "leftover bundles=$leftover_bundles leftover bundledeployments=$leftover_bd fleet-controller ready=$controller_ready"

expected="0 leftover bundles, 0 leftover bundledeployments, fleet-controller ready=true after delete-during-create"
actual="leftover bundles=$leftover_bundles, leftover bundledeployments=$leftover_bd, controller ready=$controller_ready"
if [[ "$leftover_bundles" == "0" && "$leftover_bd" == "0" && "$controller_ready" == "true" ]]; then
  results_summary pass "$expected" "$actual"
else
  results_summary fail "$expected" "$actual"
fi
