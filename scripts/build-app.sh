#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="UsageNow"
DIST_APP="${ROOT_DIR}/dist/${APP_NAME}.app"
BINARY_PATH="${ROOT_DIR}/.build/arm64-apple-macosx/release/${APP_NAME}"
RESOURCES_SRC="${ROOT_DIR}/Sources/${APP_NAME}/Resources/AppIcon.icns"

cd "${ROOT_DIR}"
swift build -c release

rm -rf "${DIST_APP}"
mkdir -p "${DIST_APP}/Contents/MacOS"
mkdir -p "${DIST_APP}/Contents/Resources"

cp "${BINARY_PATH}" "${DIST_APP}/Contents/MacOS/${APP_NAME}"
cp "${SCRIPT_DIR}/Info.plist" "${DIST_APP}/Contents/Info.plist"
cp "${RESOURCES_SRC}" "${DIST_APP}/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "${DIST_APP}"
codesign --verify --deep --strict "${DIST_APP}"

echo "Built ${DIST_APP}"
