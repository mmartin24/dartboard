#!/bin/bash
# setup-gitea.sh
#
# Prepares Gitea and the cluster for tests 01-08. Safe to re-run (run it after
# every `tofu apply` + ../10-setup-fleet.sh, the cluster side is lost on a
# rebuild).
#
# Gitea side (through its API, nothing is assumed to exist):
#   - the organization (or user) $GITEA_ORG
#   - two PUBLIC repos, $GITEA_REPO_A and $GITEA_REPO_B (public, because the
#     GitRepos fetch them without credentials)
#   - a "gogs"-type push webhook on each, pointing at the cluster
#     (not "gitea"-type: gitjob only understands GitHub/GitLab/Gogs/... headers)
# Cluster side:
#   - CoreDNS entry so pods can resolve $GITEA_CLUSTER_HOST to this host
#   - the gitjob-webhook Ingress, so Gitea can reach gitjob's webhook receiver
#
# It does NOT install Gitea, change Gitea's app.ini, or touch the host firewall;
# README.md ("Bring your own Gitea") lists those one-time steps. After this
# script, fill the repos with ./seed-test-repo.sh.
#
# Requires: KUBECONFIG pointing at the upstream cluster, GITEA_TOKEN exported
# (Gitea token with repo + organization write), curl, jq.
# Optional environment (defaults in brackets):
#   GITEA_CLUSTER_IP   IP your pods use to reach this host [auto: gateway of the
#                      docker network of the current k3d context]
#   WEBHOOK_HOST_IP    IP Gitea uses to reach the cluster's ingress [first IP
#                      from `hostname -I`]
#   WEBHOOK_PORT       host port mapped to the cluster ingress's port 80 [8080]
#                      (first_app_http_port in terraform.tfvars)
# plus everything in lib/config.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
: "${GITEA_TOKEN:?export GITEA_TOKEN first}"

api="$GITEA_HOST_URL/api/v1"
gitea() { # gitea <METHOD> <path> [json body] -> prints body; on HTTP >= 400 prints Gitea's message and exits
  local method="$1" path="$2" body="${3:-}" out code
  out=$(curl -s -w '\n%{http_code}' -X "$method" -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
    ${body:+-d "$body"} "$api$path") || { echo "ERROR: cannot reach Gitea at $GITEA_HOST_URL" >&2; exit 1; }
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if (( code >= 400 )); then
    echo "ERROR: Gitea $method $path -> HTTP $code: $(jq -r '.message // empty' <<<"$out" 2>/dev/null || echo "$out")" >&2
    echo "(a 403 'token does not have ... scope' means GITEA_TOKEN needs more scopes: repository + organization write)" >&2
    exit 1
  fi
  echo "$out"
}
gitea_status() { # HTTP status of a GET
  curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $GITEA_TOKEN" "$api$1"
}

if [[ "$(gitea_status /version)" != 200 ]]; then
  echo "ERROR: cannot reach Gitea at $GITEA_HOST_URL (or GITEA_TOKEN is invalid)." >&2
  echo "Install/start Gitea first, or set GITEA_HOST_URL (see README.md)." >&2
  exit 1
fi

### Gitea: org/user and repos (the org is only looked at if a repo is missing)
repos_path=""
ensure_org() {
  [[ -n "$repos_path" ]] && return
  if [[ "$(gitea_status "/orgs/$GITEA_ORG")" == 200 ]]; then
    repos_path="/orgs/$GITEA_ORG/repos"
  elif [[ "$(gitea_status "/users/$GITEA_ORG")" == 200 ]]; then
    repos_path="/user/repos" # a plain user: the token must belong to that user
    [[ "$(gitea GET /user | jq -r .login)" == "$GITEA_ORG" ]] || { echo "ERROR: $GITEA_ORG is a user but GITEA_TOKEN belongs to someone else." >&2; exit 1; }
  else
    echo "creating organization $GITEA_ORG"
    gitea POST /orgs "{\"username\":\"$GITEA_ORG\",\"visibility\":\"public\"}" >/dev/null
    repos_path="/orgs/$GITEA_ORG/repos"
  fi
}
for repo in "$GITEA_REPO_A" "$GITEA_REPO_B"; do
  if [[ "$(gitea_status "/repos/$GITEA_ORG/$repo")" == 200 ]]; then
    echo "repo $GITEA_ORG/$repo exists"
  else
    ensure_org
    echo "creating public repo $GITEA_ORG/$repo"
    gitea POST "$repos_path" "{\"name\":\"$repo\",\"private\":false,\"default_branch\":\"main\"}" >/dev/null
  fi
done

### Cluster: where pods reach this host
gateway="${GITEA_CLUSTER_IP:-}"
if [[ -z "$gateway" ]]; then
  container=$(upstream_server_container)
  if [[ -n "$container" ]]; then
    gateway=$(docker inspect "$container" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')
  fi
fi
if [[ -z "$gateway" ]]; then
  echo "ERROR: cannot work out the IP your pods use to reach this host." >&2
  echo "The current kubectl context ($(kubectl config current-context)) is not a k3d cluster. Set GITEA_CLUSTER_IP=<ip> and re-run." >&2
  exit 1
fi
lan_ip="${WEBHOOK_HOST_IP:-$(hostname -I | awk '{print $1}')}"
webhook_port="${WEBHOOK_PORT:-8080}"
webhook_host="gitjob-${lan_ip//./-}.nip.io"
webhook_url="http://$webhook_host:$webhook_port/"
echo "$GITEA_CLUSTER_HOST -> $gateway, webhook $webhook_url"

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  gitea.server: |
    $GITEA_CLUSTER_HOST:53 {
      hosts {
        $gateway $GITEA_CLUSTER_HOST
        fallthrough
      }
    }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitjob-webhook
  namespace: cattle-fleet-system
spec:
  rules:
  - host: $webhook_host
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: gitjob
            port:
              number: 80
EOF
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=120s

### Gitea: one gogs webhook per repo -> gitjob
for repo in "$GITEA_REPO_A" "$GITEA_REPO_B"; do
  hooks="/repos/$GITEA_ORG/$repo/hooks"
  body="{\"type\":\"gogs\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"$webhook_url\",\"content_type\":\"json\"}}"
  id=$(gitea GET "$hooks" | jq -r '[.[] | select(.type=="gogs")][0].id // empty')
  if [[ -n "$id" ]]; then
    gitea PATCH "$hooks/$id" "$body" >/dev/null
    echo "$repo: webhook $id -> $webhook_url"
  else
    id=$(gitea POST "$hooks" "$body" | jq -r .id)
    echo "$repo: created webhook $id -> $webhook_url"
  fi
done
echo
echo "Done. Next, fill both repos with the test content:"
echo "  $(dirname "${BASH_SOURCE[0]}")/seed-test-repo.sh $GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_A.git"
echo "  $(dirname "${BASH_SOURCE[0]}")/seed-test-repo.sh $GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_B.git"
