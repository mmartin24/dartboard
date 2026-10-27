# Fleet scalability tests

Scripts that test how [Fleet](https://fleet.rancher.io) behaves under load.
They create one *upstream* cluster (where Fleet runs) and several
*downstream* clusters (where Fleet deploys to), install a Fleet version of
your choice and run 8 test scenarios against it. Every run produces a results
file that says `PASSED`, `FAILED` or `ERROR`.

| | Clusters | Gitea runs | Folder |
|---|---|---|---|
| **[Local (k3d)](#local-k3d-setup-and-run)** | k3d containers on your machine, as many as `cluster_count` in `local/terraform.tfvars` | in Docker on your machine | [`local/`](local/) |
| **[AWS](#aws-setup-and-run)** | RKE2 upstream + k3s downstream on EC2, as many as `cluster_count` in `aws/terraform.tfvars` | as a pod in the upstream cluster | [`aws/`](aws/) |

The tests live in [`local/scripts/new-tests/`](local/scripts/new-tests/);
`aws/scripts/new-tests` is a link to it, so both setups run the same scripts.
Only the terraform files and `10-setup-fleet.sh` differ between the folders.

Read the [common part](#common-to-both-setups) first, then follow the section
of your setup top to bottom. All commands run from `qa/`.

---

# Common to both setups

## Fleet version

The version to install and test is in `qa/VERSION` (git-ignored). Create it
once:

```bash
cp VERSION.example VERSION      # then edit if you want another version
```

It drives both setups and names the results folder. To test another version
on running clusters, change it and run `./prepare.sh local` (or `aws`) again;
Fleet is upgraded in place.

## Gitea requirements

The tests push commits to a [Gitea](https://about.gitea.com) server and Fleet
fetches from it. Gitea needs:

- `DOMAIN` and `ROOT_URL` with the host name the clusters use to reach Gitea.
- `[webhook] ALLOWED_HOST_LIST = *`.
- An **access token** with the scopes `write:repository` and
  `write:organization`.

`prepare.sh` sets up a Gitea that meets all three: in Docker locally, as a pod
on AWS. To use your own Gitea locally instead, export `GITEA_HOST_URL`,
`GITEA_CLUSTER_URL` and `GITEA_TOKEN` before running `prepare.sh` and the
tests.

## Gitea settings

Defaults are in `local/scripts/new-tests/lib/config.sh`, except the last four,
which only `setup-gitea.sh` reads. Override any of them with an environment
variable, e.g. `GITEA_ORG=acme ./local/scripts/new-tests/run-all.sh`, and use
the same values for `prepare.sh` and the tests. Values that `prepare.sh` wrote
to `.env` (see [Local](#local-k3d-setup-and-run) step 4) always come from
that file.

| Variable | Default | Meaning |
|---|---|---|
| `GITEA_HOST_URL` | `http://localhost:3000` | Gitea as seen from your machine. The tests push only here and refuse any other address. AWS: `localhost:3001`, set by `install-gitea-in-cluster.sh` |
| `GITEA_ORG` | `fleet-e2e-gitea` | Organization (or user) that owns the repos |
| `GITEA_REPO_A` | `fleet-e2e` | Main test repo |
| `GITEA_REPO_B` | `fleet-e2e-2` | Second repo, used by test 08 |
| `GITEA_CLUSTER_HOST` | `gitea.qa.local` | Name the clusters use for Gitea. Must match Gitea's `DOMAIN` and `ROOT_URL` |
| `GITEA_CLUSTER_URL` | `http://gitea.qa.local:3000` | Gitea as seen from inside the clusters |
| `FETCH_REPO_URL` | repo A | What tests 01, 03 and 05 fetch from (branch `main`) |
| `GITEA_CLUSTER_IP` | gateway of the k3d docker network | IP the clusters use to reach your machine (local only) |
| `WEBHOOK_HOST_IP` | first IP from `hostname -I` | IP Gitea uses to reach the clusters (local only) |
| `WEBHOOK_PORT` | `8080` | Host port to the upstream cluster's ingress, `first_app_http_port` in `terraform.tfvars` (local only) |
| `WEBHOOK_URL` | not set | AWS only, set by `install-gitea-in-cluster.sh`: webhook target; `setup-gitea.sh` then skips the DNS entry and Ingress |

## The tests

Each test creates its own GitRepo, deletes it at the end and gives a verdict.

| Test | What it checks |
|---|---|
| `01-run-baseline-scale-test.sh` | Rolls out 50 bundles to all clusters and deletes them again. The baseline for the others |
| `02-run-race-condition-test.sh` | Pushes 8 commits back to back, faster than the clusters can follow, and checks that nothing is left on an old commit |
| `03-run-controller-crash-test.sh` | Kills fleet-controller during a rollout and checks that it recovers without duplicate work. Measures recovery time |
| `04-run-heavy-content-race-test.sh` | Deletes a GitRepo with a heavy Helm chart (Grafana) mid-install and immediately re-creates it |
| `05-run-create-delete-churn-test.sh` | Repeats create, ready, delete 5 times, watching for leaked secrets and growing etcd size |
| `06-run-single-bundle-create-delete-race-test.sh` | Deletes a GitRepo as soon as its bundle appears, before anything is deployed. A basic cleanup check, not a real race |
| `07-run-webhook-vs-polling-test.sh` | Pushes 5 commits with the Gitea webhook off (polling only) and 5 with it on, and checks the webhook drives the update |
| `08-run-webhook-shared-path-test.sh` | Two repos whose webhooks share one receiver URL: pushes to both back to back, checks neither GitRepo reacts to the other's push |

`02` can end with `FAILED` and `TIMEOUT ... never found on all 50 bundles.
Still stuck: <bundle names>`. That is the Fleet bug the test catches, not a
setup problem.

## How the tests behave

- Before starting, a test deletes any GitRepo left from an earlier run and
  waits until its resources are gone.
- Every wait has a limit: 15 minutes, 8 for deletions. When it runs out the
  test ends with `FAILED` and says what it waited for. Change with
  `WAIT_TIMEOUT_SECONDS=1800` or `DELETE_TIMEOUT_SECONDS=600`. Tests 02, 07
  and 08 also have their own short limits per step, set at the top of each
  script.
- Any other stop (an error, Ctrl-C) still writes a summary with `ERROR`.

## Results

Tests write to `<local|aws>/scripts/testresults/<fleet version>_<date>/<scenario>.jsonl`
(a re-run on the same day adds `_<time>` to the name). Each file is JSON Lines, ending with a
`summary` line whose `status` is `PASSED`, `FAILED` or `ERROR`. Every line
carries `ts` (UTC), `scenario`, `fleet_version`, `run_id` and `env`; all but
the first and the summary line also carry `elapsed_s`. Measured numbers are
`metric` lines with `metric`, `value`, `unit`. `env` is `local`, or `aws` when run from `qa/aws/`; override with
`RESULTS_ENV`.

Verdicts of all runs, both setups:

```bash
jq -r 'select(.event=="summary") | "\(input_filename) \(.env // "?") \(.scenario) \(.status)"' \
  */scripts/testresults/*/*.jsonl
```

### Publishing results

To copy a run into a git repo of your choice (a clone on your machine), commit
and push it (on AWS: `aws` instead of `local`):

```bash
RESULTS_REPO_DIR=~/repos/my-results \
  ./publish-results.sh local local/scripts/testresults/0.16.3_2026-10-26
```

With `RESULTS_REPO_DIR` exported, `run-all.sh` publishes at the end on its
own.

---

# Local (k3d): setup and run

About 10 GB of free RAM for 10 clusters.

**1. Tools:** Linux with Docker running, `tofu`
([OpenTofu](https://opentofu.org)), `k3d`, `kubectl`, `helm`, `git`, `curl`,
`jq`, `envsubst`, `zsh`.

**2. One-time machine setup:**

```bash
sudo sysctl -w fs.inotify.max_user_instances=8192
sudo ufw allow from 172.16.0.0/12       # lets the clusters reach your machine
```

**3. Cluster settings.** Set `cluster_count` (downstream clusters) in
`local/terraform.tfvars`. Start with 10.

**4. Prepare everything:** Gitea in Docker, clusters, Fleet, Gitea repos and
test content. `tofu apply` asks for your approval. Safe to re-run.

```bash
./prepare.sh local
```

It writes the settings the tests need (`KUBECONFIG`, Gitea token) to
`local/.env`, git-ignored and readable only by you. The test scripts read it
on their own.

<details><summary>The same without <code>prepare.sh</code>, command by command</summary>

```bash
cd local                                    # everything below runs from qa/local/
export QA_PREPARE=1                         # scripts use the exports below, not local/.env

# Gitea in Docker, with an admin user and a token
docker run -d --name gitea -p 3000:3000 \
  -e GITEA__security__INSTALL_LOCK=true \
  -e GITEA__server__DOMAIN=gitea.qa.local \
  -e GITEA__server__ROOT_URL=http://gitea.qa.local:3000/ \
  -e GITEA__webhook__ALLOWED_HOST_LIST='*' \
  gitea/gitea:latest
until curl -s -o /dev/null http://localhost:3000/api/healthz; do sleep 1; done
docker exec -u git gitea gitea admin user create --admin --username fleet-qa-admin \
  --password '<password>' --email fleet-qa-admin@example.com --must-change-password=false
export GITEA_TOKEN=$(docker exec -u git gitea gitea admin user generate-access-token \
  --username fleet-qa-admin --token-name qa --scopes all --raw)

# Clusters (tofu apply asks for your approval)
tofu init
tofu apply
export KUBECONFIG=$PWD/default_config/upstream.yaml

# Fleet and the downstream clusters; wait until all show BUNDLES-READY 1/1
./scripts/10-setup-fleet.sh
./scripts/20-register-agents.sh
kubectl get clusters.fleet.cattle.io -n fleet-default

# Gitea org, repos and webhooks, DNS entry and Ingress; then the test content
./scripts/new-tests/setup-gitea.sh
./scripts/new-tests/seed-test-repo.sh http://localhost:3000/fleet-e2e-gitea/fleet-e2e.git
./scripts/new-tests/seed-test-repo.sh http://localhost:3000/fleet-e2e-gitea/fleet-e2e-2.git

# Tests, in this same shell
./scripts/new-tests/run-all.sh
```

</details>

**5. Run the tests** (all 8 take about 15 minutes with 10 clusters):

```bash
./local/scripts/new-tests/run-all.sh                         # all 8 tests
./local/scripts/new-tests/02-run-race-condition-test.sh      # or a single one
```

**6. Read the results**, see [Results](#results).

**7. Clean up:**

```bash
tofu -chdir=local destroy
```

For your own `kubectl` or `k9s`:
`export KUBECONFIG=$PWD/local/default_config/upstream.yaml`.

---

# AWS: setup and run

The AWS side must already be in place: an AWS account with an SSO profile
allowed to create EC2 and VPC resources, the SSH key pair at the paths in
`aws/terraform.tfvars`, and the managed prefix list named in `ssh_prefix_list`
(the IPs allowed to SSH in). `tofu` creates the VPC itself unless
`existing_vpc_name` is set. Gitea runs as a pod in the upstream cluster,
reached from your machine through a port-forward on `localhost:3001`.

**1. Tools:** `tofu`, `kubectl`, `helm`, `git`, `curl`, `jq`, `envsubst`,
`zsh`, `ssh`, AWS CLI.

**2. Settings and login.** Fill in your AWS profile and SSH key paths in
`aws/terraform.tfvars`, then log in:

```bash
aws sso login --profile <profile>
```

**3. Prepare everything:** clusters, tunnels, Fleet, Gitea in the cluster,
Gitea repos and test content. `tofu apply` asks for your approval. Safe to
re-run: `tofu apply` only adds what is missing.

```bash
./prepare.sh aws
```

The settings the tests need go to `aws/.env`, as for local.

<details><summary>The same without <code>prepare.sh</code>, command by command</summary>

```bash
cd aws                                      # everything below runs from qa/aws/
export QA_PREPARE=1                         # scripts use the exports below, not aws/.env

# Clusters (tofu apply asks for your approval)
tofu init
tofu apply

# Tunnels to the upstream server; wait until the cluster answers
./default_config/open-tunnels-to-upstream-server-0.sh
export KUBECONFIG=$PWD/default_config/upstream.yaml
until kubectl get --raw /version >/dev/null 2>&1; do sleep 2; done

# Fleet and the downstream clusters; wait until all show BUNDLES-READY 1/1
./scripts/10-setup-fleet.sh
./scripts/20-register-agents.sh
kubectl get clusters.fleet.cattle.io -n fleet-default

# Gitea as a pod: admin user, token and port-forward; eval loads the settings
eval "$(./scripts/new-tests/install-gitea-in-cluster.sh)"

# Gitea org, repos and webhooks; then the test content
./scripts/new-tests/setup-gitea.sh
./scripts/new-tests/seed-test-repo.sh "$GITEA_HOST_URL/fleet-e2e-gitea/fleet-e2e.git"
./scripts/new-tests/seed-test-repo.sh "$GITEA_HOST_URL/fleet-e2e-gitea/fleet-e2e-2.git"

# Tests, in this same shell
./scripts/new-tests/run-all.sh
```

</details>

**4. Run the tests:**

```bash
./aws/scripts/new-tests/run-all.sh                           # all 8 tests
./aws/scripts/new-tests/02-run-race-condition-test.sh        # or a single one
```

**5. Read the results**, see [Results](#results).

**6. Clean up:**

```bash
tofu -chdir=aws destroy
```

For your own `kubectl` or `k9s`:
`export KUBECONFIG=$PWD/aws/default_config/upstream.yaml`.
