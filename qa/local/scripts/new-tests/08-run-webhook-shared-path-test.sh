#!/bin/bash
# 08-run-webhook-shared-path-test.sh
#
# "Webhook sharing the same path" from developer feedback: gitjob exposes a
# single webhook receiver for the whole cluster -- every GitRepo's webhook
# points at the exact same URL, there's no per-GitRepo receiver path.
# gitjob disambiguates which GitRepo(s) a given push affects by matching
# the webhook payload's repo URL against each GitRepo's spec.repo (see
# pkg/webhook/webhook.go in Fleet's source), not by the receiver URL. This
# test proves that disambiguation actually works: two distinct Gitea repos
# (fleet-e2e-gitea/fleet-e2e and .../fleet-e2e-2), each with its own
# GitRepo and its own webhook -- but both webhooks configured to hit the
# identical gitjob receiver URL -- and a push to one must not trigger the
# other.
#
# Pushes to A and B back to back with no wait in between, so both webhook
# deliveries actually land on gitjob's shared receiver close together --
# waiting for A to fully settle before pushing B (as an earlier version of
# this test did) never exercises the "shared path" part of the feedback at
# all, just sequential isolated pushes.
#
# Correctness is checked via each GitRepo's own status.webhookCommit, not
# status.commit -- if gitjob ever mis-routed A's webhook to also resync B,
# B would just re-fetch its own already-current HEAD (no new commit to
# fetch), so status.commit wouldn't visibly change either way. status.
# webhookCommit is only set when gitjob's webhook handler itself resynced
# that specific GitRepo, so it's the only field that actually catches a
# mis-route.
#
# Requires:
# - GITEA_TOKEN exported (see lib/gitrepo-commits.sh)
# - Both fleet-e2e-gitea/fleet-e2e and fleet-e2e-gitea/fleet-e2e-2 to exist
#   in the local Gitea, each with a "gogs"-type webhook (see 07's header
#   comment for why "gogs" and not Gitea's native "gitea" type) pointed at
#   gitjob's webhook receiver ingress. This script doesn't create the repos
#   or webhooks, only pushes to them.
# - Gitea's ROOT_URL/DOMAIN (app.ini) matching both GitRepos' spec.repo
#   hostname (gitea.qa.local) -- see 07's header comment.
#
# Edit the values below directly before running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/results.sh"
source "$SCRIPT_DIR/lib/gitrepo-commits.sh"

# VER="0.16.0-rc.2"
VER="${VER:-$(cat "$SCRIPT_DIR/../VERSION")}" # shared across all scripts, see scripts/VERSION

gitrepo_a_name="webhook-shared-path-a"
gitrepo_b_name="webhook-shared-path-b"
gitrepo_a_manifest="$SCRIPT_DIR/manifests/gitrepo-webhook-shared-path-a.yaml"
gitrepo_b_manifest="$SCRIPT_DIR/manifests/gitrepo-webhook-shared-path-b.yaml"
gitrepo_a_clone_dir="/tmp/fleet-e2e-shared-path-a"
gitrepo_b_clone_dir="/tmp/fleet-e2e-shared-path-b"
gitrepo_a_path="scalability-performance/single-race/one"
gitrepo_b_path="scalability-performance/single-race-b/one"
# Local Gitea (internal). Needs GITEA_TOKEN exported in your shell.
gitrepo_a_url="$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_A.git"
gitrepo_b_url="$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_B.git"
webhook_timeout=15
baseline_timeout=60

results_init 08_webhook_shared_path "$VER"
emit_event "test parameters: two GitRepos, two Gitea repos, webhooks sharing one gitjob receiver URL"

### Bump HEAD on both repos before (re)creating the GitRepos. gitjob tracks
### "last seen commit" per GitRepo namespace/name, not per object UID -- if a
### prior run's GitRepo (same name) was deleted while its last-known commit
### still matches this run's fresh object's first poll, gitjob silently never
### finishes reconciling the new object (no Job, status.commit stays empty
### forever). Pushing a throwaway commit first guarantees the new object's
### baseline poll always sees something gitjob hasn't already processed
### under that name.
gitrepo_commits_init "$gitrepo_a_clone_dir" "$gitrepo_a_url" main
push_marker_commit "$gitrepo_a_path" "shared-path-a-preflight" >/dev/null
gitrepo_commits_init "$gitrepo_b_clone_dir" "$gitrepo_b_url" main
push_marker_commit "$gitrepo_b_path" "shared-path-b-preflight" >/dev/null

### Create both GitRepos (pollingInterval: 1h baked into the manifests --
### any update within $webhook_timeout seconds can only be the webhook)
render_manifest "$gitrepo_a_manifest" | kubectl apply -f - -n fleet-default
render_manifest "$gitrepo_b_manifest" | kubectl apply -f - -n fleet-default
echo
emit_event "created both gitrepos (repo A: fleet-e2e, repo B: fleet-e2e-2)"

