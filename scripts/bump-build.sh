#!/usr/bin/env bash
# Increment CFBundleVersion in Info.plist and print the new build number.
set -euo pipefail
cd "$(dirname "$0")/.."

current=$(grep -A1 '<key>CFBundleVersion</key>' Info.plist | sed -n 's|.*<string>\([0-9][0-9]*\)</string>.*|\1|p')
if [[ -z "$current" ]]; then
  echo "bump-build: could not read CFBundleVersion from Info.plist" >&2
  exit 1
fi
next=$((current + 1))
sed -i "/<key>CFBundleVersion<\/key>/{n;s|<string>[0-9]*</string>|<string>${next}</string>|}" Info.plist
echo "$next"
