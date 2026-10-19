#!/bin/bash
# lib/gitrepo-commits.sh
#
# Scripts commits against a GitRepo source so scenarios can push new commits
# without a human copy-pasting a SHA.
#
# Only pushes to your own Gitea ($GITEA_HOST_URL, see lib/config.sh):
# gitrepo_commits_init refuses any other URL, so these scripts can never
# push to a repo that isn't your scratch repo.
#
# Needs GITEA_TOKEN exported (Gitea: Settings -> Applications -> Generate New
# Token, needs repo write). It is read from the environment only, never
# written to disk or embedded in a URL, so it never ends up in this repo or
# in `git remote -v` output.
#
# Usage:
#   source "$(dirname "$0")/lib/gitrepo-commits.sh"
#   gitrepo_commits_init <local_clone_dir> <repo_url> [branch=main]
#   commit=$(push_marker_commit <path_in_repo> <marker_kv>)
#   commit=$(push_image_bump <fleet_yaml_path_in_repo> <new_image>)

# Without this, a git command run with no valid credentials (e.g.
# GITEA_TOKEN not exported) doesn't fail -- it silently prompts for a
# username on the terminal and hangs forever waiting for input that never
# comes, since these scripts never read from stdin. Forces every git
# command below to fail immediately instead, with a normal non-zero exit
# code the surrounding checks can catch.
export GIT_TERMINAL_PROMPT=0

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

GITREPO_COMMITS_DIR=""
GITREPO_COMMITS_BRANCH="main"
GITREPO_COMMITS_AUTH_ARGS=()

gitrepo_commits_init() {
  local dir="$1" repo_url="$2" branch="${3:-main}"
  if [[ "$repo_url" != "$GITEA_HOST_URL"/* ]]; then
    echo "[new-tests] REFUSING: $repo_url is not under GITEA_HOST_URL ($GITEA_HOST_URL) -- only your own Gitea is a valid push target." >&2
    exit 1
  fi
  GITREPO_COMMITS_DIR="$dir"
  GITREPO_COMMITS_BRANCH="$branch"
  GITREPO_COMMITS_AUTH_ARGS=()
  if [[ -n "${GITEA_TOKEN:-}" ]]; then
    GITREPO_COMMITS_AUTH_ARGS=(-c "http.extraHeader=Authorization: token $GITEA_TOKEN")
  fi
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" "${GITREPO_COMMITS_AUTH_ARGS[@]}" fetch origin "$branch"
    git -C "$dir" checkout "$branch"
    git -C "$dir" reset --hard "origin/$branch"
  else
    git "${GITREPO_COMMITS_AUTH_ARGS[@]}" clone --branch "$branch" "$repo_url" "$dir"
  fi
}

# push_marker_commit <path_in_repo> <marker_kv>
# Writes/updates a small ConfigMap resource under <path_in_repo> so the
# bundle's resourcesSHA256Sum actually changes (a real redeploy, not a
# no-op commit bump), commits, pushes, and prints the new commit SHA.
push_marker_commit() {
  local path_in_repo="$1" marker_kv="$2"
  local target_dir="$GITREPO_COMMITS_DIR/$path_in_repo"
  mkdir -p "$target_dir"
  cat >"$target_dir/new-tests-marker-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: new-tests-marker
data:
  marker: "$marker_kv"
EOF
  git -C "$GITREPO_COMMITS_DIR" add "$path_in_repo/new-tests-marker-configmap.yaml"
  git -C "$GITREPO_COMMITS_DIR" commit -m "new-tests marker: $marker_kv" --allow-empty >&2
  if ! git -C "$GITREPO_COMMITS_DIR" "${GITREPO_COMMITS_AUTH_ARGS[@]}" push origin "$GITREPO_COMMITS_BRANCH" >&2; then
    echo "[new-tests] ERROR: git push failed -- is GITEA_TOKEN exported and valid? (Settings -> Applications -> Generate New Token, needs repo write)" >&2
    exit 1
  fi
  git -C "$GITREPO_COMMITS_DIR" rev-parse HEAD
}

# push_image_bump <fleet_yaml_path_in_repo> <new_image>
# Rewrites the "image: ..." line under a fleet.yaml's helm.values (expects
# a bundle set up like scale-50-bundles/ten/one, which has a real
# Deployment templated on .Values.image) so the change forces an actual
# rolling pod restart on every target cluster, not just a ConfigMap tweak.
# <fleet_yaml_path_in_repo> is the path to the fleet.yaml itself (not its
# directory), e.g. scalability-performance/scale-50-bundles/ten/one/fleet.yaml.
push_image_bump() {
  local fleet_yaml_path_in_repo="$1" new_image="$2"
  local fleet_yaml="$GITREPO_COMMITS_DIR/$fleet_yaml_path_in_repo"
  sed -i "s#^\(\s*image:\).*#\1 $new_image#" "$fleet_yaml"
  git -C "$GITREPO_COMMITS_DIR" add "$fleet_yaml_path_in_repo"
  git -C "$GITREPO_COMMITS_DIR" commit -m "new-tests: bump image to $new_image" >&2
  if ! git -C "$GITREPO_COMMITS_DIR" "${GITREPO_COMMITS_AUTH_ARGS[@]}" push origin "$GITREPO_COMMITS_BRANCH" >&2; then
    echo "[new-tests] ERROR: git push failed -- is GITEA_TOKEN exported and valid? (Settings -> Applications -> Generate New Token, needs repo write)" >&2
    exit 1
  fi
  git -C "$GITREPO_COMMITS_DIR" rev-parse HEAD
}
