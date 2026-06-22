#!/bin/zsh
set -euo pipefail
CONFIGURATION="${1:-Debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/build/$CONFIGURATION/AppA.app/Contents/MacOS/AppA" --call-peer --variant=one-connection --exit
