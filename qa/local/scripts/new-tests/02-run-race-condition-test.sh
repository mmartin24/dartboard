#!/bin/bash
# 02-run-race-condition-test.sh
#
# Same shape as 01-run-baseline-scale-test.sh, plus one twist: instead of pushing one
# commit and waiting for it to fully roll out, this pushes RACE_WAVES
# commits back to back, each one waiting only until the commit hash is
# found on all 50 bundles (not fully ready) before the next one is pushed
# -- so the pushes deliberately overlap an in-flight rollout. Each commit
# bumps the image on a real nginx Deployment (bundle "one"), forcing an
# actual rolling pod restart across all target clusters -- not a no-op
# ConfigMap tweak, which converged too fast to measure anything. After the
# last wave, there's an explicit check that all 50 bundles become fully
# ready (not just found) on the final commit, then that Fleet converged
# cleanly overall: no BundleDeployment left behind still pointing at an
# earlier commit. Convergence progress is logged periodically throughout,
# not just as a single before/after snapshot.
#
# Every wave (not just the last one) also logs: the GitRepo's own
# .status.commit (proving the new commit is actually picked up and
# reflected on the GitRepo object itself, not just on the bundles), and the
# current count of stale BundleDeployments still pointing at any earlier
# commit -- so a cluster/bundle that falls behind and never catches up
# shows up in the per-wave log instead of only being caught by the
# once-at-the-end check.
#
# Edit the values below directly before running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/results.sh"
source "$SCRIPT_DIR/lib/gitrepo-commits.sh"

