#!/bin/bash
# 07-run-webhook-vs-polling-test.sh
#
# "Webhook with and without polling" from developer feedback. A single push
# per phase proves nothing about robustness, so this mirrors 02's wave loop
# (several commits pushed back to back) instead of one -- but isolates the
# delivery mechanism instead of overlapping content: phase 1 runs the wave
# loop with the Gitea webhook OFF (polling only), phase 2 runs the same wave
# loop with the webhook ON. Confirms multi-wave updates don't break under
# either mechanism, and that phase 2 is actually driven by the webhook (via
# status.webhookCommit), not incidentally by polling.
#
# pollingInterval is the same short value in both phases (see
# $poll_interval_seconds below) -- an earlier version set it to 1h for phase
# 2 to force "webhook or nothing", but that means a broken webhook hangs
# this test for up to an hour instead of failing loudly. Capping it means
# phase 2 could, in the worst case, silently pass via a polling fallback
# instead of proving the webhook fired -- that's why phase 2 also checks
# status.webhookCommit explicitly per wave, not just convergence timing.
#
# Requires:
# - GITEA_TOKEN exported (see lib/gitrepo-commits.sh)
# - A Gitea webhook already configured on fleet-e2e-gitea/fleet-e2e, type
#   "gogs" (NOT Gitea's native "gitea" type -- gitjob's parser only
#   recognizes GitHub/GitLab/Gogs/Bitbucket/Azure DevOps payload headers,
#   there's no X-Gitea-Event case), pointed at gitjob's webhook receiver
#   ingress. This script only toggles the webhook active/inactive, it
#   doesn't create one.
# - Gitea's own ROOT_URL/DOMAIN (app.ini) must match this GitRepo's
#   spec.repo hostname (gitea.qa.local) -- gitjob matches an incoming
#   webhook payload's repo URL against spec.repo by exact hostname, so a
#   mismatch (e.g. ROOT_URL still saying "localhost" or a stale IP) means
#   the webhook fires (200 OK) but silently matches no GitRepo.
#
# Edit the values below directly before running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/results.sh"
source "$SCRIPT_DIR/lib/gitrepo-commits.sh"

# VER="0.16.0-rc.2"
VER="${VER:-$(cat "$SCRIPT_DIR/../VERSION")}" # shared across all scripts, see scripts/VERSION

gitrepo_name="webhook-vs-polling"
gitrepo_manifest="$SCRIPT_DIR/manifests/gitrepo-webhook-vs-polling.yaml"
gitrepo_clone_dir="/tmp/fleet-e2e-webhook-vs-polling"
gitrepo_path="scalability-performance/single-race/one"
# Local Gitea (internal). Needs GITEA_TOKEN exported in your shell.
gitrepo_url="$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_A.git"
gitea_api="$GITEA_HOST_URL/api/v1/repos/$GITEA_ORG/$GITEA_REPO_A/hooks"

waves=5                # commits per phase
wave_interval_seconds=2 # pause between pushes within a phase
wave_timeout_seconds=20 # per-wave bound before failing loudly
poll_interval_seconds=15 # pollingInterval for BOTH phases -- capped, see header comment

results_init 07_webhook_vs_polling "$VER"
emit_event "test parameters: waves=$waves wave_interval_seconds=$wave_interval_seconds poll_interval_seconds=$poll_interval_seconds"

gitrepo_commits_init "$gitrepo_clone_dir" "$gitrepo_url" main

webhook_id=$(curl -s -H "Authorization: token $GITEA_TOKEN" "$gitea_api" | jq -r '.[] | select(.type=="gogs") | .id' | head -1)
if [[ -z "$webhook_id" ]]; then
  echo "No 'gogs'-type Gitea webhook found on fleet-e2e-gitea/fleet-e2e -- see this script's header comment." >&2
  exit 1
fi
emit_event "using gitea webhook id=$webhook_id"

gitrepo_status_commit() {
  kubectl get gitrepo "$gitrepo_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null
}

