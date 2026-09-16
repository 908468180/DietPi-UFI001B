#!/bin/sh -e
# 01-deps.sh - install build prerequisites on the (Ubuntu 22.04) runner.
# Idempotent; safe to re-run.

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    android-sdk-libsparse-utils \
    bc \
    binfmt-support \
    bison \
    ca-certificates \
    cpio \
    curl \
    debootstrap \
    device-tree-compiler \
    e2fsprogs \
    fdisk \
    gcc-aarch64-linux-gnu \
    gcc-arm-none-eabi \
    git \
    libssl-dev \
    python3-cryptography \
    python3-pycryptodome \
    qemu-user-static \
    systemd-container \
    wget

update-binfmts --display qemu-aarch64 >/dev/null 2>&1 || true