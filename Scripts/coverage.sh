#!/bin/zsh
# Runs the test suites with code coverage and prints the share of lines and functions they run, per module.
#
#   Scripts/coverage.sh
set -euo pipefail
cd "${0:A:h:h}"
SCRATCH=.build-coverage
mkdir -p $SCRATCH
swift test --enable-code-coverage --skip LiveInferenceTests --scratch-path $SCRATCH >$SCRATCH/tests.log 2>&1 || { tail -30 $SCRATCH/tests.log; exit 1; }
# Each bundle's own total is the "Executed" line right after its ".xctest' passed" line.
awk '/\.xctest. (passed|failed)/ { getline; tests += $2; failures += $5 } END { printf "%d tests, %d failures\n", tests, failures }' $SCRATCH/tests.log
PRODUCTS=$SCRATCH/out/Products/Debug
bundles=($PRODUCTS/*Tests.xctest)
objects=()
for b in $bundles; do objects+=(-object "$b/Contents/MacOS/${b:t:r}"); done
xcrun llvm-cov export -summary-only -instr-profile $SCRATCH/debug/codecov/default.profdata "${objects[@]:1}" \
  -ignore-filename-regex='(\.build[^/]*|Tests|checkouts)/' | python3 -c '
import json, os, sys
root = os.getcwd() + "/"
modules = {}
for f in json.load(sys.stdin)["data"][0]["files"]:
    path = f["filename"].replace(root, "")
    if not path.startswith("Sources/"):
        continue
    s, m = f["summary"], modules.setdefault(path.split("/")[1], [0, 0, 0, 0])
    m[0] += s["lines"]["count"]; m[1] += s["lines"]["covered"]; m[2] += s["functions"]["count"]; m[3] += s["functions"]["covered"]
print("| Module | Lines | Functions |\n|---|---:|---:|")
for name, (lines, covered, funcs, fcovered) in sorted(modules.items(), key=lambda kv: -kv[1][1] / kv[1][0]):
    print(f"| `{name}` | {100 * covered / lines:.1f}% ({covered}/{lines}) | {100 * fcovered / max(funcs, 1):.1f}% ({fcovered}/{funcs}) |")
'
