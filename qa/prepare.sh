#!/bin/bash
# Prepares everything up to running the tests: clusters, Fleet, Gitea, test
# repos. At the end it writes the settings the tests need (KUBECONFIG,
# GITEA_TOKEN, ...) to qa/<local|aws>/.env (git-ignored); the tests load it on
# their own, so there is nothing to export.
#
#   ./prepare.sh local [--version=0.16.3]     # or: aws
#
# --version writes qa/VERSION and installs that Fleet. Without it, the version
# in qa/VERSION is installed.
#
# tofu apply asks for your approval. Local only: TOFU_AUTO_APPROVE=1 (exported
# or in front of the command) skips it. Safe to re-run: every step skips or
# repeats what is already there.
#
# Run ./requirements.sh local|aws [--fix] first: it checks the tools, inotify
# limits, ports and the firewall on any Linux distribution.
#
# One-time steps it does not do (they need sudo or a browser):
#   local: sudo sysctl -w fs.inotify.max_user_instances=8192  (requirements.sh --fix)
#          allow 172.16.0.0/12 in your firewall, e.g. sudo ufw allow from 172.16.0.0/12
#   aws:   aws sso login --profile <profile from terraform.tfvars>
set -euo pipefail
usage() { echo "usage: ./prepare.sh local|aws [--version=0.16.3]" >&2; exit 1; }
env="${1:-}"
[[ "$env" == local || "$env" == aws ]] || usage
shift
qa="$(cd "$(dirname "$0")" && pwd)"
for arg in "$@"; do
  case "$arg" in
    --version=?*) ver=${arg#*=}; echo "${ver#v}" >"$qa/VERSION" ;;
    *) usage ;;
  esac
done
[[ -f "$qa/VERSION" ]] || { echo "ERROR: no qa/VERSION: use --version=<Fleet version> or cp VERSION.example VERSION" >&2; exit 1; }
cd "$qa/$env"
tests="$PWD/scripts/new-tests"
# Every script below uses this run's values, not an older .env (see lib/config.sh).
export QA_PREPARE=1

