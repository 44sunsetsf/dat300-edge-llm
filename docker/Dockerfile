# Build environment matching the Pis (Debian 13 "trixie", arm64, gcc 14).
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build git ca-certificates iproute2 procps \
    && rm -rf /var/lib/apt/lists/*
