#!/usr/bin/env bash
# run-matrix.sh - run the AI-workload warp matrix against a Swift s3api
# endpoint, then aggregate every result file into one summary.
#
# Usage: ./run-matrix.sh [options]
#   -s, --smoke           10s runs, objects = max(8, 2 x concurrency); validates the whole pipeline
#   -o, --only GLOB       run only variants whose id matches GLOB (repeatable), e.g. 'kv-*'
#   -d, --duration DUR    per-run duration (default 2m)
#   -r, --results DIR     results root (default ./results); each run writes DIR/<timestamp>/
#   -a, --aggregate DIR   skip the benchmarks and aggregate an existing run directory
#   -l, --list            print the matrix and exit
#   -h, --help
#
# Environment (same names the image uses):
#   WARP_HOST, WARP_REGION, WARP_ACCESS_KEY, WARP_SECRET_KEY   required for benchmarks
#   IMAGE                                                     default warp-swift-bench
#
# Every run writes <id>.json.zst and <id>.log into the run directory, plus
# manifest.tsv describing each variant. Aggregation writes analysis/<id>.json
# (warp analyze --json), summary.csv and summary.md.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE=${IMAGE:-warp-swift-bench}
DURATION=2m
RESULTS_ROOT=$HERE/results
SMOKE=0
AGGREGATE_ONLY=
ONLY=()

# ---------------------------------------------------------------------------
# The matrix. Fields: id | mode | bucket | obj.size | objects | concurrent | extra flags
#
# get-mode rows that share a bucket are preloaded once: the first row uploads
# with --noclear, later rows reuse the objects with --list-existing, and the
# bucket is emptied when the group is done. Everything else uses warp's
# default clear-before/clear-after behaviour in warp-benchmark-bucket.
# ---------------------------------------------------------------------------
KV_DIST='--put-distrib 40 --get-distrib 40 --stat-distrib 10 --delete-distrib 10'
MATRIX=(
  # KV-cache offload (LMCache): PUT-heavy mixed, sizes around a real chunk.
  "kv-8mib-c8        |mixed|warp-benchmark-bucket|8MiB  |200  |8 |$KV_DIST"
  "kv-8mib-c16       |mixed|warp-benchmark-bucket|8MiB  |200  |16|$KV_DIST"
  "kv-32mib-c8       |mixed|warp-benchmark-bucket|32MiB |200  |8 |$KV_DIST"
  "kv-32mib-c16      |mixed|warp-benchmark-bucket|32MiB |200  |16|$KV_DIST"
  "kv-32mib-c8-nomp  |mixed|warp-benchmark-bucket|32MiB |200  |8 |$KV_DIST --disable-multipart"
  "kv-32mib-c16-nomp |mixed|warp-benchmark-bucket|32MiB |200  |16|$KV_DIST --disable-multipart"
  "kv-64mib-c8       |mixed|warp-benchmark-bucket|64MiB |100  |8 |$KV_DIST"
  "kv-64mib-c16      |mixed|warp-benchmark-bucket|64MiB |100  |16|$KV_DIST"
  "kv-64mib-c8-nomp  |mixed|warp-benchmark-bucket|64MiB |100  |8 |$KV_DIST --disable-multipart"
  "kv-64mib-c16-nomp |mixed|warp-benchmark-bucket|64MiB |100  |16|$KV_DIST --disable-multipart"
  # Model weights: large sequential GET, then ranged GET like a safetensors loader.
  "wt-1gib-c4        |get  |warp-get-1gib        |1GiB  |8    |4 |"
  "wt-1gib-c8        |get  |warp-get-1gib        |1GiB  |8    |8 |"
  "wt-1gib-c4-range64|get  |warp-get-1gib        |1GiB  |8    |4 |--range-size 64MiB"
  "wt-1gib-c8-range64|get  |warp-get-1gib        |1GiB  |8    |8 |--range-size 64MiB"
  # Training data: tokenized/WebDataset shards, then variable-size raw samples.
  "ds-shard-256mib-c32|get |warp-get-256mib      |256MiB|64   |32|"
  "ds-sample-4mib-c32|get  |warp-get-4mib        |4MiB  |2000 |32|--obj.randsize"
  "ds-sample-4mib-c64|get  |warp-get-4mib        |4MiB  |2000 |64|--obj.randsize"
  # Metadata and index traffic: small objects, latency-bound, plus listing.
  "meta-4kib-c32     |mixed|warp-benchmark-bucket|4KiB  |5000 |32|"
  "meta-64kib-c32    |mixed|warp-benchmark-bucket|64KiB |5000 |32|"
  "list-1kib-c16     |list |warp-benchmark-bucket|1KiB  |10000|16|"
)

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

