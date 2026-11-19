#!/usr/bin/env bash
# Writes Build-Information.txt for a release. Inputs come from the environment.
set -euo pipefail
OUT="${1:-Build-Information.txt}"
{
  echo "SleepFlow – build information"
  echo "============================="
  echo "Version:            ${APP_VERSION:-?} (build ${BUILD_NUMBER:-?})"
  echo "Commit:             ${GITHUB_SHA:-?}"
  echo "Branch / tag:       ${GITHUB_REF_NAME:-?}"
  echo "Built:              $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
  echo "Workflow run:       ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  echo "Xcode:              $(xcodebuild -version | tr '\n' ' ')"
  echo "iOS SDK:            $(xcrun --sdk iphoneos --show-sdk-version)"
  echo "Minimum iOS:        17.0 (AlarmKit alarms from iOS 26, otherwise notification alarms)"
  echo "Signing:            ${SIGNING_STATUS:-unsigned}"
  echo "Unit tests:         ${UNIT_TESTS:-not run}"
  echo "UI tests:           ${UI_TESTS:-not run}"
  echo "SleepCore tests:    see the 'core' job of the same run"
  echo
  echo "Install on iPhone from Windows: open iPhone-Installer.exe, pick SleepFlow.ipa,"
  echo "sign in with your Apple ID and install. With a free Apple ID the app must be"
  echo "re-signed every 7 days (iPhone-Installer can renew it automatically)."
} > "$OUT"
cat "$OUT"
