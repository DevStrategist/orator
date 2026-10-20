#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift test --package-path "$ROOT" --jobs 2
uv run --project "$ROOT/runtime" --locked python -m unittest discover -s "$ROOT/runtime" -p 'test_*.py' -v
