#!/bin/sh
# Regenerates Pennant.xcodeproj from project.yml (xcodegen: brew install xcodegen).
set -e
cd "$(dirname "$0")/.."
xcodegen generate
echo "Pennant.xcodeproj generated. Open it with: open Pennant.xcodeproj"
