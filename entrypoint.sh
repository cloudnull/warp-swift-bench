#!/bin/sh
# Wraps `warp` with the settings an OpenStack Swift s3api endpoint needs.
#
# Environment (all read at run time, nothing is stored in the image):
#   WARP_HOST        Swift proxy host[:port], no scheme, no path   (required)
#   WARP_ACCESS_KEY  Keystone EC2 credential "access"              (required)
#   WARP_SECRET_KEY  Keystone EC2 credential "secret"              (required)
#   WARP_REGION      SigV4 region; must equal s3api `location`     (default us-east-1)
#   WARP_TLS         true|false                                    (default true)
#   WARP_BUCKET      bucket for benchmark data; ALL DATA IN IT IS DELETED
#                                                                  (default warp-benchmark-bucket)
#
# Usage:
#   entrypoint.sh [mode] [warp flags...]
#   mode is any warp benchmark (mixed, get, put, delete, list, stat, ...); default mixed.
#   analyze/cmp/merge/client are passed straight to warp and need no credentials.
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: docker run --rm -e WARP_HOST=... -e WARP_ACCESS_KEY -e WARP_SECRET_KEY \
           [-e WARP_REGION=...] [-e WARP_BUCKET=...] [-v "$PWD/results:/data"] \
           IMAGE [mode] [warp flags...]

  mode   warp benchmark: mixed (default), get, put, delete, list, stat, multipart, ...
  flags  anything warp accepts, e.g. --duration 2m --obj.size 4MiB --objects 500 --concurrent 16

Run `IMAGE mixed --help` to see every flag for a mode.
USAGE
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

# First non-flag argument is the warp mode; default to mixed.
mode=mixed
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
  mode="$1"
  shift
fi

# Local-only subcommands: no endpoint, no credentials.
case "$mode" in
  analyze|cmp|merge|client) exec warp "$mode" "$@" ;;
esac

# Pass-through of a mode's own --help without demanding credentials.
for arg in "$@"; do
  case "$arg" in
    -h|--help) exec warp "$mode" --help ;;
  esac
done

missing=0
for v in WARP_HOST WARP_ACCESS_KEY WARP_SECRET_KEY; do
  if [ -z "$(eval "printf '%s' \"\${$v:-}\"")" ]; then
    echo "error: $v is not set" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  usage
  exit 2
fi

case "$WARP_HOST" in
  http://*|https://*)
    echo "error: WARP_HOST must be host[:port] without a scheme; TLS is controlled by WARP_TLS" >&2
    exit 2 ;;
esac

bucket="${WARP_BUCKET:-warp-benchmark-bucket}"

# Swift's s3api only serves path-style requests (/<bucket>/<key>); there is no
# wildcard DNS or certificate for <bucket>.<host>. Host, keys, TLS and region
# come from WARP_* env vars that warp reads itself. Flags placed before "$@"
# so anything the caller passes wins.
set -- --lookup path --bucket "$bucket" "$@"

echo "warp ${mode}: host=${WARP_HOST} tls=${WARP_TLS:-true} region=${WARP_REGION:-us-east-1} bucket=${bucket}" >&2
exec warp "$mode" "$@"
