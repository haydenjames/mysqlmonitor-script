#!/bin/bash
# Runs every check against the fake server in tests/bin (no MySQL needed).
cd "$(dirname "$0")/.." || exit 1
export MOCK_STATE=$(mktemp -d)
tmp=$(mktemp)
trap 'rm -rf "$MOCK_STATE" "$tmp"' EXIT
echo "## layouts at every size, with gawk, mawk and busybox awk"
python3 -I tests/sizes.py mysqlmonitor.sh tests > "$tmp"
grep -Ev 'OK$|^ *size|^$' "$tmp"
grep -E 'all checks OK|problems' "$tmp"
echo "## key handling through a pty"
python3 -I tests/keys.py mysqlmonitor.sh tests
echo "## --once"
out=$(PATH=$PWD/tests/bin:$PATH ./mysqlmonitor.sh --once)
printf '%s\n' "$out" | head -3
