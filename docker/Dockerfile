# 编译 Pi 用程序的环境。BASE 默认 Debian 13 (trixie, gcc 14)，和 Pi 上的系统一致，速度最好；
# 用 --build-arg BASE=debian:bookworm 编译 Debian 12 兼容版（prefill 慢约 6%，给系统较旧的 Pi 用）。
# 只支持 64 位系统（arm64/aarch64）：32 位系统的 Pi 要重装 64 位系统。
ARG BASE=debian:trixie
FROM ${BASE}
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build git ca-certificates iproute2 procps \
    && rm -rf /var/lib/apt/lists/*
