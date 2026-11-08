#!/bin/bash
set -euo pipefail

DEFAULT_DEVICE="4902F1E6-4F1C-40A8-8C57-F1D91073F8F1"
BUNDLE_ID="com.flickpic.app"
SCHEME="PhotoSifter"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHOTOS_DIR="${ROOT}/build/seed-photos"
EXPECTED_PHOTOS=100

DEVICE="${DEFAULT_DEVICE}"
BUILD=0
LAUNCH=1

usage() {
    cat <<EOF
Usage: scripts/seed-simulator.sh [--device <udid>] [--build] [--no-launch]

Resets a simulator to a known FlickPic test state:
  1. Generates ${EXPECTED_PHOTOS} predefined photos into build/seed-photos
     (scripts/seed/GenerateSeedPhotos.swift, deterministic).
  2. Wipes the simulator photo library and all FlickPic app state
     (Application Support JSON, UserDefaults, caches).
  3. Imports the photos, resets Photos permission, launches the app.
     The app opens on the first-launch permission screen.

Options:
  --device <udid>  Simulator to seed (default ${DEFAULT_DEVICE}).
  --build          Build and install the app first.
  --no-launch      Do not launch the app at the end.

Simulator only. A physical device's photo library cannot be seeded from the CLI.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --build) BUILD=1; shift ;;
        --no-launch) LAUNCH=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
done

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

DEVICE_DIR="${HOME}/Library/Developer/CoreSimulator/Devices/${DEVICE}"
MEDIA_DIR="${DEVICE_DIR}/data/Media"
if [[ ! -d "${DEVICE_DIR}" ]]; then
    echo "no simulator with udid ${DEVICE}" >&2
    exit 1
fi

boot() {
    xcrun simctl boot "${DEVICE}" 2>/dev/null || true
    xcrun simctl bootstatus "${DEVICE}" -b >/dev/null
}

log "Generating seed photos"
rm -rf "${PHOTOS_DIR}"
swift "${ROOT}/scripts/seed/GenerateSeedPhotos.swift" "${PHOTOS_DIR}"

log "Booting simulator ${DEVICE}"
open -a Simulator --args -CurrentDeviceUDID "${DEVICE}"
boot

if [[ "${BUILD}" == 1 ]]; then
    log "Building and installing ${SCHEME}"
    xcodebuild -scheme "${SCHEME}" -destination "id=${DEVICE}" -derivedDataPath "${ROOT}/build" build -quiet
    xcrun simctl install "${DEVICE}" "${ROOT}/build/Build/Products/Debug-iphonesimulator/PhotoSifter.app"
fi

xcrun simctl terminate "${DEVICE}" "${BUNDLE_ID}" 2>/dev/null || true
APP_DATA="$(xcrun simctl get_app_container "${DEVICE}" "${BUNDLE_ID}" data 2>/dev/null || true)"
if [[ -z "${APP_DATA}" ]]; then
    echo "warning: ${BUNDLE_ID} is not installed, only the photo library will be seeded (use --build)" >&2
fi

log "Shutting down to wipe the photo library and app state"
xcrun simctl shutdown "${DEVICE}" 2>/dev/null || true
rm -rf "${MEDIA_DIR}/DCIM" "${MEDIA_DIR}/PhotoData"
if [[ -n "${APP_DATA}" ]]; then
    rm -rf "${APP_DATA}/Library/Application Support" \
           "${APP_DATA}/Library/Caches" \
           "${APP_DATA}/Library/Preferences/${BUNDLE_ID}.plist" \
           "${APP_DATA}/Documents" \
           "${APP_DATA}/tmp"
    mkdir -p "${APP_DATA}/Library/Caches" "${APP_DATA}/Documents" "${APP_DATA}/tmp"
fi

log "Booting and importing ${EXPECTED_PHOTOS} photos"
boot
if [[ -n "${APP_DATA}" ]]; then
    xcrun simctl privacy "${DEVICE}" reset photos "${BUNDLE_ID}"
fi
xcrun simctl addmedia "${DEVICE}" "${PHOTOS_DIR}"/*

imported=0
for _ in $(seq 1 30); do
    imported=$(find "${MEDIA_DIR}/DCIM" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.heic' \) 2>/dev/null | wc -l | tr -d ' ')
    [[ "${imported}" -ge "${EXPECTED_PHOTOS}" ]] && break
    sleep 1
done
if [[ "${imported}" -ne "${EXPECTED_PHOTOS}" ]]; then
    echo "error: photo library has ${imported} files, expected ${EXPECTED_PHOTOS}" >&2
    exit 1
fi
log "Photo library has ${imported} photos"

if [[ -n "${APP_DATA}" && "${LAUNCH}" == 1 ]]; then
    log "Launching ${BUNDLE_ID}"
    xcrun simctl launch "${DEVICE}" "${BUNDLE_ID}" >/dev/null
fi

log "Done"
