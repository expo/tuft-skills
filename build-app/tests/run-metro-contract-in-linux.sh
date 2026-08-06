#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Ubuntu matches the production Tuft cloud VM's relevant contract: Linux with
# no launchd and no systemd user session. Mount read-only so the test cannot
# hide side effects in the source tree.
docker run --rm \
  -v "$ROOT:/skill:ro" \
  ubuntu:24.04 \
  bash /skill/tests/run-metro-contract.sh

