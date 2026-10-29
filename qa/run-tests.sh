#!/bin/bash
# Runs the scale tests of one setup. Run it from anywhere.
#
#   ./run-tests.sh --target=local|aws [--tests=all|02,07] [--version=0.16.3]
#
# --tests    all (default), or test numbers 01-08 separated by commas: 02,07
# --version  only names the results folder (default: qa/VERSION). It does not
#            install Fleet, ./prepare.sh does; the tests warn if it differs
#            from the installed fleet-controller.
set -euo pipefail
usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
target="" tests=all
for arg in "$@"; do
  case "$arg" in
    --target=*) target=${arg#*=} ;;
    --tests=*) tests=${arg#*=} ;;
    --version=*) export VER=${arg#*=} ;;
    *) usage ;;
  esac
done
[[ "$target" == local || "$target" == aws ]] || usage
tests=${tests//[\[\] ]/} # --tests=[02,07] works too
IFS=, read -ra list <<<"$tests"
if [[ "$tests" != all ]]; then
  for n in "${list[@]}"; do
    [[ "$n" =~ ^0[1-8]$ ]] || { echo "unknown test: $n (use 01 to 08, or all)" >&2; exit 1; }
  done
fi

cd "$(dirname "$0")/$target/scripts/new-tests"
[[ "$tests" == all ]] && exec ./run-all.sh
# Same results folder run-all.sh uses. ${PWD%/*}, not ../: aws/scripts/new-tests
# is a link, and ../ would follow it back to local/scripts.
ver="${VER:-$(cat "${PWD%/*}/../../VERSION")}"
export RESULTS_RUN_DIR="${PWD%/*}/testresults/${ver#v}_$(date +%Y-%m-%d)"
rc=0
for n in "${list[@]}"; do
  echo "=== RUNNING TEST $n"
  ./"$n"-*.sh || rc=1
done
exit $rc
