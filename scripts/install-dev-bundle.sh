#!/usr/bin/env bash
set -euo pipefail

SOURCE_PATH="${1:-}"
DEST_PATH="${2:-}"

if [[ -z "$SOURCE_PATH" || -z "$DEST_PATH" ]]; then
  echo "Usage: $0 SOURCE_PATH DEST_PATH" >&2
  exit 64
fi

if [[ ! -e "$SOURCE_PATH" ]]; then
  echo "Bundle not found: $SOURCE_PATH" >&2
  exit 1
fi

signing_identity_for() {
  local path="$1"
  if [[ -n "${DEV_BUNDLE_SIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$DEV_BUNDLE_SIGN_IDENTITY"
    return
  fi

  /usr/bin/codesign -d --verbose=4 "$path" 2>&1 | sed -n 's/^Authority=//p' | head -n 1
}

sign_bundle_like_source() {
  local bundle_path="$1"
  local source_path="$2"
  local identity
  identity="$(signing_identity_for "$source_path" || true)"

  # Re-sign with the source's identity when it is available locally (e.g. your own Apple
  # Development certificate); otherwise fall back to ad-hoc signing, which is enough for a
  # development install. The TunaKit binary is signed with the Tuna developer's identity,
  # which contributors do not have.
  if [[ -n "$identity" ]] && /usr/bin/codesign \
      --force \
      --sign "$identity" \
      --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags \
      "$bundle_path" >/dev/null 2>&1; then
    return
  fi

  /usr/bin/codesign --force --sign - --timestamp=none "$bundle_path" >/dev/null
}

bundle_dir="$(dirname "$DEST_PATH")"
mkdir -p "$bundle_dir"

rm -rf "$DEST_PATH"
ditto "$SOURCE_PATH" "$DEST_PATH"

build_dir="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
tunakit_source="$build_dir/TunaKit.framework"

if [[ -d "$tunakit_source" ]]; then
  if [[ -d "$DEST_PATH/Versions/A" ]]; then
    runtime_frameworks_dir="$DEST_PATH/Versions/A/Frameworks"
  else
    runtime_frameworks_dir="$DEST_PATH/Frameworks"
  fi

  mkdir -p "$runtime_frameworks_dir"
  embedded_tunakit="$runtime_frameworks_dir/TunaKit.framework"
  rm -rf "$embedded_tunakit"
  ditto "$tunakit_source" "$embedded_tunakit"

  sign_bundle_like_source "$embedded_tunakit" "$tunakit_source"
  sign_bundle_like_source "$DEST_PATH" "$SOURCE_PATH"

  echo "Embedded $tunakit_source -> $embedded_tunakit"
fi

echo "Installed $SOURCE_PATH -> $DEST_PATH"
