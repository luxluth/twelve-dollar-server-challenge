#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p bin
zig build --release=fast
cp zig-out/bin/server bin/server
