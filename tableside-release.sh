#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

action="${1:-}"
environment="${2:-staging}"
if [[ "$environment" != "staging" && "$environment" != "production" ]]; then
  echo "Environment must be staging or production." >&2
  exit 2
fi

command -v shorebird >/dev/null 2>&1 || {
  echo "Shorebird is not installed. See docs/update-distribution.md." >&2
  exit 2
}
[[ -f shorebird.yaml ]] || {
  echo "Run 'shorebird login' and 'shorebird init' once, then commit shorebird.yaml." >&2
  exit 2
}

define_file="config/firebase-${environment}.json"
[[ -f "$define_file" ]] || {
  echo "Missing $define_file" >&2
  exit 2
}

run_ios() {
  local operation="$1"
  local staging_plist="ios/Runner/GoogleService-Info.plist"
  local production_plist="config/firebase-production/GoogleService-Info.plist"
  local backup=""
  local signing_args=()

  [[ -n "${SHOREBIRD_PUBLIC_KEY_PATH:-}" && -f "$SHOREBIRD_PUBLIC_KEY_PATH" ]] || {
    echo "Set SHOREBIRD_PUBLIC_KEY_PATH to the secured RSA public PEM." >&2
    exit 2
  }
  signing_args+=(--public-key-path "$SHOREBIRD_PUBLIC_KEY_PATH")
  if [[ "$operation" == "patch" ]]; then
    [[ -n "${SHOREBIRD_PRIVATE_KEY_PATH:-}" && -f "$SHOREBIRD_PRIVATE_KEY_PATH" ]] || {
      echo "Set SHOREBIRD_PRIVATE_KEY_PATH to the secured RSA private PEM." >&2
      exit 2
    }
    signing_args+=(--private-key-path "$SHOREBIRD_PRIVATE_KEY_PATH")
    if [[ "$environment" == "staging" ]]; then
      signing_args+=(--track staging)
    fi
  fi

  if [[ "$environment" == "production" ]]; then
    [[ -f "$production_plist" ]] || {
      echo "Production iOS requires $production_plist" >&2
      exit 2
    }
    backup="$(mktemp)"
    cp "$staging_plist" "$backup"
    trap 'cp "$backup" "$staging_plist"; rm -f "$backup"' EXIT
    cp "$production_plist" "$staging_plist"
  fi

  flutter pub get
  flutter test
  shorebird "$operation" ios "${signing_args[@]}" -- \
    "--dart-define-from-file=$define_file"
}

case "$action" in
  doctor)
    shorebird doctor
    ;;
  release-ios)
    run_ios release
    ;;
  patch-ios)
    run_ios patch
    ;;
  *)
    cat <<'USAGE'
Usage:
  ./tableside-release.sh doctor
  ./tableside-release.sh release-ios staging
  ./tableside-release.sh patch-ios staging
  ./tableside-release.sh release-ios production
  ./tableside-release.sh patch-ios production

The first TestFlight build must use release-ios. Later Dart-only fixes use
patch-ios. Native/plugin/asset changes always require another release-ios.
USAGE
    exit 2
    ;;
esac
