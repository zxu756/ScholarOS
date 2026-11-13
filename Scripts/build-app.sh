#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ScholarOS"
BUILD_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

echo "==> Building ${APP_NAME} (release)..."
cd "${ROOT_DIR}"
swift build -c release --product "${APP_NAME}"

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${ROOT_DIR}/Scripts/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
swift "${ROOT_DIR}/Scripts/make-icon.swift" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "${APP_BUNDLE}"
echo "==> Packaged & signed ${APP_BUNDLE}"
