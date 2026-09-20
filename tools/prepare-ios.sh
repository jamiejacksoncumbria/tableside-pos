#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

echo "Resolving Flutter dependencies..."
flutter pub get

manifest="ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
if [[ ! -f "$manifest" ]]; then
  echo "Flutter did not generate $manifest" >&2
  echo "Check that Swift Package Manager is enabled in this Flutter SDK." >&2
  exit 1
fi

# Flutter currently creates this aggregate package at its own iOS default
# before Xcode resolves dependencies. Firebase's current Apple packages require
# iOS 15, and Xcode performs package resolution before Flutter's build migration
# can raise the generated manifest. Patch only this ignored generated file.
perl -0pi -e 's/\.iOS\("[0-9]+(?:\.[0-9]+)*"\)/.iOS("15.0")/' "$manifest"

if ! grep -Fq '.iOS("15.0")' "$manifest"; then
  echo "Could not set the generated Swift package deployment target to iOS 15." >&2
  exit 1
fi

echo "Generated Swift package target:"
grep -F '.iOS(' "$manifest"

echo "Installing CocoaPods dependencies..."
(
  cd ios
  pod install --repo-update
)

echo "iOS dependencies are ready. Open ios/Runner.xcworkspace in Xcode."
