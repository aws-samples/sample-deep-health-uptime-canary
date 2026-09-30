# Contract test

`contract_test.py` validates that a `/health/deep` handler meets the deep-health
contract before you wire it into the canary. Standard library only — no installs.

## Run it

```bash
# Happy path — expect 200 {status:ok, latencyMs} within the SLO
python3 contract_test.py --url https://app.example.com/health/deep --slo-ms 3000

# Failure path — expect 503 {status:degraded} (point at a handler with a paused dependency)
python3 contract_test.py --url https://app.example.com/health/deep --expect-degraded
```

## What it checks

| Check | Healthy run | `--expect-degraded` run |
|---|---|---|
| JSON well-formed | ✓ | ✓ |
| Status code | 200 | 503 |
| `status` field | `"ok"` | `"degraded"` |
| Required keys (`status`, `latencyMs`) | ✓ | — |
| `latencyMs` numeric | ✓ | — |
| Round trip within SLO | ✓ | — |
| `Cache-Control` prevents caching (`no-store`/`no-cache`/`private`) | ✓ | ✓ |

Exit code `0` = contract satisfied, non-zero = violation — so it drops straight
into CI (GitLab CI, GitHub Actions) as a gate on new handlers.

## Failure-demo scripts (sample app only)

Prove the alerting path end to end by inducing a **real** dependency failure and
then recovering — against the serverless sample app.

> **Scope: these scripts work only with the bundled [`sample-app/`](../sample-app/).**
> They delete and re-seed a DynamoDB sentinel item whose table and key schema are
> specific to that sample, so they cannot break your own application's dependency.
> Both scripts `describe-table` first and **refuse to run** if the target isn't keyed
> like the sample app's table — so a mistyped `--table` cannot modify one of your
> tables. See [Demoing a failure against your own app](#demoing-a-failure-against-your-own-app)
> below.

```bash
# Break it: delete the DynamoDB sentinel item → /health/deep returns 503.
bash test/break-dependency.sh            # auto-discovers the sample-app table

# …watch the canary fail and the availability alarm fire (SNS email), then:

# Restore it: re-seed the sentinel → /health/deep returns 200, alarm clears.
bash test/restore-dependency.sh
```

Run with no arguments and both scripts **prompt** for whatever isn't already set — the
region (unless `--region`/`AWS_REGION` is set, in which case the configured region is
offered as the default), the table, and the stack to discover it from. Pass
`--table <name>` to skip discovery entirely; otherwise the table is discovered from the
target stack's `HealthTableName` output, then from the deterministic `<root-stack>-health`
name, then from that stack's own nested stacks (never any other stack in the account).
Other flags: `--sample-stack <root-stack-name>`, `--sentinel-id`, `--region`.

Passing `--table` and `--region` makes a run fully non-interactive; so does piping from
anything other than a terminal, which skips the prompts and relies on flags plus
discovery — safe for CI.

If `break-dependency.sh` reports that the sentinel is already absent, the dependency is
already broken from a previous run — the script says so rather than silently succeeding
(DynamoDB's `delete-item` returns success for a key that doesn't exist, which would
otherwise make the script claim a 503 it didn't cause).

## Demoing a failure against your own app

The scripts above don't apply to your own endpoint. Two ways to exercise the same
alarm + SNS path against it:

| Approach | How | Touches your backend? |
|---|---|---|
| **Latency breach** (recommended) | Redeploy with a deliberately tight budget: `bash deploy.sh --target-url <your-url> --slo-ms 1`. Healthy responses now exceed the SLO, so the canary fails, the latency alarm fires after 2 of 3 runs, and you get the SNS email. Redeploy with your real `SloMs` to recover. | No |
| **Real dependency failure** | Briefly break what your health endpoint probes — revoke the reader's IAM permission, point it at an unreachable host, or stop the replica. The handler returns `503 {"status":"degraded"}` and the availability alarm fires on the first failed run. | Yes |

Use the latency route in any environment you care about: it proves the canary, both
alarms, the dashboard and the notification path without going near your data. Save the
dependency-failure route for a staging environment.

## Repository self-checks

`repo_checks.py` validates the things that drift silently and that `cfn-lint` can't see.
Standard library only, no AWS calls, no credentials:

```bash
python3 test/repo_checks.py
```

| Check | What it catches |
|---|---|
| `canary-sync` | The canary logic lives in two places — [`canary/deep-health.js`](../canary/deep-health.js) (source of truth) and the inline `Script:` block in `deep-health-uptime.yaml`. Fails if they diverge (comments ignored). |
| `dashboard-json` | The dashboard is JSON embedded in a YAML `!Sub`. Renders it, parses it, and verifies every `${...}` resolves to a declared parameter — so a typo can't ship a broken dashboard. |
| `nested-params` | Every parameter the root stack passes to a nested stack is actually declared by that child template. Catches a parameter added to the child but never plumbed through the parent. |

Exit `0` = all pass. This runs in CI ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml))
alongside `cfn-lint`, `shellcheck`, `node --check`, and a Python compile pass.
