#!/bin/zsh
set -euo pipefail
CONFIGURATION="${1:-Debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/build/$CONFIGURATION/AppA.app/Contents/MacOS/AppA" --variant=two-connection
"$ROOT/build/$CONFIGURATION/AppB.app/Contents/MacOS/AppB" --variant=two-connection