elapsed=0
while [[ -z "$(kubectl get gitrepo "$gitrepo_a_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null)" \
      || -z "$(kubectl get gitrepo "$gitrepo_b_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null)" ]]; do
  echo -n .
  sleep 1
  elapsed=$((elapsed + 1))
  if (( elapsed >= baseline_timeout )); then
    emit_event "TIMEOUT after ${baseline_timeout}s waiting for baseline status.commit -- repo A commit=$(kubectl get gitrepo "$gitrepo_a_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null || echo '<none>'), repo B commit=$(kubectl get gitrepo "$gitrepo_b_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null || echo '<none>')"
    # gitjob logs were never captured the one time this hung -- dump them now.
    kubectl logs -n cattle-fleet-system -l app=gitjob --tail=100 >&2
    results_summary fail \
      "both gitrepos report a baseline status.commit within ${baseline_timeout}s" \
      "repo A commit=$(kubectl get gitrepo "$gitrepo_a_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null || echo '<none>'), repo B commit=$(kubectl get gitrepo "$gitrepo_b_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null || echo '<none>')"
    exit 1
  fi
done
echo
baseline_a=$(kubectl get gitrepo "$gitrepo_a_name" -n fleet-default -o jsonpath='{.status.commit}')
baseline_b=$(kubectl get gitrepo "$gitrepo_b_name" -n fleet-default -o jsonpath='{.status.commit}')
baseline_webhook_a=$(kubectl get gitrepo "$gitrepo_a_name" -n fleet-default -o jsonpath='{.status.webhookCommit}' 2>/dev/null)
baseline_webhook_b=$(kubectl get gitrepo "$gitrepo_b_name" -n fleet-default -o jsonpath='{.status.webhookCommit}' 2>/dev/null)
emit_event "baseline: repo A commit=$baseline_a webhookCommit=${baseline_webhook_a:-<unset>}, repo B commit=$baseline_b webhookCommit=${baseline_webhook_b:-<unset>}"

### Push to A then immediately to B -- no wait in between, so both webhook
### deliveries land on gitjob's shared receiver close together instead of
### one at a time.
gitrepo_commits_init "$gitrepo_a_clone_dir" "$gitrepo_a_url" main
commit_a=$(push_marker_commit "$gitrepo_a_path" "shared-path-a")
[[ -n "$commit_a" ]] || exit 1
emit_event "pushed commit $commit_a to repo A"

gitrepo_commits_init "$gitrepo_b_clone_dir" "$gitrepo_b_url" main
commit_b=$(push_marker_commit "$gitrepo_b_path" "shared-path-b")
[[ -n "$commit_b" ]] || exit 1
emit_event "pushed commit $commit_b to repo B (immediately after A, no wait)"

elapsed=0
while [[ "$(kubectl get gitrepo "$gitrepo_a_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null)" != "$commit_a" \
       || "$(kubectl get gitrepo "$gitrepo_b_name" -n fleet-default -o jsonpath='{.status.commit}' 2>/dev/null)" != "$commit_b" ]]; do
  echo -n .
  sleep 1
  elapsed=$((elapsed + 1))
  (( elapsed >= webhook_timeout )) && break
done
echo

a_commit=$(kubectl get gitrepo "$gitrepo_a_name" -n fleet-default -o jsonpath='{.status.commit}')
b_commit=$(kubectl get gitrepo "$gitrepo_b_name" -n fleet-default -o jsonpath='{.status.commit}')
a_webhook_commit=$(kubectl get gitrepo "$gitrepo_a_name" -n fleet-default -o jsonpath='{.status.webhookCommit}' 2>/dev/null)
b_webhook_commit=$(kubectl get gitrepo "$gitrepo_b_name" -n fleet-default -o jsonpath='{.status.webhookCommit}' 2>/dev/null)
emit_event "after concurrent pushes: repo A commit=$a_commit webhookCommit=$a_webhook_commit (expected both $commit_a), repo B commit=$b_commit webhookCommit=$b_webhook_commit (expected both $commit_b)"

### Delete
echo
echo "delete "
kubectl delete -n fleet-default gitrepo "$gitrepo_a_name" "$gitrepo_b_name"
echo

wait_start "$DELETE_TIMEOUT_SECONDS"
while (( $(kubectl get secrets --no-headers -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 | wc -l) != 0 )); do echo -n .; sleep 3; wait_check "secrets removed"; done
echo
emit_event "secrets removed"

expected="repo A's own commit and webhookCommit both equal $commit_a (its own push), repo B's own commit and webhookCommit both equal $commit_b (its own push) -- neither reflects the other's payload"
actual="repo A: commit=$a_commit webhookCommit=$a_webhook_commit; repo B: commit=$b_commit webhookCommit=$b_webhook_commit"
if [[ "$a_commit" == "$commit_a" && "$a_webhook_commit" == "$commit_a" \
   && "$b_commit" == "$commit_b" && "$b_webhook_commit" == "$commit_b" ]]; then
  results_summary pass "$expected" "$actual"
else
  results_summary fail "$expected" "$actual"
fi
