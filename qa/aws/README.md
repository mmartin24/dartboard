# Fleet scale tests on AWS

The same 8 tests as [`qa/local/`](../local/README.md), on AWS clusters
(one RKE2 upstream cluster, k3s downstream clusters, 50 by default).
`scripts/new-tests` is a link to `../../local/scripts/new-tests`, so both
setups always run the same scripts; see the local README for what each test
does and how to read the results.

The difference to local: the AWS clusters cannot reach a Gitea on your
machine, so Gitea runs as a pod in the upstream cluster, and your machine
reaches it through a `kubectl port-forward` on `localhost:3001`.

## Setup

**Step 1. Settings and AWS login.** Copy `terraform.tfvars.example` to
`terraform.tfvars` (git-ignored) and fill in your AWS profile and SSH key
paths, then log in:

```bash
aws sso login --profile <profile>
```

**Step 2. Create the clusters and install Fleet** (from `qa/aws/`). The Fleet
version is in `scripts/VERSION`.

```bash
tofu init && tofu apply
./default_config/open-tunnels-to-upstream-server-0.sh
export KUBECONFIG="$PWD/default_config/upstream.yaml"
./scripts/10-setup-fleet.sh
./scripts/20-register-agents.sh
kubectl get clusters.fleet.cattle.io -n fleet-default   # wait for all 1/1
```

**Step 3. Gitea in the cluster** (from `qa/aws/scripts/new-tests/`):

```bash
eval "$(./install-gitea-in-cluster.sh)"
./setup-gitea.sh
./seed-test-repo.sh "$GITEA_HOST_URL/fleet-e2e-gitea/fleet-e2e.git"
./seed-test-repo.sh "$GITEA_HOST_URL/fleet-e2e-gitea/fleet-e2e-2.git"
```

`install-gitea-in-cluster.sh` starts Gitea (namespace `gitea`), creates an
admin user and a token, opens the port-forward, and prints the settings the
other scripts need; `eval` puts them in the current shell. The token is never
written to a file.

- **New shell:** run `eval "$(./install-gitea-in-cluster.sh)"` again.
- **Port-forward stopped** (e.g. network drop): same, run it again.
- **Gitea pod restarted:** its data is gone (it is not kept on disk), so run
  all of step 3 again.

## Run

From `qa/aws/scripts/new-tests/`, with `KUBECONFIG` and the Gitea settings
from step 3 in the shell:

```bash
./run-all.sh                               # all 8 tests
./02-run-race-condition-test.sh            # or a single one
```

## Results

All runs of one Fleet version on one day go to one folder:

```text
scripts/testresults/<fleet version>_<date>/<NN>_<scenario>.jsonl
```

A test run again on the same day gets its start time added, e.g.
`02_race_condition_14-05-31.jsonl`. The folder is git-ignored. The folder
name comes from `scripts/VERSION`: if a test prints `WARNING: VER=... but
installed fleet-controller is ...`, the file does not match the cluster.

Verdicts of all runs:

```bash
jq -r 'select(.event=="summary") | "\(.scenario) \(.status)"' ../testresults/*/*.jsonl
```

### Publishing results

Results stay on your machine until you publish them. With a clone of your
results repo, from `qa/aws/`:

```bash
RESULTS_REPO_DIR=<clone of your results repo> \
  ../publish-results.sh aws scripts/testresults/<fleet version>_<date>
```

It copies the `.jsonl` files to `aws/<fleet version>_<date>/` in that repo,
commits and **pushes right away**. To publish automatically after a full run,
export `RESULTS_REPO_DIR` before `./run-all.sh`.

## Clean up

From `qa/aws/`:

```bash
tofu destroy
```
