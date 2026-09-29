"""
emf.py — tiny CloudWatch EMF (Embedded Metric Format) helper for the
/health/deep reference handlers (Python).

WHY: the canary measures the FULL end-to-end time a user waits, but from its
outside vantage that number is opaque — you can't tell cold start from a slow
dependency query. Emitting a few metrics from INSIDE the app breaks it down so
you can see WHY latency is high:
    ColdStartMs — Lambda init/cold-start overhead (emitted only on the cold invoke)
    DbQueryMs   — the dependency probe round-trip (the handler already measures this)
    TotalMs     — total in-handler time

These are DIAGNOSTIC only. The uptime SLO is still judged end-to-end by the
canary — these metrics just explain the number, they don't change it.

EMF = a specially structured JSON log line. CloudWatch auto-extracts the metrics
from it — no put_metric_data call, no extra request latency, no SDK dependency.
Works on Lambda out of the box; on ECS/EKS send stdout to CloudWatch Logs
(awslogs/Fluent Bit) with the log group configured.

COLD START (Lambda-only): cold_start_ms() returns the container init time on the
FIRST call of a fresh container and 0 thereafter — so it maps to a real Lambda cold
start. EC2/ECS/Fargate run long-lived processes with NO per-request cold start, so it
fires at most once per task launch (usually before the load balancer sends traffic)
and is 0 after — i.e. ColdStartMs correctly shows no data there. DbQueryMs/TotalMs
still populate, which is the meaningful app-vs-DB split.

Namespace: DeepHealth/Breakdown, dimension Service (default 'deep-health').
Override via env METRIC_NAMESPACE / METRIC_SERVICE.
"""
import json
import os
import time

_INIT_START = time.monotonic()  # module load == container init begins
_init_reported = False


def cold_start_ms() -> int:
    """Milliseconds spent initialising this container, reported once (0 afterwards)."""
    global _init_reported
    if _init_reported:
        return 0
    _init_reported = True
    return int((time.monotonic() - _INIT_START) * 1000)


def emit_breakdown(db_query_ms: int, total_ms: int, cold_ms: int = 0, **extra) -> None:
    """Emit latency-breakdown metrics via EMF.

    db_query_ms: dependency probe round-trip (ms)
    total_ms:    total in-handler time (ms)
    cold_ms:     cold-start ms; omit/0 to skip (use cold_start_ms())
    extra:       extra properties to log (not turned into metrics)
    """
    ns = os.environ.get("METRIC_NAMESPACE", "DeepHealth/Breakdown")
    service = os.environ.get("METRIC_SERVICE", "deep-health")
    names = [{"Name": "DbQueryMs", "Unit": "Milliseconds"}, {"Name": "TotalMs", "Unit": "Milliseconds"}]
    rec = {"Service": service, "DbQueryMs": db_query_ms, "TotalMs": total_ms, **extra}
    if cold_ms > 0:
        names.append({"Name": "ColdStartMs", "Unit": "Milliseconds"})
        rec["ColdStartMs"] = cold_ms
    rec["_aws"] = {
        "Timestamp": int(time.time() * 1000),
        "CloudWatchMetrics": [{"Namespace": ns, "Dimensions": [["Service"]], "Metrics": names}],
    }
    print(json.dumps(rec))
