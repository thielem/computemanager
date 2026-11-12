#!/usr/bin/env bash
# Remove fand (INST-2). Thin wrapper around scripts/uninstall-fand.sh (shared with the cask).
# Usage: sudo scripts/uninstall.sh
set -euo pipefail
exec "$(dirname "$0")/uninstall-fand.sh"
