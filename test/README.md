# Contract test

`contract_test.py` validates that a `/health/deep` handler meets the deep-health
contract before you wire it into the canary. Standard library only — no installs.

## Run it

```bash
# Happy path — expect 200 {status:ok, latencyMs} within the SLO
python contract_test.py --url https://app.example.com/health/deep --slo-ms 3000

# Failure path — expect 503 {status:degraded} (point at a handler with a paused dependency)
python contract_test.py --url https://app.example.com/health/deep --expect-degraded
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

Exit code `0` = contract satisfied, non-zero = violation — so it drops straight
into CI (GitLab CI, GitHub Actions) as a gate on new handlers.

## Failure-demo scripts (sample app)

Prove the alerting path end to end by inducing a **real** dependency failure and
then recovering — against the serverless sample app.

```bash
# Break it: delete the DynamoDB sentinel item → /health/deep returns 503.
bash test/break-dependency.sh            # auto-discovers the sample-app table

# …watch the canary fail and the availability alarm fire (SNS email), then:

# Restore it: re-seed the sentinel → /health/deep returns 200, alarm clears.
bash test/restore-dependency.sh
```

Both auto-discover the table by scanning the stack's `HealthTableName` output (including nested stacks under the root deploy)
(`HealthTableName`). If you deployed via the root/nested stack, pass the table
explicitly with `--table <name>` (find it with `aws dynamodb list-tables`), or
`--sample-stack <nested-stack-name>`. Other flags: `--sentinel-id`, `--region`.

> Tip: this is the "realistic outage" demo. For a quick **latency**-based failure
> instead, redeploy with a tight budget (`--slo-ms 100`) so passing responses
> breach the SLO — see the main README.
