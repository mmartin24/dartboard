# new-tests

The test scripts, in the order you would run them. How to set everything up
and run the tests is in the [main README](../../../README.md); this page only
describes what is in this folder.

| File | What it is |
|---|---|
| `run-all.sh` | Runs tests 01 to 08 one after another |
| `01-...` to `08-...` | The tests, one script each (see the table in the main README). Values such as the number of bundles are at the top of each script |
| `setup-gitea.sh` | Creates the Gitea repos and webhooks and prepares the cluster to reach Gitea |
| `seed-test-repo.sh` | Fills a Gitea repo with the content the tests use |
| `install-gitea-in-cluster.sh` | AWS only: runs Gitea as a pod in the upstream cluster and prints the settings the other scripts need |
| `manifests/` | The GitRepo definitions the tests apply. They contain placeholders such as `${GITEA_ORG}` that are filled in from `lib/config.sh` |
| `lib/config.sh` | Gitea names and URLs, with defaults you can override (table in the main README) |
| `lib/results.sh` | Results files, verdicts, wait time limits and cleanup of leftovers |
| `lib/gitrepo-commits.sh` | Pushing commits to your Gitea (tests 02, 04, 07, 08) |

## Reading a test script

Each test reads from top to bottom: plain `kubectl` commands and `while`
loops that print a dot every few seconds while waiting. `emit_event "text"`
prints `text: <time>` and also adds a line to the results file. A wait loop
has `wait_start` before it and `wait_check "what"` inside it, which ends the
test with `FAILED` when the time limit is reached.

A test ends by calling `results_summary pass|fail "<expected>" "<actual>"`,
which prints

```text
EXPECTED: ...
RESULT:   ...
STATUS:   PASSED
```

and writes the same into the results file.

## Applying a manifest by hand

From `qa/` (`bash -c`, because `lib/config.sh` is bash):

```bash
bash -c 'source local/scripts/new-tests/lib/config.sh
  render_manifest local/scripts/new-tests/manifests/gitrepo-single-race.yaml | kubectl apply -f -'
```

## Checking test 02 wave by wave

Each wave of test 02 logs a line ending in `all 50 bundles matched` when the
new commit reached every bundle:

```bash
grep "bundles matched" local/scripts/testresults/*/02_race_condition*.jsonl
```

You should see one line per wave. If a wave hits its time limit, the test
stops there with a `TIMEOUT` event that names the stuck bundles.