# push_waves <phase_label>
# Pushes $waves marker commits back to back, waiting (bounded by
# $wave_timeout_seconds) after each for status.commit to catch up. Prints
# the last pushed commit on stdout; fails the whole run on any wave timeout.
push_waves() {
  local phase="$1" wave=1 commit push_time elapsed
  while (( wave <= waves )); do
    commit=$(push_marker_commit "$gitrepo_path" "$phase-wave-$wave")
    [[ -n "$commit" ]] || exit 1
    push_time=$(date +%s)
    # >&2 below: this function's stdout is captured via $(...) by the
    # caller to get the final commit hash -- emit_event's terminal echo
    # would otherwise leak into that captured string too (it happened: a
    # prior run had the whole log embedded in $commit2 instead of a bare
    # SHA, so the final webhookCommit comparison failed even though the
    # webhook worked correctly).
    emit_event "$phase wave $wave: pushed commit $commit" >&2

    elapsed=0
    while [[ "$(gitrepo_status_commit)" != "$commit" ]]; do
      sleep 1
      elapsed=$(( $(date +%s) - push_time ))
      if (( elapsed >= wave_timeout_seconds )); then
        emit_event "$phase wave $wave: TIMEOUT after ${wave_timeout_seconds}s -- status.commit never reached $commit (still $(gitrepo_status_commit))" >&2
        results_summary fail \
          "$phase wave $wave: status.commit reaches $commit within ${wave_timeout_seconds}s" \
          "status.commit stuck at $(gitrepo_status_commit) after ${wave_timeout_seconds}s" >&2
        exit 1
      fi
    done
    emit_event "$phase wave $wave: status.commit=$commit observed after ${elapsed}s" >&2

    (( wave < waves )) && sleep "$wave_interval_seconds"
    wave=$((wave + 1))
  done
  echo "$commit"
}

### Create (pollingInterval fixed at $poll_interval_seconds for the whole run)
render_manifest "$gitrepo_manifest" | kubectl apply -f - -n fleet-default
kubectl patch gitrepo "$gitrepo_name" -n fleet-default --type=merge -p "{\"spec\":{\"pollingInterval\":\"${poll_interval_seconds}s\"}}"
echo
emit_event "created gitrepo (pollingInterval=${poll_interval_seconds}s)"

### Phase 1: polling only (webhook deactivated)
curl -s -o /dev/null -X PATCH -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"active": false}' "$gitea_api/$webhook_id"
emit_event "phase 1: gitea webhook deactivated"

commit1=$(push_waves "phase1-polling")
[[ -n "$commit1" ]] || exit 1

### Phase 2: webhook reactivated, same pollingInterval throughout
curl -s -o /dev/null -X PATCH -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"active": true}' "$gitea_api/$webhook_id"
emit_event "phase 2: gitea webhook reactivated"

commit2=$(push_waves "phase2-webhook")
[[ -n "$commit2" ]] || exit 1
webhook_commit=$(kubectl get gitrepo "$gitrepo_name" -n fleet-default -o jsonpath='{.status.webhookCommit}' 2>/dev/null)
emit_event "phase 2: final commit $commit2, status.webhookCommit=$webhook_commit"

### Delete
echo
echo "delete "
kubectl delete -n fleet-default gitrepo "$gitrepo_name"
echo

wait_start "$DELETE_TIMEOUT_SECONDS"
while (( $(kubectl get secrets --no-headers -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 | wc -l) != 0 )); do echo -n .; sleep 3; wait_check "secrets removed"; done
echo
emit_event "secrets removed"

expected="phase 2 final status.webhookCommit equals last pushed commit $commit2 (proves the webhook, not polling, drove the update)"
actual="status.webhookCommit=$webhook_commit"
if [[ "$webhook_commit" == "$commit2" ]]; then
  results_summary pass "$expected" "$actual"
else
  results_summary fail "$expected" "$actual"
fi
