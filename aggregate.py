#!/usr/bin/env python3
"""Aggregate warp results from one run directory into TPS and per-operation tables.

Inputs:  <run_dir>/analysis/<id>.json   from `warp analyze --json`
         <run_dir>/manifest.tsv         variant metadata written by run-matrix.sh (optional)
Outputs: <run_dir>/tps.csv              one row per variant
         <run_dir>/summary.csv          one row per variant and operation
         <run_dir>/summary.md           both tables, also printed to stdout

TPS is transactions per second: successful S3 operations completed per second
inside warp's trimmed measurement window. A multipart upload counts as one PUT
transaction, however many parts it takes, so s3api sees more HTTP requests
than this number for objects above the multipart threshold.
"""
import csv
import json
import os
import re
import sys

READ_OPS = {"GET", "STAT", "HEAD"}
WRITE_OPS = {"PUT", "DELETE", "POST", "MULTIPART"}
LIST_OPS = {"LIST"}

TPS_COLUMNS = [
    "id", "mode", "obj_size", "objects", "concurrent", "extra",
    "tps", "read_tps", "write_tps", "list_tps", "mib_s", "requests", "errors", "window_s", "first_error",
]
OP_COLUMNS = [
    "id", "op", "mode", "obj_size", "objects", "concurrent", "extra",
    "requests", "errors", "tps", "mib_s", "obj_s",
    "median_mib_s", "slowest_mib_s",
    "lat_avg_ms", "lat_p50_ms", "lat_p90_ms", "lat_p99_ms", "lat_max_ms",
    "ttfb_p50_ms", "ttfb_p99_ms",
]
TPS_MD = [
    ("id", "variant"), ("mode", "mode"), ("obj_size", "size"), ("concurrent", "conc"),
    ("tps", "TPS"), ("read_tps", "read TPS"), ("write_tps", "write TPS"), ("list_tps", "list TPS"),
    ("mib_s", "MiB/s"), ("errors", "errs"),
]
OP_MD = [
    ("id", "variant"), ("op", "op"), ("obj_size", "size"), ("concurrent", "conc"),
    ("tps", "TPS"), ("mib_s", "MiB/s"), ("obj_s", "obj/s"),
    ("lat_avg_ms", "avg ms"), ("lat_p50_ms", "p50"), ("lat_p90_ms", "p90"), ("lat_p99_ms", "p99"),
    ("ttfb_p50_ms", "TTFB p50"), ("ttfb_p99_ms", "TTFB p99"), ("errors", "errs"),
]
TEXT_KEYS = {"id", "op", "mode", "obj_size", "extra"}


def read_manifest(run_dir):
    path = os.path.join(run_dir, "manifest.tsv")
    if not os.path.exists(path):
        return {}
    with open(path, newline="") as fh:
        return {row["id"]: row for row in csv.DictReader(fh, delimiter="\t")}


def meta_from_commandline(cmd):
    """Fallback when there is no manifest: pull the basics out of warp's recorded command line."""
    def flag(name, default=""):
        m = re.search(r"--%s=(\S+)" % re.escape(name), cmd)
        return m.group(1) if m else default
    parts = cmd.split()
    return {"mode": parts[1] if len(parts) > 1 else "", "obj_size": flag("obj.size"),
            "objects": flag("objects"), "concurrent": flag("concurrent"), "extra": ""}


def window_seconds(tp):
    return (tp.get("measure_duration_millis") or 0) / 1000.0


def per_second(tp, key):
    dur = window_seconds(tp)
    return (tp.get(key) or 0) / dur if dur else 0.0


def tps(tp):
    """Successful operations per second in the measurement window."""
    dur = window_seconds(tp)
    if not dur:
        return 0.0
    ok = (tp.get("ops") or 0) - (tp.get("errors") or 0)
    return max(ok, 0) / dur


def latency(op):
    """Flatten the per-request block into lat_*/ttfb_* milliseconds."""
    out = {}
    blocks = []
    for entries in (op.get("requests_by_client") or {}).values():
        blocks.extend(entries or [])
    if not blocks:
        return out
    blk = blocks[0]
    single = blk.get("single_sized_requests")
    multi = blk.get("multi_sized_requests")
    if single:
        out["lat_avg_ms"] = single.get("dur_avg_millis")
        out["lat_p50_ms"] = single.get("dur_median_millis")
        out["lat_p90_ms"] = single.get("dur_90_millis")
        out["lat_p99_ms"] = single.get("dur_99_millis")
        out["lat_max_ms"] = single.get("slowest_millis")
        fb = single.get("first_byte") or {}
        out["ttfb_p50_ms"] = fb.get("median_millis")
        out["ttfb_p99_ms"] = fb.get("p99_millis")
    elif multi:
        # --obj.randsize runs report per-size buckets with an average duration
        # but no duration percentiles; warp gives per-request throughput
        # percentiles instead. Derive durations as avg_obj_size / bps and
        # combine buckets weighted by request count.
        buckets = multi.get("by_size") or []
        total = sum(b.get("requests", 0) for b in buckets) or 1

        def wavg(getter):
            vals = [(b.get("requests", 0), getter(b)) for b in buckets]
            vals = [(n, v) for n, v in vals if v is not None]
            return sum(n * v for n, v in vals) / total if vals else None

        def dur_from_bps(b, key):
            bps, size = b.get(key) or 0, b.get("avg_obj_size") or 0
            return size / bps * 1000.0 if bps and size else None

        out["lat_avg_ms"] = wavg(lambda b: b.get("avg_duration_millis"))
        out["lat_p50_ms"] = wavg(lambda b: dur_from_bps(b, "bps_median"))
        out["lat_p90_ms"] = wavg(lambda b: dur_from_bps(b, "bps_90"))
        out["lat_p99_ms"] = wavg(lambda b: dur_from_bps(b, "bps_99"))
        maxes = [m for m in (dur_from_bps(b, "bps_slowest") for b in buckets) if m is not None]
        out["lat_max_ms"] = max(maxes) if maxes else None
        out["ttfb_p50_ms"] = wavg(lambda b: (b.get("first_byte") or {}).get("median_millis"))
        out["ttfb_p99_ms"] = wavg(lambda b: (b.get("first_byte") or {}).get("p99_millis"))
        out["lat_derived"] = True
    return out


