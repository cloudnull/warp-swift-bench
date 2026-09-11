# warp-swift-bench

Runs [MinIO warp](https://github.com/minio/warp) against an OpenStack Swift
s3api endpoint. The image contains only warp; credentials are passed as
environment variables when the container starts and are gone when it exits.

## Build

```sh
docker build -t warp-swift-bench .
```

The Dockerfile downloads `warp` with wget from `dl.min.io`, verifies it
against the published SHA-256, and runs it as an unprivileged user.

## Run

Keystone EC2 credentials map onto warp like this:

| `openstack ec2 credentials show` | warp env var      |
|----------------------------------|-------------------|
| `access`                         | `WARP_ACCESS_KEY` |
| `secret`                         | `WARP_SECRET_KEY` |

Set the two secrets in your shell without putting them on a command line
(`read -s` keeps them out of history), then pass them by name so docker
copies them from your environment:

```sh
read -rs -p 'access: ' WARP_ACCESS_KEY; echo
read -rs -p 'secret: ' WARP_SECRET_KEY; echo
export WARP_ACCESS_KEY WARP_SECRET_KEY

docker run --rm -it \
  -e WARP_HOST=swift.api.sjc3.rackspacecloud.com \
  -e WARP_REGION=SJC3 \
  -e WARP_ACCESS_KEY -e WARP_SECRET_KEY \
  -v "$PWD/results:/data" \
  warp-swift-bench mixed --duration 2m --obj.size 4MiB --objects 500 --concurrent 16

unset WARP_ACCESS_KEY WARP_SECRET_KEY
```

The first argument is the warp benchmark mode (`mixed`, `get`, `put`,
`delete`, `list`, `stat`, `multipart`, ...); everything after it goes to
warp unchanged. Omit the mode to get `mixed`. Warp's own defaults are
5 minutes, 2500 objects of 10 MiB, 20 concurrent operations; that pre-uploads
25 GiB, so set `--objects` and `--obj.size` deliberately.

Results (`warp-<mode>-<timestamp>-<id>.json.zst`) land in the mounted `results/`
directory. Re-analyze one later with:

```sh
docker run --rm -v "$PWD/results:/data" warp-swift-bench analyze "warp-mixed-2026-09-10[145340]-rZto.json.zst"
```

## Running the AI-workload matrix

`run-matrix.sh` runs twenty variants that mirror how AI workloads hit object
storage, then aggregates every result file into one table:

| Family | Mode | Sizes | What it models |
|--------|------|-------|----------------|
| `kv-*` | mixed, PUT-heavy | 8, 32, 64 MiB, with and without multipart | LMCache KV-cache offload |
| `wt-*` | get, whole and 64 MiB ranges | 1 GiB | safetensors weight loading |
| `ds-shard-*` | get | 256 MiB | tokenized / WebDataset shards |
| `ds-sample-*` | get, random sizes | up to 4 MiB | raw training samples |
| `meta-*` | mixed | 4 KiB, 64 KiB | manifests, indexes, tokenizer files |
| `list-*` | list | 1 KiB | dataset enumeration |

```sh
export WARP_HOST=swift.api.sjc3.rackspacecloud.com WARP_REGION=SJC3
export WARP_ACCESS_KEY WARP_SECRET_KEY        # set with read -rs as above

./run-matrix.sh --list                        # show the matrix
./run-matrix.sh --smoke                       # 10s runs, few objects: check the pipeline
./run-matrix.sh                               # the real thing, 2 minutes per variant
./run-matrix.sh --only 'kv-*' --duration 5m   # a subset, longer
./run-matrix.sh --aggregate results/<dir>     # re-aggregate an existing run
```

Each invocation writes `results/<UTC timestamp>/` containing `<id>.json.zst`
and `<id>.log` per variant, `manifest.tsv`, `analysis/<id>.json` from
`warp analyze --json`, and three aggregates that are also printed at the end:

- `tps.csv`: one row per variant with TPS (successful S3 operations per
  second in warp's trimmed window), split into read (GET + STAT), write
  (PUT + DELETE) and list, plus MiB/s and errors.
- `summary.csv`: one row per variant and operation with TPS, throughput,
  and request latency percentiles including time to first byte.
- `summary.md`: both tables as Markdown.

A multipart upload counts as one PUT transaction regardless of part count, so
s3api sees more HTTP requests than the TPS figure for objects above 16 MiB.
A failed variant is recorded in the manifest and the rest of the matrix
continues. Errors inside a run are counted per operation and the first
message is listed under "Errors" in the summary.

The script empties every bucket it used when it finishes. If the endpoint
returns a sporadic auth error during that sweep, a few objects can remain;
`./run-matrix.sh --smoke --only list-1kib-c16` clears the main bucket again.

The `get` families share one bucket per object size (`warp-get-1gib`,
`warp-get-256mib`, `warp-get-4mib`): the first variant uploads the objects,
later ones reuse them with `--list-existing`, and the bucket is emptied at
the end. A full run pre-uploads roughly 40 GiB in total and takes about an
hour at 2 minutes per variant.

## Environment

| Variable          | Default                 | Notes |
|-------------------|-------------------------|-------|
| `WARP_HOST`       | (required)              | `host[:port]`, no scheme or path |
| `WARP_ACCESS_KEY` | (required)              | EC2 `access` |
| `WARP_SECRET_KEY` | (required)              | EC2 `secret` |
| `WARP_REGION`     | `us-east-1`             | Must equal the s3api `location` (`SJC3` on Rackspace Flex SJC3). See below. |
| `WARP_TLS`        | `true`                  | Set `false` for a plain-HTTP proxy |
| `WARP_BUCKET`     | `warp-benchmark-bucket` | Warp deletes everything in it |

## Finding the region

SigV4 puts the region in the credential scope and s3api compares it to its
configured `location`. Swift's default is `us-east-1`; Rackspace Flex SJC3
uses `SJC3`. Warp reports a mismatch only as `400 Bad Request` because its
first call is a HEAD, which has no body. Ask the endpoint directly with a
signed request and it names the value it wants:

```sh
# The x-amz-content-sha256 header (SHA-256 of an empty body) is mandatory for
# s3api; curl < 8.x does not add it on its own.
curl -sS --aws-sigv4 "aws:amz:us-east-1:s3" \
  --user "$WARP_ACCESS_KEY:$WARP_SECRET_KEY" \
  -H "x-amz-content-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
  https://swift.api.sjc3.rackspacecloud.com/
# <Error><Code>AuthorizationHeaderMalformed</Code><Message>... expecting 'SJC3'</Message>...
```

## Swift specifics baked into the entrypoint

- `--lookup path`: s3api serves `/<bucket>/<key>` only; there is no wildcard
  DNS or certificate for virtual-hosted buckets.
- TLS on by default; add `--insecure` after the mode to skip certificate
  verification against a lab proxy.
- Add `--disable-multipart` if the target proxy lacks SLO support.