# VER="0.16.0-rc.2"
VER="${VER:-$(cat "${SCRIPT_DIR%/*}/../../VERSION")}" # shared across all scripts, see qa/VERSION

clusters=${CLUSTERS:-$(kubectl get clusters.fleet.cattle.io -n fleet-default --no-headers 2>/dev/null | wc -l)} # registered Fleet Clusters; override with CLUSTERS=N
bundles=50
race_waves=8            # how many commits to push back to back
race_interval_seconds=5 # pause between pushes

gitrepo_name="scale-50-race"
gitrepo_manifest="$SCRIPT_DIR/manifests/gitrepo-scale-50-bundles-race.yaml"
gitrepo_clone_dir="/tmp/fleet-e2e-race"
# Path to bundle "one"'s fleet.yaml specifically (not the "ten" path root --
# writing a loose file there creates a stray 51st bundle, see the crash
# this caused earlier). Bundle "one" has a real nginx Deployment templated
# on .Values.image, so bumping the image here (push_image_bump) forces an
# actual rolling pod restart on every target cluster -- not a no-op
# ConfigMap tweak, which never took measurable time to converge.
gitrepo_path="scalability-performance/scale-50-bundles/ten/one/fleet.yaml"
image_tags=(nginx:1.25 nginx:1.26 nginx:1.27) # cycled across waves
# Your Gitea (see lib/config.sh). Push side (this script, runs on your machine)
# needs GITEA_TOKEN exported in your shell -- see lib/gitrepo-commits.sh.
# The in-cluster fetch side (GitRepo's spec.repo) uses a different address
# -- see manifests/gitrepo-scale-50-bundles-race.yaml's comment.
gitrepo_url="$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_A.git"

test_bd=$((clusters * bundles))
test_bd_ready="$test_bd/$test_bd"

results_init 02_race_condition "$VER"
echo "Clusters: $clusters"
echo "Bundles: $bundles"
echo "Waves: $race_waves"
echo
emit_event "test parameters: clusters=$clusters bundles=$bundles waves=$race_waves"

gitrepo_commits_init "$gitrepo_clone_dir" "$gitrepo_url" main

### Create
render_manifest "$gitrepo_manifest" | kubectl apply -f - -n fleet-default
echo
emit_event "created gitrepo"

# How many of the $bundles bundles are fully rolled out (ready ==
# desiredReady) *for the given commit specifically* -- scoped by commit so
# a bundle still ready on an OLDER commit doesn't count as done. Used both
# as the wave-advance gate and to log a convergence curve over time instead
# of a single before/after snapshot.
bundles_fully_ready_count_for_commit() {
  local commit="$1"
  kubectl get bundle -n fleet-default -l "fleet.cattle.io/repo-name=$gitrepo_name,fleet.cattle.io/commit=$commit" -o json 2>/dev/null \
    | jq '[.items[] | select(.status.summary.ready == .status.summary.desiredReady and .status.summary.desiredReady > 0)] | length'
}

# BundleDeployments anywhere still pointing at a commit other than the one
# given -- used per-wave (not just once at the very end) so a cluster/bundle
# that falls behind and never catches up shows up in the log as soon as the
# next wave lands, not only in the final summary.
stale_bundledeployment_count_excluding() {
  local current_commit="$1"
  kubectl get bundledeployments -A -l "fleet.cattle.io/commit,fleet.cattle.io/commit!=$current_commit" --no-headers 2>/dev/null | wc -l
}

# Named bundles for this GitRepo that do NOT yet report the given commit --
# used on timeout to say exactly which bundle(s) are stuck instead of just
# a bare, unexplained count.
bundles_not_on_commit() {
  local commit="$1"
  kubectl get bundle -n fleet-default -l "fleet.cattle.io/repo-name=$gitrepo_name" -o json 2>/dev/null \
    | jq -r --arg c "$commit" '.items[] | select(.metadata.labels["fleet.cattle.io/commit"] != $c) | .metadata.name'
}

# How long to wait (seconds) before giving up and failing loudly with
# diagnostics, instead of looping forever if a bundle never catches up.
wave_found_timeout=180
final_ready_timeout=300

# commits[1]=first pushed commit, commits[2]=second, etc.
commits=()
wave=1
while (( wave <= race_waves )); do
  image="${image_tags[$(( (wave - 1) % ${#image_tags[@]} ))]}"
  commit=$(push_image_bump "$gitrepo_path" "$image")
  [[ -n "$commit" ]] || exit 1
  commits+=("$commit")
  echo
  emit_event "wave $wave: pushed commit $commit (image=$image)"

  # Deliberately weak signal: the commit hash just needs to be FOUND on all
  # $bundles bundles (not ready yet) -- this is what lets the next wave's
  # push overlap the in-flight rollout. Sampled periodically (not silent
  # dots) so the convergence curve up to this point is visible. Bounded by
  # $wave_found_timeout -- without a bound, a bundle that never catches up
  # (a real possible finding, not just noise) would hang this loop forever
  # with no explanation.
  elapsed=0
  found=$(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/commit=$commit" 2>/dev/null | wc -l)
  while (( found != bundles )); do
    emit_event "wave $wave: commit $commit found on $found/$bundles bundles ($(bundles_fully_ready_count_for_commit "$commit")/$bundles fully ready)"
    sleep 3
    elapsed=$((elapsed + 3))
    if (( elapsed >= wave_found_timeout )); then
      stuck=$(bundles_not_on_commit "$commit" | tr '\n' ' ')
      emit_event "wave $wave: TIMEOUT after ${wave_found_timeout}s -- commit $commit never found on all $bundles bundles. Still stuck: $stuck"
      results_summary fail \
        "wave $wave: commit $commit found on all $bundles bundles within ${wave_found_timeout}s" \
        "found on $found/$bundles bundles, still stuck: $stuck"
      exit 1
    fi
    found=$(kubectl get --no-headers --chunk-size=0 -n fleet-default bundle -l "fleet.cattle.io/commit=$commit" 2>/dev/null | wc -l)
  done
  echo
  emit_event "wave $wave: commit $commit found on $found/$bundles bundles ($(bundles_fully_ready_count_for_commit "$commit")/$bundles fully ready) -- all $bundles bundles matched"

  gitrepo_status_commit=$(kubectl get gitrepo "$gitrepo_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null)
  stale_count=$(stale_bundledeployment_count_excluding "$commit")
  if (( stale_count == 0 )); then
    emit_event "wave $wave: gitrepo status.commit=$gitrepo_status_commit (pushed $commit) -- 0 bundledeployments stale, all already on this commit"
  else
    emit_event "wave $wave: gitrepo status.commit=$gitrepo_status_commit (pushed $commit) -- $stale_count bundledeployment(s) still on an older commit (expected mid-race; only a real problem if still nonzero after the final wave)"
  fi

  if (( wave < race_waves )); then
    sleep "$race_interval_seconds"
  fi
  wave=$((wave + 1))
done

final_commit="${commits[-1]}"

# Explicit final check for the last wave: unlike the per-wave loop above
# (which only waits for the commit to be *found*), this waits until all
# $bundles bundles are FULLY ready on the final commit -- bundle "one" now
# has an actual Deployment, so this can take real time (image pull + pod
# ready across 50 clusters). Sampled periodically to log the convergence
# curve instead of silent dots.
elapsed=0
ready_now=$(bundles_fully_ready_count_for_commit "$final_commit")
while (( ready_now != bundles )); do
  emit_event "wave $race_waves final check: commit $final_commit at $ready_now/$bundles bundles fully ready"
  sleep 5
  elapsed=$((elapsed + 5))
  if (( elapsed >= final_ready_timeout )); then
    not_ready=$(kubectl get bundle -n fleet-default -l "fleet.cattle.io/repo-name=$gitrepo_name,fleet.cattle.io/commit=$final_commit" -o json 2>/dev/null \
      | jq -r '.items[] | select(.status.summary.ready != .status.summary.desiredReady) | .metadata.name' | tr '\n' ' ')
    emit_event "wave $race_waves final check: TIMEOUT after ${final_ready_timeout}s -- never reached $bundles/$bundles fully ready. Still not ready: $not_ready"
    results_summary fail \
      "wave $race_waves final check: all $bundles bundles fully ready for commit $final_commit within ${final_ready_timeout}s" \
      "ready $ready_now/$bundles, still not ready: $not_ready"
    exit 1
  fi
  ready_now=$(bundles_fully_ready_count_for_commit "$final_commit")
done
echo
emit_event "wave $race_waves final check: all $bundles/$bundles bundles fully ready for commit $final_commit"

# Bounded too, even though every bundle already reported fully ready above
# -- this is just the GitRepo object's own aggregate catching up, which
# should be near-instant, but "should be" isn't "provably bounded".
elapsed=0
gitrepo_ready_timeout=60
while ! kubectl get -n fleet-default gitrepo "$gitrepo_name" | grep -q "$test_bd_ready"; do
  echo -n .
  sleep 5
  elapsed=$((elapsed + 5))
  if (( elapsed >= gitrepo_ready_timeout )); then
    echo
    emit_event "TIMEOUT after ${gitrepo_ready_timeout}s -- gitrepo never reported $test_bd_ready bundledeployments ready despite all bundles individually ready"
    results_summary fail \
      "gitrepo reports $test_bd_ready bundledeployments ready within ${gitrepo_ready_timeout}s of all bundles individually ready" \
      "gitrepo not yet reporting $test_bd_ready after ${gitrepo_ready_timeout}s"
    exit 1
  fi
done
echo
emit_event "gitrepo ready on final commit $final_commit ($bundles/$bundles bundles ok, $test_bd_ready bundledeployments ready)"

### Final checks: GitRepo status.commit matches the last pushed commit, and
### no BundleDeployment anywhere is still pointing at an earlier one.
final_status_commit=$(kubectl get gitrepo "$gitrepo_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null)
emit_event "final check: gitrepo status.commit=$final_status_commit (expected $final_commit)"

stale_total=$(stale_bundledeployment_count_excluding "$final_commit")
echo
emit_event "stale bundledeployments from superseded commits: $stale_total"
emit_metric stale_bundledeployments "$stale_total" count

### Delete
echo
echo "delete "
kubectl delete -n fleet-default gitrepo "$gitrepo_name"
echo

wait_start "$DELETE_TIMEOUT_SECONDS"
while (( $(kubectl get secrets --no-headers -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 | wc -l) != 0 )); do echo -n .; sleep 5; wait_check "secrets removed"; done
echo
emit_event "secrets removed"

expected="after $race_waves waves: 0 stale bundledeployments and gitrepo status.commit=$final_commit"
actual="stale bundledeployments=$stale_total, gitrepo status.commit=$final_status_commit"
if [[ "$stale_total" == "0" && "$final_status_commit" == "$final_commit" ]]; then
  results_summary pass "$expected" "$actual"
else
  results_summary fail "$expected" "$actual"
fi