def summarise(run_id, doc, meta):
    """Returns (variant_row, [op_rows])."""
    base = {"id": run_id, "mode": meta.get("mode", ""), "obj_size": meta.get("obj_size", ""),
            "objects": meta.get("objects", ""), "concurrent": meta.get("concurrent", ""),
            "extra": meta.get("extra", "")}
    op_rows = []
    read_tps = write_tps = list_tps = 0.0
    for op_name, op in sorted((doc.get("by_op_type") or {}).items()):
        if not op.get("total_requests"):
            continue
        tp = op.get("throughput") or {}
        seg = tp.get("segmented") or {}
        op_tps = tps(tp)
        if op_name in READ_OPS:
            read_tps += op_tps
        elif op_name in WRITE_OPS:
            write_tps += op_tps
        elif op_name in LIST_OPS:
            list_tps += op_tps
        row = dict(base, op=op_name,
                   requests=op.get("total_requests"), errors=op.get("total_errors"),
                   tps=op_tps,
                   mib_s=per_second(tp, "bytes") / 2 ** 20,
                   obj_s=per_second(tp, "objects"),
                   median_mib_s=(seg.get("median_bps") or 0) / 2 ** 20,
                   slowest_mib_s=(seg.get("slowest_bps") or 0) / 2 ** 20)
        row.update(latency(op))
        if row.get("lat_derived"):
            row["op"] = op_name + " *"
        op_rows.append(row)

    total = doc.get("total") or {}
    ttp = total.get("throughput") or {}
    variant = dict(base,
                   tps=tps(ttp), read_tps=read_tps, write_tps=write_tps, list_tps=list_tps,
                   mib_s=per_second(ttp, "bytes") / 2 ** 20,
                   requests=total.get("total_requests"), errors=total.get("total_errors"),
                   window_s=window_seconds(ttp),
                   first_error=(total.get("first_errors") or [""])[0])
    return variant, op_rows


def fmt(v):
    if v is None or v == "":
        return ""
    if isinstance(v, float):
        return "%.1f" % v if abs(v) >= 10 else "%.2f" % v
    return str(v)


def write_csv(path, columns, rows):
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=columns)
        w.writeheader()
        for r in rows:
            w.writerow({k: fmt(r.get(k)) for k in columns})


def md_table(spec, rows):
    lines = ["| " + " | ".join(h for _, h in spec) + " |",
             "|" + "|".join("---" if k in TEXT_KEYS else "---:" for k, _ in spec) + "|"]
    for r in rows:
        lines.append("| " + " | ".join(fmt(r.get(k)) for k, _ in spec) + " |")
    return lines


def main():
    if len(sys.argv) != 2:
        print("usage: aggregate.py RUN_DIR", file=sys.stderr)
        sys.exit(2)
    run_dir = sys.argv[1]
    analysis_dir = os.path.join(run_dir, "analysis")
    manifest = read_manifest(run_dir)

    files = sorted(f for f in os.listdir(analysis_dir) if f.endswith(".json"))
    order = {rid: i for i, rid in enumerate(manifest)}
    files.sort(key=lambda f: order.get(f[:-5], len(order)))

    variants, op_rows = [], []
    for f in files:
        run_id = f[:-5]
        with open(os.path.join(analysis_dir, f)) as fh:
            doc = json.load(fh)
        meta = manifest.get(run_id) or meta_from_commandline(doc.get("commandline", ""))
        v, ops = summarise(run_id, doc, meta)
        variants.append(v)
        op_rows.extend(ops)

    write_csv(os.path.join(run_dir, "tps.csv"), TPS_COLUMNS, variants)
    write_csv(os.path.join(run_dir, "summary.csv"), OP_COLUMNS, op_rows)

    failed = [rid for rid, m in manifest.items() if m.get("status") != "ok"]
    lines = ["# warp results: %s" % os.path.basename(os.path.abspath(run_dir)), ""]
    if failed:
        lines += ["Failed variants (no data): " + ", ".join(failed), ""]
    lines += ["## Transactions per second", "",
              "Successful S3 operations per second in warp's trimmed measurement window.",
              "read = GET + STAT, write = PUT + DELETE. A multipart upload is one PUT transaction.", ""]
    lines += md_table(TPS_MD, variants)
    lines += ["", "## Per-operation detail", "",
              "Latencies are per request in milliseconds; obj/s counts objects, which for LIST is entries returned.",
              "Rows marked * are random-size runs: p50/p90/p99 are derived from warp's per-request",
              "throughput percentiles and the average object size, not measured directly.", ""]
    lines += md_table(OP_MD, op_rows)
    errored = [v for v in variants if v.get("errors")]
    if errored:
        lines += ["", "## Errors", ""]
        for v in errored:
            lines.append("- %s: %s of %s requests failed; first: %s" % (
                v["id"], v["errors"], v.get("requests"), v.get("first_error") or "(no message recorded)"))
    lines += ["", "Files: tps.csv (per variant), summary.csv (per operation), analysis/<id>.json (raw warp analysis)."]
    md = "\n".join(lines) + "\n"
    with open(os.path.join(run_dir, "summary.md"), "w") as fh:
        fh.write(md)
    sys.stdout.write(md)


if __name__ == "__main__":
    main()
