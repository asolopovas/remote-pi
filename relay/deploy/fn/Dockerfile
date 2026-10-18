# Locked source build; no registry publication or unverified upstream binary.
FROM rust:1.94.0-slim-bookworm@sha256:a86cada82e36ebd7a9bffed7548792c55a952fdb20718eea9278a936bcb76e62 AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY migrations ./migrations
RUN cargo build --release --locked

FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/relay /usr/local/bin/relay
ARG SOURCE_REVISION
LABEL org.opencontainers.image.revision=$SOURCE_REVISION org.opencontainers.image.version="0.3.1"
USER 10001:10001
ENV REMOTEPI_RELAY_PORT=3000 REMOTEPI_MESH_DB_PATH=/data/mesh.db
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD curl -fsS http://127.0.0.1:3000/health || exit 1
CMD ["relay"]
