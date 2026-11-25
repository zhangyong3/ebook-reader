#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./scripts/test-annotation-layout.sh --pagination-check
