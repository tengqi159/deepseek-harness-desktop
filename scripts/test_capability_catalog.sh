#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
/usr/bin/env node "$PROJECT_ROOT/scripts/test_capability_catalog.mjs"
