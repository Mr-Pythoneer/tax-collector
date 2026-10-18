# Tax Collector relay server. Build it from the repository root:
#
#   docker build -f server/Dockerfile -t tax-collector-relay .
#
# Every step only copies files (no RUN, no npm install: the server has no dependencies), so an
# image for the other architecture (linux/amd64 on an ARM machine, or the reverse) builds without
# emulation. server/Dockerfile.dockerignore keeps the rest of the repository out of the build.
# Both rely on BuildKit, Docker's default builder since version 23. Running it: server/README.md.

FROM node:24-alpine

LABEL org.opencontainers.image.title="Tax Collector relay" \
      org.opencontainers.image.description="Passes encrypted messages between Tax Collector and parents' phones, and serves the parent app."

# The code belongs to root, so the server can read it but not change it.
WORKDIR /app
COPY server/package.json server/server.mjs server/
COPY server/lib/ server/lib/
COPY parent/ parent/

# The data folder (the setup code and the computers' channels) has to belong to the node user
# before VOLUME, so that a new volume starts out writable by it. BuildKit's WORKDIR makes a
# missing folder as the current USER, which saves a RUN step.
USER node
WORKDIR /data
WORKDIR /app
VOLUME /data

# Requests arrive from Docker's bridge, not loopback: believe Tailscale's X-Forwarded-For from
# private addresses, so rate limits see each visitor (README, "With Docker").
ENV HOST=0.0.0.0 \
    PORT=8787 \
    TC_DATA_DIR=/data \
    TC_TRUST_PROXY=private
EXPOSE 8787

# Node's own fetch, since the image has no curl.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/v1/health',{signal:AbortSignal.timeout(4000)}).then(r=>r.json()).then(b=>process.exit(b.ok===true?0:1)).catch(()=>process.exit(1))"]

# The server saves its data and exits on SIGTERM.
STOPSIGNAL SIGTERM
CMD ["node", "server/server.mjs"]
