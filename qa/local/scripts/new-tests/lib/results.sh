#!/bin/bash
# lib/results.sh
#
# Minimal structured-output helper. Every scenario script still reads
# top-to-bottom (plain "kubectl ... ; while ... ;
# echo -n 'x: '; date" blocks) -- the only change is swapping that
# echo+date line for emit_event, which does the same thing on your
# terminal AND appends one JSON line to a .jsonl file, so results can be
# parsed later without regex-scraping prose (see ../../testresults/).
#
# Usage:
#   source "$(dirname "$0")/lib/results.sh"
#   results_init <scenario> <fleet_version>
#   emit_event "bundles ready"     # prints "bundles ready: <date>", like
#                                   # the original script, and appends
#                                   # {"ts":...,"event":"bundles ready"}
#   results_finish <PASSED|FAILED|ERROR>

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

RESULTS_FILE=""
RESULTS_SUMMARY_WRITTEN=""
RESULTS_CONTEXT="{}"

results_init() {
  local scenario="$1" fleet_version="$2"
  local run_id dir

  # Fail fast and loud if kubectl isn't actually pointed at this project's
  # Fleet cluster -- without this, a missing/wrong KUBECONFIG (e.g. a fresh
  # shell where it was never exported) makes kubectl silently fall back to
  # whatever's in ~/.kube/config, which can be a totally unrelated, possibly
  # offline cluster. Every subsequent kubectl call in these scripts would
  # then just look empty/unreachable forever, with nothing to explain why.
  if ! kubectl get namespace cattle-fleet-system >/dev/null 2>&1; then
    echo "[new-tests] ERROR: kubectl cannot reach this project's Fleet cluster (namespace cattle-fleet-system not found)." >&2
    echo "[new-tests] Current kubectl context: $(kubectl config current-context 2>&1)" >&2
    echo "[new-tests] Is KUBECONFIG exported in this shell? From qa/local/ or qa/aws/: export KUBECONFIG=\"\$PWD/default_config/upstream.yaml\"" >&2
    exit 1
  fi

  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  # One folder per Fleet version and day: testresults/<fleet version>_<local date>/<scenario>.jsonl,
  # whether the tests run one by one or through run-all.sh.
  dir="${RESULTS_RUN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/testresults/${fleet_version}_$(date +%Y-%m-%d)}"
  mkdir -p "$dir"
  RESULTS_FILE="$dir/${scenario}.jsonl"
  # Same test run again that day: keep both, the later one with its start time.
  [[ -e "$RESULTS_FILE" ]] && RESULTS_FILE="$dir/${scenario}_$(date +%H-%M-%S).jsonl"
  RESULTS_CONTEXT=$(_results_context "$scenario" "$fleet_version" "$run_id")
  echo "Scenario: $scenario"
  echo "Fleet Version: $fleet_version"
  echo "Results file: $RESULTS_FILE"
  echo "Context: $RESULTS_CONTEXT"
  echo
  # VER only names the file -- what actually ran is the controller image.
  local installed
  installed=$(jq -r .fleet_controller_image <<<"$RESULTS_CONTEXT")
  if [[ "${installed##*:v}" != "$fleet_version" ]]; then
    echo "[new-tests] WARNING: VER=$fleet_version but installed fleet-controller is $installed" >&2
  fi
  echo -n "run started: "; date
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ctx "$RESULTS_CONTEXT" \
    '{ts: $ts, event: "run started"} + $ctx' >>"$RESULTS_FILE"

  # Every run must end with exactly one {"event":"summary"} line, even when
  # a script bails out early (plain `exit 1`, Ctrl-C, `timeout` killing it)
  # -- otherwise the jsonl has no pass/fail verdict at all.
  trap '_results_on_exit $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  _results_delete_leftover_gitrepos
}

# Deletes every GitRepo left in fleet-default by an earlier run (a failed run
# exits before its own delete step). Any leftover counts, not just this
# test's own: several tests count bundledeployments/secrets cluster-wide, so
# someone else's GitRepo makes their wait loops never match.
_results_delete_leftover_gitrepos() {
  local leftovers
  leftovers=$(kubectl get gitrepo -n fleet-default -o name 2>/dev/null)
  if [[ -n "$leftovers" ]]; then
    emit_event "deleting leftover gitrepos from a previous run: $(echo $leftovers)"
    # shellcheck disable=SC2086 # one arg per GitRepo
    kubectl delete -n fleet-default $leftovers --wait=false
  fi
  # Checked even when no GitRepo was left: a GitRepo can be gone while its
  # bundles/bundledeployments are still being cleaned up. Only resources with
  # the fleet.cattle.io/repo-name label count, so the per-cluster fleet-agent
  # bundles (always present) are ignored.
  wait_start "$DELETE_TIMEOUT_SECONDS"
  while [[ -n "$(kubectl get gitrepo -n fleet-default -o name 2>/dev/null)" \
        || -n "$(kubectl get bundles -n fleet-default -l fleet.cattle.io/repo-name -o name 2>/dev/null)" \
        || -n "$(kubectl get bundledeployments -A -l fleet.cattle.io/repo-name -o name 2>/dev/null)" \
        || -n "$(kubectl get secrets -A --field-selector type=fleet.cattle.io/bundle-deployment/v1alpha1 -o name 2>/dev/null)" ]]; do
    echo -n .; sleep 3
    wait_check "leftover gitrepos, bundles, bundledeployments and their secrets fully gone"
  done
  [[ -n "$leftovers" ]] && { echo; emit_event "leftover gitrepos fully gone (gitrepos, bundles, bundledeployments, secrets)"; }
  return 0
}

