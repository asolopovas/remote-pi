FROM rust:1-slim AS builder
WORKDIR /app

# Camada de cache das dependências: builda um main vazio só com os manifests.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs \
    && cargo build --release \
    && rm -rf src target/release/rp-s3 target/release/deps/rp_s3*

COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 rps3
COPY --from=builder /app/target/release/rp-s3 /usr/local/bin/rp-s3

ENV DATA_DIR=/data \
    PORT=8080
EXPOSE 8080
VOLUME ["/data"]
USER rps3
ENTRYPOINT ["rp-s3"]
