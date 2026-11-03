#!/usr/bin/env bash
# 發佈新版到 GitHub Release（App 的雲端更新從這裡下載）
# 用法：先改 pubspec.yaml 的 version，然後在 Git Bash 執行  bash tools/release.sh "更新內容"
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="wahaha232/WirelessDebugToggle"
VERSION=$(grep -E '^version:' pubspec.yaml | sed -E 's/version: *([^+]+).*/\1/')
TAG="v$VERSION"
NOTES="${1:-$TAG}"
APK="dist/WirelessDebugToggle-$TAG.apk"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG 已存在，請先調高 pubspec.yaml 的 version" >&2
  exit 1
fi

flutter build apk --release --target-platform android-arm64
mkdir -p dist
cp build/app/outputs/flutter-apk/app-release.apk "$APK"
(cd dist && sha256sum "$(basename "$APK")" > "$(basename "$APK").sha256")

git push origin HEAD
gh release create "$TAG" "$APK" "$APK.sha256" --repo "$REPO" --target "$(git rev-parse HEAD)" --title "$TAG" --notes "$NOTES"
echo "已發佈 $TAG"
