#!/usr/bin/env bash
# refresh_prebuilts.sh: one-shot refresh of the committed prebuilt binaries.
#
# Triggers the `prebuild-oniguruma` GitHub Actions workflow, waits for it to
# finish, downloads the combined artifact, installs it into
# packages/oniguruma_native/prebuilt/, regenerates the embedded wasm and the
# SHA-256 manifest, and verifies integrity. It does NOT commit: it leaves the
# working tree ready for you to review and commit.
#
# This is the automated version of the manual steps in prebuild-oniguruma.yml's
# header (and it installs into the CORRECT package dir, avoiding the "unzipped
# into the old oniguruma_ffi name" slip).
#
# Usage:
#   tool/prebuilt/refresh_prebuilts.sh [ref]
#
#   ref  git ref the workflow builds from (default: current branch). CI compiles
#        the shim AT THIS REF, so it must already be pushed with the source you
#        want baked in, otherwise the fresh prebuilts will be stale.
#
# Requirements: gh (authenticated), dart, unzip, rsync, and sha256sum|shasum.
set -euo pipefail

WORKFLOW="prebuild-oniguruma.yml"
ARTIFACT="oniguruma-prebuilt"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- preconditions ----------------------------------------------------------
command -v gh    >/dev/null 2>&1 || die "gh CLI not found (https://cli.github.com)"
command -v dart  >/dev/null 2>&1 || die "dart not found (needed to regenerate the wasm embed)"
command -v unzip >/dev/null 2>&1 || die "unzip not found"
command -v rsync >/dev/null 2>&1 || die "rsync not found"
gh auth status  >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

if command -v sha256sum >/dev/null 2>&1; then SHACHECK="sha256sum -c"
elif command -v shasum  >/dev/null 2>&1; then SHACHECK="shasum -a 256 -c"
else die "need sha256sum or shasum on PATH"; fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
PKG="$REPO_ROOT/packages/oniguruma_native"
[ -d "$PKG/prebuilt" ] || die "$PKG/prebuilt not found: run from within the repo"

REF="${1:-$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)}"
log "Building from ref: $REF"

# CI builds the shim from the PUSHED ref; warn on uncommitted source changes.
if [ -n "$(git -C "$REPO_ROOT" status --porcelain -- "$PKG/src" "$PKG/lib")" ]; then
  echo "WARNING: uncommitted changes under $PKG/{src,lib}."
  echo "         The workflow builds the shim from origin/$REF, so anything not"
  echo "         committed and pushed will NOT be reflected in the new binaries."
  if [ -t 0 ] && [ "${FORCE:-0}" != 1 ]; then
    read -r -p "Continue anyway? [y/N] " ans
    case "$ans" in y|Y) ;; *) die "aborted"; esac
  fi
fi

# --- trigger ----------------------------------------------------------------
# Remember the newest existing dispatch run so we can spot the one we start.
before="$(gh run list --workflow="$WORKFLOW" --event=workflow_dispatch -L 1 \
  --json databaseId --jq '.[0].databaseId // 0')"
before="${before:-0}"

log "Triggering $WORKFLOW ..."
gh workflow run "$WORKFLOW" --ref "$REF"

# Poll until a newer dispatch run appears (databaseIds increase monotonically).
log "Waiting for the run to register ..."
rid=0
for ((i = 0; i < 40; i++)); do
  sleep 3
  rid="$(gh run list --workflow="$WORKFLOW" --event=workflow_dispatch -L 1 \
    --json databaseId --jq '.[0].databaseId // 0')"
  rid="${rid:-0}"
  [ "$rid" -gt "$before" ] && break
done
[ "$rid" -gt "$before" ] || die "could not find the dispatched run (check: gh run list --workflow=$WORKFLOW)"

log "Run $rid started: $(gh run view "$rid" --json url --jq .url)"

# --- wait -------------------------------------------------------------------
log "Waiting for completion (13 native targets + wasm; typically ~10-20 min) ..."
gh run watch "$rid" --exit-status || die "workflow run $rid did not succeed: see the URL above"

# --- download + extract -----------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "Downloading artifact '$ARTIFACT' ..."
gh run download "$rid" -n "$ARTIFACT" -D "$tmp/dl"
[ -f "$tmp/dl/oniguruma-prebuilt.zip" ] || die "artifact did not contain oniguruma-prebuilt.zip"

log "Extracting ..."
unzip -q -o "$tmp/dl/oniguruma-prebuilt.zip" -d "$tmp/extract"
[ -d "$tmp/extract/prebuilt" ] || die "bundle root is not prebuilt/, layout changed?"

# Sanity-check completeness BEFORE overwriting anything: 13 native libs + 1 wasm.
count="$(find "$tmp/extract/prebuilt" -type f \
  \( -name '*.dylib' -o -name '*.so' -o -name '*.dll' -o -name '*.wasm' \) | wc -l | tr -d ' ')"
log "Bundle contains $count binaries"
[ "$count" -ge 14 ] || die "expected >=14 binaries, got $count: refusing to overwrite"

# --- install ----------------------------------------------------------------
# Overwrite the binaries; skip junk and the bundle's manifest (regenerated below
# so its format matches the local tooling exactly).
log "Installing into $PKG/prebuilt ..."
rsync -a --exclude='.DS_Store' --exclude='checksums.sha256' \
  "$tmp/extract/prebuilt/" "$PKG/prebuilt/"

# The web wasm (prebuilt/web/*.wasm) is committed and published to the GitHub
# Release by the release-wasm workflow: no embed step to regenerate.
log "Regenerating checksums.sha256 ..."
bash "$PKG/tool/prebuilt/gen_checksums.sh" >/dev/null

log "Verifying integrity ..."
( cd "$PKG/prebuilt" && $SHACHECK checksums.sha256 >/dev/null ) \
  && log "All prebuilt binaries verify against the manifest."

# --- summary ----------------------------------------------------------------
echo
log "Done. Review and commit the refreshed files:"
git -C "$REPO_ROOT" status --short -- "$PKG/prebuilt"
echo
echo "    git add packages/oniguruma_native/prebuilt"
echo "    git commit -m 'chore: refresh oniguruma_native prebuilt binaries'"
