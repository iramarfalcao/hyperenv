#!/bin/bash
# Regenerates hyperenv/Design/Tokens.swift and the icon assets from design/.
# Run after changing design/tokens.json or design/icons.
#
# Usage: Scripts/generate-design.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift "$REPO/Scripts/GenerateDesign/main.swift" "$REPO/../../design" "$REPO/hyperenv"