if [[ "$env" == local ]]; then
  # 1280 was enough for a 10-cluster run; the kernel default (128) is not.
  if (( $(sysctl -n fs.inotify.max_user_instances) < 1280 )); then
    echo "ERROR: run first: sudo sysctl -w fs.inotify.max_user_instances=8192"; exit 1
  fi

  echo "=== Gitea in Docker"
  gitea_url="${GITEA_HOST_URL:-http://localhost:3000}"
  if ! curl -s -o /dev/null "$gitea_url/api/healthz"; then
    if docker container inspect gitea >/dev/null 2>&1; then
      docker start gitea
    else
      docker run -d --name gitea -p 3000:3000 \
        -e GITEA__security__INSTALL_LOCK=true \
        -e GITEA__server__DOMAIN=gitea.qa.local \
        -e GITEA__server__ROOT_URL=http://gitea.qa.local:3000/ \
        -e GITEA__security__ALLOWED_HOST_LIST='*,private' \
        gitea/gitea:latest
    fi
    for _ in $(seq 60); do curl -s -o /dev/null "$gitea_url/api/healthz" && break; sleep 1; done
  fi
  # An exported GITEA_TOKEN is used if Gitea accepts it (one left in the shell
  # from an older Gitea is not); otherwise make one in the container.
  if [[ -n "${GITEA_TOKEN:-}" ]] && [[ "$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: token $GITEA_TOKEN" "$gitea_url/api/v1/user")" != 200 ]]; then
    GITEA_TOKEN=""
  fi
  if [[ -z "${GITEA_TOKEN:-}" ]]; then
    # The token comes from the 'gitea' container. If something else answers on
    # the port (e.g. the Gitea snap), the container is not up and docker exec fails.
    if [[ "$(docker inspect -f '{{.State.Running}}' gitea 2>/dev/null)" != true ]]; then
      echo "ERROR: $gitea_url answers, but the 'gitea' container is not running." >&2
      echo "Something else uses that port (e.g. the Gitea snap: sudo snap stop --disable gitea)." >&2
      echo "Stop it and run again, or export GITEA_TOKEN (and GITEA_HOST_URL) for your own Gitea." >&2
      exit 1
    fi
    admin="fleet-qa-admin" # must differ from GITEA_ORG
    if ! docker exec -u git gitea gitea admin user list --admin | grep -qw "$admin"; then
      docker exec -u git gitea gitea admin user create --admin --username "$admin" \
        --password "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" --email "$admin@example.com" --must-change-password=false
    fi
    GITEA_TOKEN=$(docker exec -u git gitea gitea admin user generate-access-token \
      --username "$admin" --token-name "qa-$(date +%s)" --scopes all --raw)
  fi
  export GITEA_TOKEN

  echo "=== Clusters"
  tofu init
  tofu apply ${TOFU_AUTO_APPROVE:+-auto-approve}
  export KUBECONFIG="$PWD/default_config/upstream.yaml"
else
  profile=$(sed -n 's/^aws_profile *= *"\([^"]*\)".*/\1/p' terraform.tfvars)
  if ! aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
    echo "ERROR: run first: aws sso login --profile $profile"; exit 1
  fi

  echo "=== Clusters"
  tofu init
  tofu apply
  ./default_config/open-tunnels-to-upstream-server-0.sh
  export KUBECONFIG="$PWD/default_config/upstream.yaml"
  # The tunnel script only prints "Waiting for tunnel"; its wait is commented
  # out, so wait here until the API answers through the tunnel.
  for _ in $(seq 60); do kubectl get --raw /version >/dev/null 2>&1 && break; sleep 2; done
  kubectl get --raw /version >/dev/null || { echo "ERROR: upstream API not reachable through the tunnel after 2 minutes"; exit 1; }
fi

echo "=== Fleet and downstream clusters"
./scripts/10-setup-fleet.sh
./scripts/20-register-agents.sh # on a re-run, "already exists" for the secrets is expected

want=$(ls default_config/downstream-*-direct.yaml | wc -l)
echo "Waiting until all $want clusters show BUNDLES-READY"
ready=0
for _ in $(seq 180); do
  ready=$(kubectl get clusters.fleet.cattle.io -n fleet-default --no-headers 2>/dev/null \
    | awk '{split($2, a, "/"); if (a[2] > 0 && a[1] == a[2]) n++} END {print n + 0}')
  (( ready == want )) && break
  echo -n .; sleep 5
done
echo
(( ready == want )) || { echo "ERROR: only $ready of $want clusters ready after 15 minutes"; exit 1; }

if [[ "$env" == aws ]]; then
  echo "=== Gitea in the cluster"
  gitea_env=$("$tests/install-gitea-in-cluster.sh")
  eval "$gitea_env"
fi

echo "=== Gitea repos, webhooks and test content"
"$tests/setup-gitea.sh"
read -r repo_a repo_b < <(source "$tests/lib/config.sh"; echo "$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_A.git $GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_B.git")
"$tests/seed-test-repo.sh" "$repo_a"
"$tests/seed-test-repo.sh" "$repo_b"

# One KEY=value per line; lib/config.sh loads it for every script.
(
  umask 077 # only you can read it: it holds the token
  rm -f .env
  {
    echo "KUBECONFIG=$KUBECONFIG"
    if [[ "$env" == local ]]; then
      echo "GITEA_TOKEN=$GITEA_TOKEN"
      (source "$tests/lib/config.sh"; echo "GITEA_HOST_URL=$GITEA_HOST_URL"; echo "GITEA_CLUSTER_URL=$GITEA_CLUSTER_URL")
      echo "WEBHOOK_URL="
    else
      tr ' ' '\n' <<<"${gitea_env#export }"
    fi
  } >.env
)
echo "=== Ready. Settings in $PWD/.env. Run the tests (from any folder):"
echo "  $tests/run-all.sh"
echo "For your own kubectl/k9s: export KUBECONFIG=$KUBECONFIG"
