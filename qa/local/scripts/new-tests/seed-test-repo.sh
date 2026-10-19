#!/bin/bash
# seed-test-repo.sh <repo-url>
#
# Fills a git repo (branch main) with everything the tests fetch, so you don't
# need a copy of anyone else's repo. Run it once on each of your two empty
# Gitea repos (see README.md, "Bring your own Gitea"):
#
#   ./scripts/new-tests/seed-test-repo.sh "$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_A.git"
#   ./scripts/new-tests/seed-test-repo.sh "$GITEA_HOST_URL/$GITEA_ORG/$GITEA_REPO_B.git"
#
# Creates under scalability-performance/:
#   scale-50-bundles/{ten,twenty,thirty,fourty,fifty}/<10 bundles each>
#                        (tests 01, 02, 03, 05; 02 bumps ten/one/fleet.yaml)
#   single-race/one      (tests 06, 07, 08)
#   single-race-b/one    (test 08)
#   heavy-race/grafana   (test 04; pulls the Grafana chart from the internet)
# Both repos get the same content (each test only uses what it needs).
# Safe to re-run: it only commits if something changed.
#
# Requires: GITEA_TOKEN exported (repo write); it is only sent as an HTTP
# header, never stored in the repo or in a URL.

set -euo pipefail
repo_url="${1:?usage: $0 <repo-url>}"
: "${GITEA_TOKEN:?export GITEA_TOKEN first}"
export GIT_TERMINAL_PROMPT=0
auth=(-c "http.extraHeader=Authorization: token $GITEA_TOKEN")

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
git -C "$dir" init -q -b main
git -C "$dir" remote add origin "$repo_url"
# An empty repo has no main yet; an already-seeded one is updated in place.
if git -C "$dir" "${auth[@]}" fetch -q origin main 2>/dev/null; then
  git -C "$dir" checkout -q -B main FETCH_HEAD
fi
git -C "$dir" config user.name "${GIT_AUTHOR_NAME:-new-tests}"
git -C "$dir" config user.email "${GIT_AUTHOR_EMAIL:-new-tests@localhost}"

root="$dir/scalability-performance"

# chart <dir> [with_deployment]: a minimal Helm chart whose ConfigMap shows
# the bundle's name; the deployment (nginx) is what test 02 rolls.
chart() {
  mkdir -p "$1/config-chart/templates"
  cat >"$1/config-chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: config-chart
description: A test chart that verifies its config
type: application
version: 0.1.0
appVersion: "1.16.0"
EOF
  cat >"$1/config-chart/templates/configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-config-{{ .Values.name }}
data:
  name: {{ .Values.name }}
  extra: {{ .Values.extra }}
EOF
  if [[ "${2:-}" == deployment ]]; then
    echo -e 'name: default-name\nimage: nginx:1.25' >"$1/config-chart/values.yaml"
    cat >"$1/config-chart/templates/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: race-test-{{ .Values.name }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: race-test-{{ .Values.name }}
  template:
    metadata:
      labels:
        app: race-test-{{ .Values.name }}
    spec:
      containers:
        - name: nginx
          image: {{ .Values.image }}
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 1
            successThreshold: 1
EOF
  else
    echo 'name: default-name' >"$1/config-chart/values.yaml"
  fi
}

# --- scale-50-bundles: 50 bundles in 5 groups of 10
names=(one two three four five six seven eight nine ten
  eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty
  twenty-one twenty-two twenty-three twenty-four twenty-five twenty-six twenty-seven twenty-eight twenty-nine thirty
  thirty-one thirty-two thirty-three thirty-four thirty-five thirty-six thirty-seven thirty-eight thirty-nine forty
  forty-one forty-two forty-three forty-four forty-five forty-six forty-seven forty-eight forty-nine fifty)
groups=(ten twenty thirty fourty fifty)
for i in "${!names[@]}"; do
  b="$root/scale-50-bundles/${groups[$((i / 10))]}/${names[$i]}"
  if (( i == 0 )); then
    chart "$b" deployment
    cat >"$b/fleet.yaml" <<EOF
defaultNamespace: default
helm:
  chart: config-chart
  values:
    name: ${names[$i]}
    extra: testvalue
    image: nginx:1.26
rolloutStrategy:
  maxUnavailable: 100%
  autoPartitionSize: 100%
EOF
  else
    chart "$b"
    cat >"$b/fleet.yaml" <<EOF
defaultNamespace: default
helm:
  chart: config-chart
  values:
    name: ${names[$i]}
    extra: testvalue
rolloutStrategy:
  maxUnavailable: 100%
  autoPartitionSize: 100%
EOF
  fi
done

# --- single-race/one and single-race-b/one
for sr in single-race single-race-b; do
  b="$root/$sr/one"
  chart "$b" deployment
  cat >"$b/fleet.yaml" <<EOF
defaultNamespace: default
helm:
  chart: config-chart
  values:
    name: $sr-one
    extra: testvalue
EOF
done

# --- heavy-race/grafana
mkdir -p "$root/heavy-race/grafana"
cat >"$root/heavy-race/grafana/fleet.yaml" <<'EOF'
defaultNamespace: heavy-race
helm:
  repo: https://grafana.github.io/helm-charts
  chart: grafana
  values:
    persistence:
      enabled: false
    testFramework:
      enabled: false
EOF

git -C "$dir" add -A
if git -C "$dir" diff --cached --quiet; then
  echo "$repo_url already has the test content, nothing to push."
  exit 0
fi
git -C "$dir" commit -q -m "Seed test content for the Fleet new-tests"
git -C "$dir" "${auth[@]}" push -q origin main
echo "Seeded $repo_url (branch main)."
