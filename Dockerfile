# syntax=docker/dockerfile:1
# warp-swift-bench
#
# MinIO warp (S3 benchmark client) packaged to run against an OpenStack Swift
# s3api endpoint. No credentials are baked into this image: WARP_ACCESS_KEY and
# WARP_SECRET_KEY are read from the environment at `docker run` time and vanish
# with the container. See README.md for the run command.

FROM alpine:3.22

# Override at build time to pin a specific release, e.g.
#   --build-arg WARP_URL=https://dl.min.io/aistor/warp/release/linux-amd64/warp
ARG WARP_URL=https://dl.min.io/aistor/warp/release/linux-amd64/warp

RUN apk add --no-cache wget ca-certificates \
 && wget -q -O /usr/local/bin/warp "${WARP_URL}" \
 && wget -q -O /tmp/warp.sha256sum "${WARP_URL}.sha256sum" \
 # The published sum names the file by version (warp.vX.Y.Z), so compare hashes only.
 && echo "$(cut -d' ' -f1 /tmp/warp.sha256sum)  /usr/local/bin/warp" | sha256sum -c - \
 && rm /tmp/warp.sha256sum \
 && chmod 0755 /usr/local/bin/warp \
 && warp --version \
 && adduser -D -u 1000 -h /data warp

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Swift-friendly defaults; both can be overridden with -e at run time.
# WARP_REGION must equal the s3api middleware's configured `location`.
ENV WARP_TLS=true \
    WARP_REGION=us-east-1

USER warp
WORKDIR /data
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["mixed"]
