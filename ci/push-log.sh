#!/usr/bin/env bash
# Pushes a log file to the 'ci-logs' branch so build failures can be read without the Actions UI
# (same mechanism as the Transkriptor project).
set -uo pipefail
FILE="$1"
NAME="${2:-$(basename "$FILE")}"
[ -f "$FILE" ] || exit 0
TMP=$(mktemp -d -p "${RUNNER_TEMP:-/tmp}")
tail -c 400000 "$FILE" > "$TMP/$NAME"
cd "$TMP"
git init -q
git config user.name "ci"
git config user.email "ci@users.noreply.github.com"
git add "$NAME"
git commit -qm "Log from run ${GITHUB_RUN_ID:-local}"
git push -qf "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" HEAD:refs/heads/ci-logs
