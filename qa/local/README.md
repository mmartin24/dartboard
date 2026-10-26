# Fleet scalability tests on a local k3d setup

A set of scripts to test how [Fleet](https://fleet.rancher.io) behaves under
load on your own machine, with no cloud account. They create one *upstream*
Kubernetes cluster (where Fleet runs) and several *downstream* clusters
(where Fleet deploys to) as Docker containers using
[k3d](https://k3d.io), install a Fleet version of your choice, and then run
test scenarios against it: rolling out 50 bundles to every cluster, pushing
commits faster than the clusters can follow, killing the Fleet controller
mid-rollout, and so on. Every run produces a results file that says
`PASSED`, `FAILED` or `ERROR`.

Everything needed is in this folder (`qa/local/`).

How to use it, in two parts:

1. **[Setup](#part-1-setup-once-before-running-any-script)**: install the
   tools, a Gitea server and a few settings. You do this yourself, once.
2. **[Run](#part-2-run-the-tests)**: numbered steps from creating the
   clusters to the test results.

---

## Part 1: Setup (once, before running any script)

### 1.1 Tools

| Tool | Used for |
|---|---|
| Linux with Docker running | the clusters are containers |
| `tofu` ([OpenTofu](https://opentofu.org)) | creates the clusters |
| `k3d`, `kubectl`, `helm` | clusters, access, installing Fleet |
| `git`, `curl`, `jq`, `envsubst`, `zsh` | used by the scripts |

You also need about 10 GB of free RAM for 10 clusters. Each cluster is its own
k3s container.

### 1.2 System setting for many clusters

Raise the inotify limit, or some clusters fail to start with `too many open
files`:

```bash
sudo sysctl -w fs.inotify.max_user_instances=8192
```

### 1.3 Gitea

The tests push commits to a [Gitea](https://about.gitea.com) server and Fleet
fetches from it, so you need one. If you already have one, skip to the
configuration. Otherwise, an example that runs Gitea in Docker with the
configuration below already applied:

```bash
docker run -d --name gitea -p 3000:3000 \
  -e GITEA__security__INSTALL_LOCK=true \
  -e GITEA__server__DOMAIN=gitea.qa.local \
  -e GITEA__server__ROOT_URL=http://gitea.qa.local:3000/ \
  -e GITEA__webhook__ALLOWED_HOST_LIST='*' \
  gitea/gitea:latest
docker exec -u git gitea gitea admin user create --admin --username qa --password '<password>' --email qa@example.com
```

Your Gitea must be configured like this (`app.ini`):

- `DOMAIN` and `ROOT_URL` must use the same host name that the clusters use to
  reach Gitea. Fleet matches an incoming webhook to a GitRepo by comparing the
  repo address Gitea puts in the webhook (built from `ROOT_URL`) with the
  address in the GitRepo; if the host names differ, the webhook is accepted
  but triggers nothing. The tests call that host name `GITEA_CLUSTER_HOST`
  and it defaults to `gitea.qa.local`. It is only a name, any name works, as
  long as `GITEA_CLUSTER_HOST` and Gitea's `DOMAIN`/`ROOT_URL` agree.
- `[webhook] ALLOWED_HOST_LIST = *`. Gitea refuses by default to send
  webhooks to private (LAN) addresses.

Then create an **access token** (Gitea: Settings, Applications) with the
scopes `write:repository` and `write:organization`. You will export it as
`GITEA_TOKEN` in Part 2. It is only read from the environment, never written
to a file or put in a URL.

Gitea is expected at `http://localhost:3000` on your machine, and the clusters
reach it on port 3000 of your machine. For another address or port, set
`GITEA_HOST_URL` and `GITEA_CLUSTER_URL` (see [Settings](#settings)).

### 1.4 Firewall

The clusters must be able to reach Gitea on your machine. Docker gives the
clusters' network an address range that you must allow in your firewall (the
commands below are for `ufw`; use the equivalent for any other firewall).

Docker normally uses addresses from `172.16.x.x` to `172.31.x.x` for its
networks, and `172.16.0.0/12` is the way to write that whole block. The
simplest rule allows all of it, and it keeps working when the network is
recreated:

```bash
sudo ufw allow from 172.16.0.0/12      # = 172.16.x.x to 172.31.x.x
```

If your Docker uses other ranges, or you prefer a narrower rule, allow the
clusters' own network. It exists after Step 1 of Part 2 and is named
`<project_name>-k3d` (`project_name` is in `terraform.tfvars`, default
`st-local`):

```bash
docker network inspect st-local-k3d --format '{{(index .IPAM.Config 0).Subnet}}'
sudo ufw allow from <the subnet printed above>
```

A narrow rule has to be updated whenever the network is recreated with a
different range.

### 1.5 Cluster settings

```bash
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` (it is not committed) and set `cluster_count`, the
number of downstream clusters. Start with 10. See [Number of
clusters](#number-of-clusters) before going higher.

The Fleet version to test is in `scripts/VERSION` (for example
`0.17.0-alpha.7`). Edit it if you want another one.

---

## Part 2: Run the tests

All commands run from this folder (`qa/local/`).

**Step 1. Create the clusters** (a few minutes):

```bash
tofu init
tofu apply
```

**Step 2. Set `KUBECONFIG` and `GITEA_TOKEN`.** Do this in every new terminal
you use for the tests:

```bash
export KUBECONFIG="$PWD/default_config/upstream.yaml"
export GITEA_TOKEN=<your Gitea token>
```

**Step 3. Install Fleet:**

```bash
./scripts/10-setup-fleet.sh
```

**Step 4. Register the downstream clusters, and wait until all show `1/1`:**

```bash
./scripts/20-register-agents.sh
kubectl get clusters.fleet.cattle.io -n fleet-default
```

**Step 5. Prepare Gitea and the cluster for it.** This creates what is
missing in Gitea (the organization `fleet-e2e-gitea`, two public repos, and a
webhook on each) and sets up the cluster so it can reach Gitea (a DNS name for
your machine, and an Ingress for Fleet's webhook receiver). It is safe to run
again, and you must run it after every `tofu apply`, because the cluster part
is lost when the clusters are rebuilt.

```bash
./scripts/new-tests/setup-gitea.sh
```

**Step 6. Fill the two repos with the test content** (50 small Helm bundles,
a few single-bundle charts, the Grafana GitRepo). Only the first time per
Gitea; it commits only if something changed.

```bash
./scripts/new-tests/seed-test-repo.sh http://localhost:3000/fleet-e2e-gitea/fleet-e2e.git
./scripts/new-tests/seed-test-repo.sh http://localhost:3000/fleet-e2e-gitea/fleet-e2e-2.git
```

**Step 7. Run the tests.** With 10 clusters, all of them take about 15
minutes.

```bash
./scripts/new-tests/run-all.sh                       # all tests, one after another
./scripts/new-tests/02-run-race-condition-test.sh    # or a single one
```

**Step 8. Read the results**, see [Results](#results).

**Step 9. Clean up** when you are done:

```bash
tofu destroy
```

---

## The tests

All tests are in `scripts/new-tests/`. Each one creates its own GitRepo, does
its thing, deletes it, and ends with a verdict.

| Test | What it checks |
|---|---|
| `01-run-baseline-scale-test.sh` | Rolls out 50 bundles to all clusters and deletes them again. The baseline for the others |
| `02-run-race-condition-test.sh` | Pushes 8 commits back to back, faster than the clusters can finish the previous one, and checks that nothing is left on an old commit |
| `03-run-controller-crash-test.sh` | Kills fleet-controller during a rollout and checks that it recovers without duplicate work. Measures recovery time |
| `04-run-heavy-content-race-test.sh` | Deletes a GitRepo with a heavy Helm chart (Grafana) mid-install and immediately re-creates it |
| `05-run-create-delete-churn-test.sh` | Repeats create, ready, delete 5 times, watching for leaked secrets and growing etcd size |
| `06-run-single-bundle-create-delete-race-test.sh` | Deletes a bundle right after it was created. A basic cleanup health check, not a real race |
| `07-run-webhook-vs-polling-test.sh` | Pushes 5 commits with the Gitea webhook off (polling only) and 5 with it on, and checks the webhook drives the update |
| `08-run-webhook-shared-path-test.sh` | Two repos whose webhooks share one receiver URL: pushes to both at once, checks neither GitRepo reacts to the other's push |

`02` can end with `FAILED` and a message like `Operation cannot be fulfilled
on bundles.fleet.cattle.io ... the object has been modified`. That is what
the test is designed to catch (an update conflict in Fleet), not a problem
with your setup.

## Results

All runs of one Fleet version on one day go to the same folder:

```text
scripts/testresults/<fleet version>_<date>/<test>.jsonl
```

For example `0.17.0-alpha.7_2026-10-15/02_race_condition.jsonl`. A test run
again on the same day gets its start time added, e.g.
`02_race_condition_14-05-31.jsonl`. Dates and times are local time. Each
file is JSON Lines: one JSON object per line, a timeline of what happened.

The last lines give the verdict. The `summary` line has `"status"` set to
`PASSED`, `FAILED` or `ERROR` (the test stopped before reaching its own
check), what was expected and what was found, and the run details: Fleet
version and image, agent versions, Kubernetes version, number of clusters and
bundles. To list the verdicts of all runs:

```bash
jq -r 'select(.event=="summary") | "\(.scenario) \(.status)"' scripts/testresults/*/*.jsonl
```

The `ts` fields inside the files are UTC.

### Publishing results

Results stay on your machine until you publish them. To publish, clone your
results repo (one folder per setup, e.g. `local/` and `aws/`) and run:

```bash
RESULTS_REPO_DIR=<clone of your results repo> \
  ../publish-results.sh local scripts/testresults/<fleet version>_<date>
```

It copies the `.jsonl` files to `local/<fleet version>_<date>/` in that repo,
commits and **pushes right away**. To publish automatically after a full run,
export `RESULTS_REPO_DIR` before `./scripts/new-tests/run-all.sh`.

## Fleet version

`scripts/VERSION` holds the Fleet version to install and test. To test another
version on running clusters, change it and run `10-setup-fleet.sh` again. It
upgrades Fleet in place, and the downstream agents follow within a minute. You
don't need to register the clusters again.

```bash
echo "0.17.0" > scripts/VERSION
./scripts/10-setup-fleet.sh
helm list -n cattle-fleet-system        # check what is installed
```

Each results file records which version it was run on, and the results
folder is named after `scripts/VERSION`. If that file does not match what is
installed, the test prints `WARNING: VER=... but installed fleet-controller
is ...`; fix the file (or run `10-setup-fleet.sh`) before going on. For a single run
without editing the file, set `VER` instead:
`VER=0.17.0 ./scripts/10-setup-fleet.sh`.

## Number of clusters

`cluster_count` in `terraform.tfvars` is the only place to set it. The tests
count the registered clusters at startup (override with `CLUSTERS=N`). After
changing it, run `tofu apply` and then `./scripts/20-register-agents.sh`
again. Errors about secrets that already exist are harmless.

Each cluster is a k3s container, so 50 clusters means 51 containers and a lot
of RAM (in our tries, about 25 GB while idle, and not all of them came up on a
31 GB machine). Start with 10.

## Settings

Everything about Gitea is set in `scripts/new-tests/lib/config.sh`. Each value
can be overridden per run with an environment variable, for example
`GITEA_ORG=acme ./scripts/new-tests/run-all.sh`. If you change them, use the
same values for `setup-gitea.sh`, `seed-test-repo.sh` and the tests.

| Variable | Default | Meaning |
|---|---|---|
| `GITEA_HOST_URL` | `http://localhost:3000` | Gitea as seen from your machine (git push, API) |
| `GITEA_ORG` | `fleet-e2e-gitea` | Organization (or user) that owns the repos |
| `GITEA_REPO_A` | `fleet-e2e` | Main test repo |
| `GITEA_REPO_B` | `fleet-e2e-2` | Second repo, used by test 08 |
| `GITEA_CLUSTER_HOST` | `gitea.qa.local` | Name the clusters use for Gitea. Must match Gitea's `DOMAIN` and `ROOT_URL` |
| `GITEA_CLUSTER_URL` | `http://gitea.qa.local:3000` | Gitea as seen from inside the clusters |
| `FETCH_REPO_URL` | repo A | What tests 01, 03 and 05 fetch from (any repo the clusters can reach, filled with `seed-test-repo.sh`, branch `main`) |
| `GITEA_CLUSTER_IP` | gateway of the k3d docker network | The IP the clusters use to reach your machine (`setup-gitea.sh`) |
| `WEBHOOK_HOST_IP` | first IP from `hostname -I` | The IP Gitea uses to reach the clusters (`setup-gitea.sh`) |
| `WEBHOOK_PORT` | `8080` | Host port that leads to the upstream cluster's ingress (`first_app_http_port` in `terraform.tfvars`) |

The tests only ever push to `GITEA_HOST_URL`; they refuse any other address.

## How the tests behave

- Before each test starts, it deletes any GitRepo left over from an earlier
  run, and waits until everything belonging to it is gone.
- Every wait has a time limit, so a test never hangs: 15 minutes in general
  and 8 minutes for deletions. If it runs out, the test ends with `FAILED` and
  says what it was waiting for. Change the limits per run with
  `WAIT_TIMEOUT_SECONDS=1800` or `DELETE_TIMEOUT_SECONDS=600`.
- If a test stops for any other reason (an error, Ctrl-C), its results file
  still ends with a summary, with status `ERROR`.
- If `KUBECONFIG` is missing or points at the wrong cluster, a test stops
  immediately and says so. If `GITEA_TOKEN` is missing, the tests that push
  stop with a message about the token.
- At the start of a run, the test warns if `scripts/VERSION` doesn't match the
  Fleet version that is actually installed.
