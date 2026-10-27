#!/bin/bash
# 04-run-heavy-content-race-test.sh
#
# The "race by weight" scenario from developer feedback: upload something
# heavy (a real Grafana chart, via Fleet's native helm.repo support -- no
# chart vendored into git, so the git repo itself stays tiny while what
# Fleet actually reconciles is real and heavy), delete it while it's still
# rolling out, then upload again immediately -- so the second create
# overlaps the first delete's still-in-progress garbage collection, instead
# of 02's overlap (which is push-vs-push on a lightweight nginx bundle, no
# delete involved).
#
# Single bundle (scalability-performance/heavy-race/grafana) across all
# $clusters clusters, not the 50-bundle set -- this test is about reconcile
# weight and delete/create overlap, not bundle count.
#
# Edit the values below directly before running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/results.sh"
source "$SCRIPT_DIR/lib/gitrepo-commits.sh"

# VER="0.16.0-rc.2"
VER="${VER:-$(cat "${SCRIPT_DIR%/*}/../../VERSION")}" # shared across all scripts, see qa/VERSION

clusters=${CLUSTERS:-$(kubectl get clusters.fleet.cattle.io -n fleet-default --no-headers 2>/dev/null | wc -l)} # registered Fleet Clusters; override with CLUSTERS=N
bundles=1
test_bd=$((clusters * bundles))
test_bd_ready="$test_bd/$test_bd"

gitrepo_name="heavy-race"
gitrepo_manifest="$SCRIPT_DIR/manifests/gitrepo-heavy-race.yaml"
gitrepo_clone_dir="/tmp/fleet-e2e-heavy-race"
gitrepo_path="scalability-performance/heavy-race/grafana"
# Local Gitea (internal). Needs GITEA_TOKEN exported in your shell for the
# push side -- see lib/gitrepo-commits.sh. The in-cluster fetch side is
# separate, see manifests/gitrepo-heavy-race.yaml's comment.
gitrepo_url="$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_A.git"

results_init 04_heavy_content_race "$VER"
echo "Clusters: $clusters"
echo "Bundles: $bundles (heavy: real Grafana chart via helm.repo)"
echo
emit_event "test parameters: clusters=$clusters bundles=$bundles"

gitrepo_commits_init "$gitrepo_clone_dir" "$gitrepo_url" main

### First upload
commit1=$(push_marker_commit "$gitrepo_path" "heavy-race-1")
[[ -n "$commit1" ]] || exit 1
render_manifest "$gitrepo_manifest" | kubectl apply -f - -n fleet-default
echo
emit_event "created gitrepo (commit $commit1)"

# Wait until BundleDeployments exist (chart pull started) but deliberately
# don't wait for ready -- Grafana's real image pull + startup takes long
# enough that this reliably still be mid-rollout when the delete below
# fires, which is the point (deleting something "still uploading").
wait_start
while (( $(kubectl get --no-headers --chunk-size=0 -A bundledeployments -l "fleet.cattle.io/repo-name=$gitrepo_name" 2>/dev/null | wc -l) != test_bd )); do echo -n .; sleep 2; wait_check "bundledeployments exist for commit $commit1 (still rolling out, not waiting for ready)"; done
echo
emit_event "bundledeployments exist for commit $commit1 (still rolling out, not waiting for ready)"

### Delete while still uploading, then immediately re-upload -- the two
### operations deliberately overlap instead of waiting for the delete's GC
### to finish first (that would just be 05's sequential churn).
kubectl delete -n fleet-default gitrepo "$gitrepo_name" --wait=false
echo
emit_event "deleted gitrepo mid-rollout (commit $commit1 not yet ready)"

commit2=$(push_marker_commit "$gitrepo_path" "heavy-race-2")
[[ -n "$commit2" ]] || exit 1

# The old GitRepo (same name) may still be terminating (finalizers pending
# -- deleting a Grafana release mid-install isn't instant), in which case
# `kubectl apply` just no-ops against the terminating object instead of
# creating a new one -- retry until a genuinely live (no deletionTimestamp)
# object exists, instead of assuming one apply is enough.
wait_start
until render_manifest "$gitrepo_manifest" | kubectl apply -f - -n fleet-default >/dev/null \
  && [[ -z "$(kubectl get gitrepo "$gitrepo_name" -n fleet-default -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]] \
  && kubectl get gitrepo "$gitrepo_name" -n fleet-default >/dev/null 2>&1; do
  echo -n .
  sleep 1
  wait_check "re-created gitrepo is live"
done
echo
emit_event "re-created gitrepo (commit $commit2) after commit $commit1's delete finished (or overlapped, if the first apply attempt already landed live)"

### Wait for the second upload to fully converge
wait_start
while ! kubectl get -n fleet-default gitrepo "$gitrepo_name" 2>/dev/null | grep -q "$test_bd_ready"; do echo -n .; sleep 5; wait_check "gitrepo ready on commit $commit2 ($test_bd_ready bundledeployments ready)"; done
echo
emit_event "gitrepo ready on commit $commit2 ($test_bd_ready bundledeployments ready)"

### Correctness checks: no duplicate/orphaned BundleDeployments left from
### the deleted first attempt, and the GitRepo reflects the latest commit.
final_bd_count=$(kubectl get --no-headers --chunk-size=0 -A bundledeployments -l "fleet.cattle.io/repo-name=$gitrepo_name" | wc -l)
final_status_commit=$(kubectl get gitrepo "$gitrepo_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null)
emit_event "final bundledeployment count: $final_bd_count (expected $test_bd), gitrepo status.commit=$final_status_commit (expected $commit2)"
emit_metric bundledeployments_final "$final_bd_count" count

stale_from_first_upload=$(kubectl get bundledeployments -A -l "fleet.cattle.io/commit=$commit1" --no-headers 2>/dev/null | wc -l)
emit_event "bundledeployments still pointing at deleted commit $commit1: $stale_from_first_upload"
emit_metric bundledeployments_on_deleted_commit "$stale_from_first_upload" count

### Delete
echo
echo "delete "
kubectl delete -n fleet-default gitrepo "$gitrepo_name"
echo

wait_start "$DELETE_TIMEOUT_SECONDS"
while (( $(kubectl get secrets --no-headers -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 | wc -l) != 0 )); do echo -n .; sleep 5; wait_check "secrets removed"; done
echo
emit_event "secrets removed"

expected="final bundledeployment count=$test_bd, gitrepo status.commit=$commit2, 0 bundledeployments left on deleted commit $commit1"
actual="final bundledeployment count=$final_bd_count, status.commit=$final_status_commit, stale-on-$commit1=$stale_from_first_upload"
if [[ "$final_bd_count" == "$test_bd" && "$final_status_commit" == "$commit2" && "$stale_from_first_upload" == "0" ]]; then
  results_summary pass "$expected" "$actual"
else
  results_summary fail "$expected" "$actual"
fi
