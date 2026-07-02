# Simple Dockerfile to build moonfire-nvr with the hvc1→hev1 fix
FROM rust:1.91-slim as builder

# Install dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    libsqlite3-dev \
    pkgconf \
    && rm -rf /var/lib/apt/lists/*

# Copy source code
WORKDIR /app
COPY . .

# Build the server
WORKDIR /app/server
RUN cargo build --release

# Runtime stage
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libsqlite3-0 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary
COPY --from=builder /app/server/target/release/moonfire-nvr /usr/local/bin/moonfire-nvr

# Copy UI if it exists
COPY --from=builder /app/ui/dist /usr/local/lib/moonfire-nvr/ui

# Set timezone
ENV TZ=America/Toronto

# Expose port
EXPOSE 8090

# Run the server
CMD ["moonfire-nvr", "run"]
