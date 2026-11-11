#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends build-essential curl ca-certificates xz-utils
fi

ZIG_VERSION=0.17.1
ZIG_TAR="zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TAR}"
ZIG_SHA="3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a"

if ! command -v zig >/dev/null 2>&1 || [ "$(zig version 2>/dev/null)" != "$ZIG_VERSION" ]; then
    echo "Fetching Zig ${ZIG_VERSION} from ${ZIG_URL}..."
    curl -fsSL -o "/tmp/${ZIG_TAR}" "${ZIG_URL}"
    echo "${ZIG_SHA}  /tmp/${ZIG_TAR}" | sha256sum -c -
    mkdir -p /opt
    rm -rf "/opt/zig-x86_64-linux-${ZIG_VERSION}"
    tar -C /opt -xJf "/tmp/${ZIG_TAR}"
    rm -f "/tmp/${ZIG_TAR}"
    ln -sf "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
fi

zig version
