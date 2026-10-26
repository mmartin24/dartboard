#!/bin/bash
# Runs all tests one after another; a failing test does not stop the rest.
# Verdicts: jq -r 'select(.event=="summary") | "\(.scenario) \(.status)"' ../testresults/*/*.jsonl
cd "$(dirname "$0")"
# All tests of this run share one results folder.
# ${PWD%/*}, not ../: qa/aws/scripts/new-tests is a link, and ../ would follow
# it back to qa/local/scripts (wrong VERSION and results folder).
export RESULTS_RUN_DIR="${PWD%/*}/testresults/${VER:-$(cat "${PWD%/*}/VERSION")}_$(date +%Y-%m-%d)"
echo "=== RUNNING TEST 01: baseline scale (50 bundles to all clusters)"
./01-run-baseline-scale-test.sh
echo "=== RUNNING TEST 02: race condition (8 rapid back-to-back commits)"
./02-run-race-condition-test.sh
echo "=== RUNNING TEST 03: controller crash (fleet-controller restart during rollout)"
./03-run-controller-crash-test.sh
echo "=== RUNNING TEST 04: heavy content race (delete and re-create a heavy GitRepo)"
./04-run-heavy-content-race-test.sh
echo "=== RUNNING TEST 05: create/delete churn (repeated create and delete cycles)"
./05-run-create-delete-churn-test.sh
echo "=== RUNNING TEST 06: single bundle create/delete race (delete during create)"
./06-run-single-bundle-create-delete-race-test.sh
echo "=== RUNNING TEST 07: webhook vs polling (5 commits per phase)"
./07-run-webhook-vs-polling-test.sh
echo "=== RUNNING TEST 08: webhook shared path (two repos, back-to-back pushes)"
./08-run-webhook-shared-path-test.sh
# Optional: push this run to the results repo (RESULTS_REPO_DIR = clone path).
# qa/aws/scripts/new-tests links here, so the folder name says local or aws.
[[ -n "${RESULTS_REPO_DIR:-}" ]] && ../../../publish-results.sh "$(basename "$(cd ../.. && pwd)")" "$RESULTS_RUN_DIR"
