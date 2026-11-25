#!/bin/bash
# Native WKWebView regression check. Uses only an isolated test app and library.
set -euo pipefail
cd "$(dirname "$0")/.."
check_mode="${1:---annotation-layout-check}"
./scripts/build.sh
check_root="$(mktemp -d "$PWD/.build/annotation-layout.XXXXXX")"
check_app="$check_root/LeafLayoutTest.app"
report="$check_root/report.json"
ditto dist/Leaf.app "$check_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.leaf.reader.layouttest' "$check_app/Contents/Info.plist"
codesign --force --sign - "$check_app"
cleanup() {
    python3 - "$check_app/Contents/MacOS/Leaf" <<'PY'
import os, signal, subprocess, sys
for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and fields[1] == sys.argv[1]:
        try: os.kill(int(fields[0]), signal.SIGTERM)
        except ProcessLookupError: pass
PY
}
trap cleanup EXIT
open -n "$check_app" --env "LEAF_LIBRARY_PATH=$check_root/Library" --args \
    --open "$PWD/Fixtures/Guide.epub" --check-report "$report" "$check_mode"
python3 - "$report" <<'PY'
import json, sys, time
from pathlib import Path
path = Path(sys.argv[1])
for _ in range(60):
    if path.exists(): break
    time.sleep(1)
else: raise SystemExit('Annotation layout check timed out')
report = json.loads(path.read_text())
states = report.get('annotationLayout', {}).get('states', [])
for state in states:
    error = max((item['error'] for item in state.get('results', [])), default=9999)
    print(f"{state['state']}: {'PASS' if state['passed'] else 'FAIL'}, max error {error:.3f}px")
if not report.get('passed'):
    print(report.get('javascriptError') or report.get('error') or 'Annotation alignment failed')
    raise SystemExit(1)
if 'pagination' in report:
    checks=report['pagination']['checks']
    for name, passed in checks.items(): print(f"{name}: {'PASS' if passed else 'FAIL'}")
    print(f'{len(checks)} pagination checks passed. Report: {path}')
else:
    print(f'{len(states)} annotation layout states passed. Report: {path}')
PY
