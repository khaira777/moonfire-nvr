# Stage 1: Build
FROM rust:1.91-slim AS builder

RUN apt-get update && apt-get install -y \
    build-essential pkg-config libclang-dev protobuf-compiler cmake \
    curl gnupg && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build dependencies first for caching
COPY server/Cargo.toml server/Cargo.lock server/
COPY server/base/Cargo.toml server/base/
COPY server/db/Cargo.toml server/db/

# Create dummy sources for dependency caching
RUN mkdir -p server/src server/base/src server/db/src && \
    echo 'fn main() {}' > server/src/main.rs && \
    touch server/base/src/lib.rs server/db/src/lib.rs

RUN cd server && cargo build --release --features bundled,mimalloc 2>/dev/null || true

# Copy actual sources
COPY server/ server/

# Build UI
COPY ui/ ui/
RUN cd ui && npm install && npm run build

# Set version
ENV VERSION=hvc1-fix

# Build actual binary
RUN cd server && cargo build --release --features bundled,mimalloc && \
    cp target/release/moonfire-nvr /usr/local/bin/moonfire-nvr

# Stage 2: Runtime
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/moonfire-nvr /usr/local/bin/moonfire-nvr

ENTRYPOINT ["/usr/local/bin/moonfire-nvr"]
