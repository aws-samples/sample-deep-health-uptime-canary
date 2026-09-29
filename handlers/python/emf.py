"""
emf.py — tiny CloudWatch EMF (Embedded Metric Format) helper for the
/health/deep reference handlers (Python).

WHY: the canary measures the FULL end-to-end time a user waits, but from its
outside vantage that number is opaque — you can't tell cold start from a slow
dependency query. Emitting a few metrics from INSIDE the app breaks it down so
you can see WHY latency is high:
    DbQueryMs   — the dependency probe round-trip (the handler already measures this)
    TotalMs     — total in-handler time

For COLD-START time, read Lambda's own `@initDuration` (REPORT log line) via
CloudWatch Logs Insights — the authoritative number, no app code required. See
DEPLOYMENT.md. We deliberately do NOT synthesize a cold-start metric in-handler.

These are DIAGNOSTIC only. The uptime SLO is still judged end-to-end by the
canary — these metrics just explain the number, they don't change it.

EMF = a specially structured JSON log line. CloudWatch auto-extracts the metrics
from it — no put_metric_data call, no extra request latency, no SDK dependency.
Works on Lambda out of the box; on ECS/EKS send stdout to CloudWatch Logs
(awslogs/Fluent Bit) with the log group configured.

DbQueryMs/TotalMs populate on any compute (Lambda, EC2, ECS, Fargate) and give the
meaningful app-vs-dependency split.

Namespace: DeepHealth/Breakdown, dimension Service (default 'deep-health').
Override via env METRIC_NAMESPACE / METRIC_SERVICE.
"""
import json
import os
import time

def emit_breakdown(db_query_ms: int, total_ms: int, **extra) -> None:
    """Emit latency-breakdown metrics via EMF.

    db_query_ms: dependency probe round-trip (ms)
    total_ms:    total in-handler time (ms)
    extra:       extra properties to log (not turned into metrics)
    """
    ns = os.environ.get("METRIC_NAMESPACE", "DeepHealth/Breakdown")
    service = os.environ.get("METRIC_SERVICE", "deep-health")
    names = [{"Name": "DbQueryMs", "Unit": "Milliseconds"}, {"Name": "TotalMs", "Unit": "Milliseconds"}]
    rec = {"Service": service, "DbQueryMs": db_query_ms, "TotalMs": total_ms, **extra}
    rec["_aws"] = {
        "Timestamp": int(time.time() * 1000),
        "CloudWatchMetrics": [{"Namespace": ns, "Dimensions": [["Service"]], "Metrics": names}],
    }
    print(json.dumps(rec))
