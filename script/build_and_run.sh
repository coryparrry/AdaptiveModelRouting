#!/usr/bin/env bash
# Build a real SwiftUI app bundle and launch it through Launch Services.
set -euo pipefail
ROUTING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROUTING_ROOT/scripts/build_demo_app.py" "$@"
