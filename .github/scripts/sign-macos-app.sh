#!/usr/bin/env bash

set -euo pipefail

app_path=$1
identity=$2
entitlements=$3

# [LAN-ONLY] --options runtime (Hardened Runtime) is only valid for an
# Apple-issued Developer ID identity. Applying it to ad-hoc (-) or self-signed
# builds makes AMFI kill the app at launch: every bundled dylib and the
# `service` helper is signed without a Team ID, so library validation rejects
# them. That is the 1.5.7 "click -> instant quit with no dialog" bug.
# Only real Developer ID builds opt in; they are also the only ones that can be
# notarized. MACOS_SIGN_MODE is set by .github/workflows/flutter-build.yml.
sign_args=(--force --sign "$identity")
if [[ "${MACOS_SIGN_MODE:-adhoc}" == "developerid" ]]; then
  sign_args+=(--options runtime --timestamp)
fi

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

# [LAN-ONLY] Print the designated requirement. TCC binds ScreenCapture grants
# to this requirement: a cdhash-based DR (typical for ad-hoc / non-Apple certs)
# means the grant dies on every rebuild, while an Apple Developer ID DR with
# `anchor apple generic` survives. Keep this visible in CI logs for auditing.
echo "=== designated requirement for $app_path ==="
codesign -d -r- "$app_path" 2>&1 || true

actual_entitlements=$(codesign -d --entitlements :- "$app_path" 2>/dev/null)
audio_input=$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw - \
  <<<"$actual_entitlements")
if [[ "$audio_input" != "true" ]]; then
  echo "Missing com.apple.security.device.audio-input entitlement" >&2
  exit 1
fi