die() { echo "error: $*" >&2; exit 1; }

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

parse_row() {
  # Sets R_ID R_MODE R_BUCKET R_SIZE R_OBJECTS R_CONC R_EXTRA from a matrix row.
  local IFS='|'
  read -r R_ID R_MODE R_BUCKET R_SIZE R_OBJECTS R_CONC R_EXTRA <<<"$1"
  R_ID=$(trim "$R_ID"); R_MODE=$(trim "$R_MODE"); R_BUCKET=$(trim "$R_BUCKET")
  R_SIZE=$(trim "$R_SIZE"); R_OBJECTS=$(trim "$R_OBJECTS"); R_CONC=$(trim "$R_CONC")
  R_EXTRA=$(trim "${R_EXTRA:-}")
}

selected() {
  # True when the id matches any --only glob (or no globs were given).
  local id=$1 g
  [ ${#ONLY[@]} -eq 0 ] && return 0
  for g in "${ONLY[@]}"; do
    # shellcheck disable=SC2053
    [[ $id == $g ]] && return 0
  done
  return 1
}

list_matrix() {
  printf '%-20s %-6s %-22s %-7s %-6s %-5s %s\n' ID MODE BUCKET SIZE OBJS CONC EXTRA
  for row in "${MATRIX[@]}"; do
    parse_row "$row"
    selected "$R_ID" || continue
    printf '%-20s %-6s %-22s %-7s %-6s %-5s %s\n' "$R_ID" "$R_MODE" "$R_BUCKET" "$R_SIZE" "$R_OBJECTS" "$R_CONC" "$R_EXTRA"
  done
}

warp() {
  # warp BUCKET MODE ARGS... -> runs the image with credentials from the environment.
  local bucket=$1 mode=$2; shift 2
  docker run --rm \
    -e WARP_HOST -e WARP_REGION -e WARP_ACCESS_KEY -e WARP_SECRET_KEY \
    -e WARP_BUCKET="$bucket" \
    -v "$RUN_DIR:/data" \
    "$IMAGE" "$mode" --no-color "$@"
}

clear_bucket() {
  # A 1-second stat run without --noclear empties the bucket before and after.
  echo "    clearing bucket $1"
  # --benchdata goes to the container's /tmp so the clearing run leaves no result file behind.
  warp "$1" stat --objects 1 --obj.size 1KiB --duration 1s --concurrent 1 --benchdata /tmp/warp-clear >/dev/null 2>&1 || true
}

declare -A PRELOADED=()

cleanup_buckets() {
  local b
  for b in "${!PRELOADED[@]}"; do clear_bucket "$b"; done
  PRELOADED=()
}

need_credentials() {
  local v
  for v in WARP_HOST WARP_REGION WARP_ACCESS_KEY WARP_SECRET_KEY; do
    if [ -z "${!v:-}" ]; then
      if [ -t 0 ]; then
        case $v in
          *KEY) read -rs -p "$v: " "$v"; echo ;;
          *)    read -r  -p "$v: " "$v" ;;
        esac
        export "$v"
      fi
      [ -n "${!v:-}" ] || die "$v is not set"
    fi
  done
}

