#!/bin/bash
# lib/config.sh
#
# Where the tests fetch from and push to. Every value has a default and can
# be overridden per run with an environment variable, e.g.
#   GITEA_ORG=myorg GITEA_REPO_A=my-repo ./scripts/new-tests/02-run-race-condition-test.sh
# Sourced by lib/results.sh, so every script has it. See qa/README.md ("Gitea
# requirements") for what has to exist on the Gitea side.

# qa/<local|aws>/.env, written by qa/prepare.sh. Its values win over the
# shell's, so a KUBECONFIG, GITEA_TOKEN or Gitea URL left over from the other
# setup is never used. prepare.sh itself runs with QA_PREPARE=1 and skips it.
_env_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/.env"
if [[ -z "${QA_PREPARE:-}" ]]; then
  if [[ ! -f "$_env_file" ]]; then
    echo "[new-tests] ERROR: $_env_file not found. Run ./prepare.sh local (or aws) from qa/ first." >&2
    exit 1
  fi
  while IFS='=' read -r _k _v || [[ -n "$_k" ]]; do
    [[ "$_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] && export "$_k=${_v%$'\r'}"
  done <"$_env_file"
fi

# Gitea, as seen from the machine running the scripts (git push, API calls).
GITEA_HOST_URL="${GITEA_HOST_URL:-http://localhost:3000}"
# Gitea, as seen from inside the cluster (what GitRepo spec.repo fetches from).
# gitjob can't reach the host's loopback, so this is a name that setup-gitea.sh
# makes CoreDNS resolve to the docker network's gateway (= the host).
GITEA_CLUSTER_HOST="${GITEA_CLUSTER_HOST:-gitea.qa.local}"
GITEA_CLUSTER_URL="${GITEA_CLUSTER_URL:-http://$GITEA_CLUSTER_HOST:3000}"
GITEA_ORG="${GITEA_ORG:-fleet-e2e-gitea}"
GITEA_REPO_A="${GITEA_REPO_A:-fleet-e2e}"     # tests 02, 04, 06, 07, 08
GITEA_REPO_B="${GITEA_REPO_B:-fleet-e2e-2}"   # test 08 only
# Tests 01, 03, 05 only fetch (never push). By default they use the same Gitea
# repo as the others, so no other git hosting is needed. Any repo your cluster
# can fetch works, if it has the content from seed-test-repo.sh on branch main.
FETCH_REPO_URL="${FETCH_REPO_URL:-$GITEA_CLUSTER_URL/$GITEA_ORG/$GITEA_REPO_A}"
export GITEA_HOST_URL GITEA_CLUSTER_HOST GITEA_CLUSTER_URL GITEA_ORG GITEA_REPO_A GITEA_REPO_B FETCH_REPO_URL

# render_manifest <file>: prints the manifest with the values above filled in
# (only these variables are replaced, any other $ in the yaml is untouched).
render_manifest() {
  envsubst '${GITEA_CLUSTER_URL} ${GITEA_ORG} ${GITEA_REPO_A} ${GITEA_REPO_B} ${FETCH_REPO_URL}' <"$1"
}

# upstream_server_container: name of the docker container running the upstream
# k3d cluster's server (the current kubectl context must be that cluster's,
# k3d names contexts "k3d-<cluster>"). Prints nothing for any other cluster.
upstream_server_container() {
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null)
  [[ "$ctx" == k3d-* ]] && echo "${ctx}-server-0"
}
