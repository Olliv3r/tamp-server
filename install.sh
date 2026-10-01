#!/usr/bin/env bash
# TAMP — Oliver Silva; revisão 1.3.2
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/tamp.sh"
main "$@"
