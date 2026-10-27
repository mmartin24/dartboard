#!/bin/bash
# install-gitea-in-cluster.sh
#
# For clusters that cannot reach a Gitea on your machine (AWS): runs Gitea as
# a pod in the upstream cluster, creates an admin user and an API token, and
# opens a port-forward so this machine reaches it on localhost. Prints the
# settings the other scripts need. qa/prepare.sh aws runs it and stores them
# in qa/aws/.env; by hand, run it through eval:
#
#   eval "$(./install-gitea-in-cluster.sh)"
#   ./setup-gitea.sh
#   ./seed-test-repo.sh "$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_A.git"
#   ./seed-test-repo.sh "$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_B.git"
#
# Safe to re-run (a new shell needs the eval again; it makes a new token).
# Gitea keeps its data in an emptyDir: if the pod restarts, the repos are gone
# and setup-gitea.sh + seed-test-repo.sh have to run again.
#
# Requires: KUBECONFIG pointing at the upstream cluster, curl.
# Optional environment (defaults in brackets):
#   GITEA_LOCAL_PORT   local port for the port-forward [3001, so it does not
#                      clash with a local Gitea on 3000]
#   GITEA_IMAGE        [gitea/gitea:1.24-rootless]

set -euo pipefail
port="${GITEA_LOCAL_PORT:-3001}"
image="${GITEA_IMAGE:-gitea/gitea:1.24-rootless}"
svc_host="gitea-http.gitea.svc.cluster.local"
admin="fleet-qa-admin"   # must differ from GITEA_ORG

# Everything but the final export line goes to stderr, so eval only sees that.
exec 3>&1 1>&2

# ROOT_URL must be the address the GitRepos use, see README.md (Fleet matches
# webhooks to GitRepos by comparing repo URLs). ALLOWED_HOST_LIST: Gitea
# refuses webhooks to private addresses by default, gitjob is one.
kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: gitea
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea
  namespace: gitea
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitea
  template:
    metadata:
      labels:
        app: gitea
    spec:
      containers:
      - name: gitea
        image: $image
        env:
        - {name: GITEA__database__DB_TYPE, value: sqlite3}
        - {name: GITEA__security__INSTALL_LOCK, value: "true"}
        - {name: GITEA__server__DOMAIN, value: $svc_host}
        - {name: GITEA__server__ROOT_URL, value: "http://$svc_host:3000/"}
        - {name: GITEA__webhook__ALLOWED_HOST_LIST, value: "*"}
        ports:
        - containerPort: 3000
        readinessProbe:
          httpGet: {path: /api/healthz, port: 3000}
        volumeMounts:
        - {name: data, mountPath: /var/lib/gitea}
        - {name: config, mountPath: /etc/gitea}
      volumes:
      - {name: data, emptyDir: {}}
      - {name: config, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata:
  name: gitea-http
  namespace: gitea
spec:
  selector:
    app: gitea
  ports:
  - port: 3000
YAML
kubectl -n gitea rollout status deploy/gitea --timeout=300s

if ! kubectl -n gitea exec deploy/gitea -- gitea admin user list --admin | grep -qw "$admin"; then
  kubectl -n gitea exec deploy/gitea -- gitea admin user create --admin --username "$admin" \
    --password "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" --email "$admin@example.com" --must-change-password=false
fi
token=$(kubectl -n gitea exec deploy/gitea -- gitea admin user generate-access-token \
  --username "$admin" --token-name "qa-$(date +%s)" --scopes all --raw)

# ponytail: a plain background port-forward; it dies if the Gitea pod restarts
# or kubectl loses the cluster -- re-run this script then.
if ! curl -s -o /dev/null "http://localhost:$port/api/healthz"; then
  nohup kubectl -n gitea port-forward svc/gitea-http "$port:3000" </dev/null >"${TMPDIR:-/tmp}/gitea-port-forward.log" 2>&1 3>&- &
  for _ in $(seq 30); do curl -s -o /dev/null "http://localhost:$port/api/healthz" && break; sleep 1; done
fi
curl -s -o /dev/null "http://localhost:$port/api/healthz" || { echo "ERROR: port-forward to Gitea failed, see ${TMPDIR:-/tmp}/gitea-port-forward.log"; exit 1; }
echo "Gitea is up: http://localhost:$port (cluster: http://$svc_host:3000)"

echo "export GITEA_HOST_URL=http://localhost:$port GITEA_CLUSTER_URL=http://$svc_host:3000" \
  "WEBHOOK_URL=http://gitjob.cattle-fleet-system.svc.cluster.local/ GITEA_TOKEN=$token" >&3
