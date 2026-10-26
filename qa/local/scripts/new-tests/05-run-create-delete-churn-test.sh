#!/bin/bash
# 05-run-create-delete-churn-test.sh
#
# Runs 01-run-baseline-scale-test.sh's create -> ready -> delete -> GC cycle back to
# back, printing etcd db size and orphaned-secret count after each cycle --
# a single cycle can't reveal a slow leak that only shows up after repeated
# churn. Also times each cycle (gitrepo created -> gitrepo ready, in
# seconds) so a run of degradation across cycles is directly visible
# instead of needing to subtract timestamps by hand.
#
# This is a sequential, multi-cycle LEAK-HUNTING test, not a race test --
# every cycle waits for full readiness before deleting, and for full GC
# before the next create, so create and delete never overlap. For the
# create/delete RACE (delete something still being created), see
# 06-run-single-bundle-create-delete-race-test.sh instead.
#
# Edit the values below directly before running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/results.sh"

# VER="0.16.0-rc.2"
VER="${VER:-$(cat "${SCRIPT_DIR%/*}/VERSION")}" # shared across all scripts, see scripts/VERSION

clusters=${CLUSTERS:-$(kubectl get clusters.fleet.cattle.io -n fleet-default --no-headers 2>/dev/null | wc -l)} # registered Fleet Clusters; override with CLUSTERS=N
agents=$clusters
bundles=50
churn_cycles=5 # how many create/delete cycles to run
cluster_ready="$clusters/$clusters"
test_bd=$((clusters * bundles))
total_bd=$((agents + test_bd))
test_bd_ready="$test_bd/$test_bd"

gitrepo_name="scale-50-single"
gitrepo_manifest="$SCRIPT_DIR/manifests/gitrepo-scale-50-bundles-baseline.yaml"

results_init 05_create_delete_churn "$VER"
echo "Clusters: $clusters"
echo "Bundles: $bundles"
echo "Churn cycles: $churn_cycles"
echo
emit_event "test parameters: clusters=$clusters bundles=$bundles churn_cycles=$churn_cycles"

cycle=1
while (( cycle <= churn_cycles )); do
  echo
  echo "=== cycle $cycle/$churn_cycles ==="

  cycle_start=$(date +%s)
  render_manifest "$gitrepo_manifest" | kubectl apply -f - -n fleet-default
  echo
  emit_event "cycle $cycle: created gitrepo"

  wait_start
  while (( $(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/repo-name=$gitrepo_name" 2>/dev/null | wc -l) != bundles )); do echo -n .; sleep 5; wait_check "cycle $cycle: bundles exist"; done
  echo
  emit_event "cycle $cycle: bundles exist"

  wait_start
  while (( $(kubectl get --no-headers --chunk-size=0 -A bundledeployments | wc -l) != total_bd )); do echo -n .; sleep 10; wait_check "cycle $cycle: bundledeployments exist"; done
  echo
  emit_event "cycle $cycle: bundledeployments exist"

  wait_start
  while (( $(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/repo-name=$gitrepo_name" | grep "$cluster_ready" | wc -l) != bundles )); do echo -n .; sleep 5; wait_check "cycle $cycle: bundles ready"; done
  echo
  emit_event "cycle $cycle: bundles ready"

  wait_start
  while ! kubectl get -n fleet-default gitrepo "$gitrepo_name" | grep -q "$test_bd_ready"; do echo -n .; sleep 5; wait_check "cycle $cycle: gitrepo ready"; done
  echo
  cycle_seconds=$(($(date +%s) - cycle_start))
  emit_event "cycle $cycle: gitrepo ready (created-to-ready: ${cycle_seconds}s)"

  kubectl delete -n fleet-default gitrepo "$gitrepo_name"
  echo

  wait_start "$DELETE_TIMEOUT_SECONDS"
  while (( $(kubectl get secrets --no-headers -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 | wc -l) != 0 )); do echo -n .; sleep 5; wait_check "cycle $cycle: secrets removed"; done
  echo
  emit_event "cycle $cycle: secrets removed"

  orphaned=$(kubectl get secrets --no-headers -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 2>/dev/null | wc -l)
  # Size of the upstream datastore: on k3d, k3s's embedded db read from the
  # server container; elsewhere (RKE2 on AWS), etcd's size from the apiserver
  # metrics. "unknown" if neither works.
  upstream_container=$(upstream_server_container)
  if [[ -n "$upstream_container" ]]; then
    etcd_size=$(docker exec "$upstream_container" du -sh /var/lib/rancher/k3s/server/db/ 2>/dev/null | awk '{print $1}' | tail -1)
  else
    etcd_size=$(kubectl get --raw /metrics 2>/dev/null | awk '/^apiserver_storage_size_bytes/ {printf "%.0f\n", $2}' | sort -g | tail -1 | numfmt --to=iec 2>/dev/null)
  fi
  emit_event "cycle $cycle: orphaned_secrets=$orphaned etcd_size=${etcd_size:-unknown}"

  cycle=$((cycle + 1))
done

results_summary pass \
  "$churn_cycles create/delete cycles complete without hanging, with etcd size/orphaned-secret metrics logged each cycle" \
  "completed $churn_cycles/$churn_cycles cycles"
