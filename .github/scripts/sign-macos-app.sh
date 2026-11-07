#!/usr/bin/env bash

set -euo pipefail

app_path=$1
identity=$2
entitlements=$3

# [LAN-ONLY] Hardened Runtime (--options runtime) is only valid for an
# Apple-issued Developer ID identity. Applying it to an ad-hoc (-) signature
# makes AMFI kill the app at launch: every bundled dylib and the `service`
# helper is signed without a Team ID, so library validation rejects them.
# That was the 1.5.7 "click -> instant quit with no dialog" bug.
# This script now has exactly one mode: ad-hoc. Never add --options runtime.
sign_args=(--force --sign "$identity")

frameworks_path="$app_path/Contents/Frameworks"
if [[ -d "$frameworks_path" ]]; then
  while IFS= read -r -d '' code; do
    if file -b "$code" | grep -q 'Mach-O'; then
      codesign "${sign_args[@]}" "$code"
    fi
  done < <(find "$frameworks_path" -type f -print0)

  while IFS= read -r -d '' framework; do
    codesign "${sign_args[@]}" "$framework"
  done < <(find "$frameworks_path" -depth -type d -name '*.framework' -print0)
fi

service_path="$app_path/Contents/MacOS/service"
if [[ -f "$service_path" ]]; then
  # `service` is a separate code-signing principal, and becomes the capture
  # process once a LaunchDaemon is installed. Give it the same entitlements as
  # the app so it keeps com.apple.security.device.audio-input for SCK loopback.
  codesign "${sign_args[@]}" --generate-entitlement-der \
    --entitlements "$entitlements" "$service_path"
fi

codesign "${sign_args[@]}" --generate-entitlement-der \
  --entitlements "$entitlements" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

# [LAN-ONLY] ad-hoc DR is cdhash-based: ScreenCapture / Accessibility / Input
# Monitoring grants are re-bound on every rebuild. Run fix-perm.command once
# after installing a new build.

actual_entitlements=$(codesign -d --entitlements :- "$app_path" 2>/dev/null)
audio_input=$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw - \
  <<<"$actual_entitlements")
if [[ "$audio_input" != "true" ]]; then
  echo "Missing com.apple.security.device.audio-input entitlement" >&2
  exit 1
fi