# _results_on_exit and results_summary below both rely on these; the test
# parameters ($clusters, $bundles, $test_bd) are read from the calling script,
# which sets them before results_init (empty when a script doesn't use them).
_results_context() {
  local scenario="$1" fleet_version="$2" run_id="$3"
  jq -nc \
    --arg scenario "$scenario" \
    --arg run_id "$run_id" \
    --arg fleet_version "$fleet_version" \
    --arg fleet_controller_image "$(kubectl get deploy fleet-controller -n cattle-fleet-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" \
    --arg fleet_agent_versions "$(kubectl get clusters.fleet.cattle.io -A -o jsonpath='{range .items[*]}{.status.agent.version}{"\n"}{end}' 2>/dev/null | sort -u | paste -sd, -)" \
    --arg upstream_k8s_version "$(kubectl version -o json 2>/dev/null | jq -r .serverVersion.gitVersion)" \
    --arg clusters_registered "$(kubectl get clusters.fleet.cattle.io -n fleet-default --no-headers 2>/dev/null | wc -l)" \
    --arg clusters "${clusters:-}" \
    --arg bundles "${bundles:-}" \
    --arg expected_bundledeployments "${test_bd:-${clusters:+${bundles:+$(( clusters * bundles ))}}}" \
    '{scenario: $scenario, run_id: $run_id, fleet_version: $fleet_version,
      fleet_controller_image: $fleet_controller_image, fleet_agent_versions: $fleet_agent_versions,
      upstream_k8s_version: $upstream_k8s_version,
      clusters_registered: ($clusters_registered | tonumber? // null),
      clusters: ($clusters | tonumber? // null), bundles: ($bundles | tonumber? // null),
      expected_bundledeployments: ($expected_bundledeployments | tonumber? // null)}'
}

_results_on_exit() {
  local rc="$1"
  [[ -n "$RESULTS_SUMMARY_WRITTEN" ]] && return
  results_summary error "script reaches its own pass/fail check" "exited early with code $rc, no pass/fail verdict (see terminal output)"
}

# wait_start [seconds] / wait_check <what>
# Bounds a plain `while ...; do echo -n .; sleep N; done` wait loop: call
# wait_start right before the loop and wait_check inside it. After the limit
# the run fails with a summary instead of hanging. Limit: wait_start's
# argument if given (deletion waits pass $DELETE_TIMEOUT_SECONDS), else
# $WAIT_TIMEOUT_SECONDS. Both can be overridden per run, e.g.
# WAIT_TIMEOUT_SECONDS=1800 ./scripts/new-tests/01-...sh
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"
DELETE_TIMEOUT_SECONDS="${DELETE_TIMEOUT_SECONDS:-480}"
wait_start() {
  WAIT_LIMIT="${1:-$WAIT_TIMEOUT_SECONDS}"
  WAIT_DEADLINE=$((SECONDS + WAIT_LIMIT))
}
wait_check() {
  (( SECONDS < WAIT_DEADLINE )) && return
  echo
  emit_event "TIMEOUT after ${WAIT_LIMIT}s waiting for: $1"
  results_summary fail "$1 within ${WAIT_LIMIT}s" "timed out after ${WAIT_LIMIT}s"
  exit 1
}

# emit_event <description>
# Prints "<description>: <date>" to the terminal (exactly like the
# "echo -n 'foo: '; date" lines used in the scripts), and appends one
# {"ts":...,"event":"<description>"} line to $RESULTS_FILE.
emit_event() {
  local description="$1"
  echo -n "$description: "
  date
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$description" \
    '{ts: $ts, event: $event}' >>"$RESULTS_FILE"
}

results_finish() {
  local status="$1"
  emit_event "run finished ($status)"
}

# results_summary <pass|fail|error> <expected> <actual>
# Prints an EXPECTED/RESULT/STATUS block to the terminal (so a run's outcome
# is readable without grepping the jsonl for the final pass/fail condition),
# appends the same as one {"event":"summary",...} line (plus the run context:
# fleet version, image, clusters, ... -- so this one line is enough), then calls
# results_finish.
results_summary() {
  local status="$1" expected="$2" actual="$3"
  local label="FAILED"
  [[ "$status" == "pass" ]] && label="PASSED"
  [[ "$status" == "error" ]] && label="ERROR"
  RESULTS_SUMMARY_WRITTEN=1
  echo
  echo "EXPECTED: $expected"
  echo "RESULT:   $actual"
  echo "STATUS:   $label"
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg expected "$expected" --arg actual "$actual" --arg status "$label" \
    --argjson ctx "$RESULTS_CONTEXT" \
    '{ts: $ts, event: "summary", status: $status, expected: $expected, actual: $actual} + $ctx' >>"$RESULTS_FILE"
  results_finish "$label"
}