run_matrix() {
  need_credentials
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE not found; run: docker build -t $IMAGE $HERE"

  # Not "$( [ ... ] && echo )": under set -e a failed test inside a bare
  # assignment's command substitution silently ends the script.
  local suffix=
  if [ "$SMOKE" = 1 ]; then suffix=-smoke; fi
  RUN_DIR=$RESULTS_ROOT/$(date -u +%Y%m%dT%H%M%SZ)$suffix
  mkdir -p "$RUN_DIR"
  echo "run directory: $RUN_DIR"
  printf 'id\tmode\tbucket\tobj_size\tobjects\tconcurrent\textra\tstatus\tseconds\n' >"$RUN_DIR/manifest.tsv"
  trap cleanup_buckets EXIT

  local total=0 n=0 failed=0 row
  for row in "${MATRIX[@]}"; do parse_row "$row"; selected "$R_ID" && total=$((total+1)); done
  [ "$total" -gt 0 ] || die "no variants match ${ONLY[*]}"

  for row in "${MATRIX[@]}"; do
    parse_row "$row"
    selected "$R_ID" || continue
    n=$((n+1))

    local objects=$R_OBJECTS duration=$DURATION
    if [ "$SMOKE" = 1 ]; then
      # warp mixed refuses to start unless objects exceed the worker count.
      duration=10s
      objects=$(( R_CONC * 2 > 8 ? R_CONC * 2 : 8 )); [ "$R_MODE" = list ] && objects=200
    fi

    local -a args=(--duration "$duration" --obj.size "$R_SIZE" --concurrent "$R_CONC" --benchdata "/data/$R_ID")
    # shellcheck disable=SC2206
    [ -n "$R_EXTRA" ] && args+=($R_EXTRA)

    if [ "$R_MODE" = get ] && [ "$R_BUCKET" != warp-benchmark-bucket ]; then
      if [ -z "${PRELOADED[$R_BUCKET]:-}" ]; then
        clear_bucket "$R_BUCKET"
        PRELOADED[$R_BUCKET]=1
        args+=(--noclear --objects "$objects")
      else
        args+=(--noclear --list-existing)
      fi
    else
      args+=(--objects "$objects")
    fi

    printf '[%2d/%d] %-20s %s %s' "$n" "$total" "$R_ID" "$R_MODE" "${args[*]}"
    echo
    local start=$SECONDS status=ok rc=0
    warp "$R_BUCKET" "$R_MODE" "${args[@]}" >"$RUN_DIR/$R_ID.log" 2>&1 || rc=$?
    # warp writes the result file before its final bucket clear, and a sporadic
    # error there makes it exit non-zero; the data is what matters.
    if [ ! -s "$RUN_DIR/$R_ID.json.zst" ]; then
      status=FAILED; failed=$((failed+1))
    elif [ "$rc" -ne 0 ]; then
      echo "    warp exited $rc after writing results; see $R_ID.log"
    fi
    local secs=$((SECONDS-start))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$R_ID" "$R_MODE" "$R_BUCKET" "$R_SIZE" "$objects" "$R_CONC" "$R_EXTRA" "$status" "$secs" >>"$RUN_DIR/manifest.tsv"
    if [ "$status" = ok ]; then
      # Single-op modes print one "Report: <OP>"; mixed ends with "Report: Total". The last Average line is the summary either way.
      printf '    ok in %ss: %s\n' "$secs" "$(grep ' \* Average:' "$RUN_DIR/$R_ID.log" | tail -1 | sed 's/^ *//')"
    else
      printf '    FAILED in %ss: %s\n' "$secs" "$(grep -m1 -E 'ERROR|error' "$RUN_DIR/$R_ID.log" || echo 'see log')"
    fi
  done

  cleanup_buckets
  # Sporadic auth errors from the endpoint can abort warp's own final clear,
  # so sweep the shared bucket once more before reporting.
  clear_bucket warp-benchmark-bucket
  trap - EXIT
  echo "benchmarks done: $((n-failed)) ok, $failed failed"
  aggregate "$RUN_DIR"
}

aggregate() {
  local dir=$1 f id
  [ -d "$dir" ] || die "no such run directory: $dir"
  mkdir -p "$dir/analysis"
  local count=0
  for f in "$dir"/*.json.zst; do
    [ -e "$f" ] || break
    id=$(basename "$f" .json.zst)
    docker run --rm -v "$dir:/data:ro" "$IMAGE" analyze --json "/data/$id.json.zst" >"$dir/analysis/$id.json" \
      || { echo "warning: analyze failed for $id" >&2; rm -f "$dir/analysis/$id.json"; continue; }
    count=$((count+1))
  done
  [ "$count" -gt 0 ] || die "no result files in $dir"
  echo "analyzed $count result files"
  python3 "$HERE/aggregate.py" "$dir"
}

while [ $# -gt 0 ]; do
  case $1 in
    -s|--smoke) SMOKE=1 ;;
    -o|--only) ONLY+=("$2"); shift ;;
    -d|--duration) DURATION=$2; shift ;;
    -r|--results) RESULTS_ROOT=$(cd "$2" 2>/dev/null && pwd) || die "no such directory: $2"; shift ;;
    -a|--aggregate) AGGREGATE_ONLY=$(cd "$2" 2>/dev/null && pwd) || die "no such directory: $2"; shift ;;
    -l|--list) list_matrix; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

if [ -n "$AGGREGATE_ONLY" ]; then
  aggregate "$AGGREGATE_ONLY"
else
  run_matrix
fi
