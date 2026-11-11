#!/usr/bin/env bash
# Ship a TestFlight build in one go: check Xcode's sign-in, run scripts/release.sh (bump, archive, export, validate,
# upload, wait for processing), then commit the bumped build number and push. See docs/install.md.
#
#   scripts/ship.sh                  iOS, then the Mac with the same build number
#   scripts/ship.sh --platform ios   iOS only (or mac)
#   scripts/ship.sh --no-push        commit the bump but don't push
#
# The commit says [skip ci]: it only changes the build number, and the code it ships was already tested.
set -euo pipefail

cd "$(dirname "$0")/.."

PLATFORMS=(ios mac)
PUSH=1
while (( $# )); do
  case "$1" in
    --platform) shift; PLATFORMS=("${1:-}") ;;
    --platform=*) PLATFORMS=("${1#--platform=}") ;;
    --no-push) PUSH=0 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "error: $*" >&2; exit 1; }
for p in "${PLATFORMS[@]}"; do [[ $p == ios || $p == mac ]] || die "--platform must be ios or mac (got '$p')"; done

# 1. Xcode must be signed in where xcodebuild can see it. With Xcode 27.2 the Apple Accounts pane can show the account
#    while this list is empty; removing and re-adding the account fixes it (docs/install.md).
if ! defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | grep -q identifier; then
  die "Xcode has no account that xcodebuild can use. In Xcode > Settings > Apple Accounts, remove the account and
       add it again (signing in once isn't always enough), then run this again."
fi

# The App Store Connect key ids live in ~/.zshrc; a non-interactive shell may not have them.
if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]] && [[ -f ~/.zshrc ]]; then
  eval "$(grep -E '^export ASC_(KEY_ID|ISSUER_ID)=' ~/.zshrc)"
fi

git diff --quiet -- project.yml || die "project.yml has uncommitted changes; commit or discard them first"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ $BRANCH == main ]] || echo "note: on branch $BRANCH, not main"

build_number() { sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?.*/\1/p' project.yml | head -1; }
LOGDIR=build/release
mkdir -p "$LOGDIR"

# 2. Release each platform. The first bumps the number; the next reuses it (numbers are tracked per platform).
results=()
first=1
for p in "${PLATFORMS[@]}"; do
  args=(--platform "$p")
  (( first )) || args+=(--keep-build)
  log="$LOGDIR/ship-$p.log"
  echo "==> scripts/release.sh ${args[*]}"
  if scripts/release.sh "${args[@]}" 2>&1 | tee "$log"; then
    if grep -q 'processed: VALID' "$log"; then results+=("$p $(build_number): VALID")
    else results+=("$p $(build_number): uploaded, still processing (see $log)"); fi
  else
    results+=("$p $(build_number): FAILED (see $log)")
    printf '%s\n' "${results[@]}"
    if git diff --quiet -- project.yml; then die "release failed for $p"; fi
    if grep -qx "$(build_number)" "$LOGDIR/uploaded$([[ $p == ios ]] && echo -ios)" 2>/dev/null; then
      # Uploaded but rejected in processing: the number is used up, so keep the bump.
      git commit -q -m "Build $(build_number) (rejected in processing) [skip ci]" -- project.yml
      die "build $(build_number) was uploaded but rejected for $p; the bump is committed. Fix it and run again."
    fi
    die "release failed for $p before uploading; project.yml is bumped to $(build_number) and not committed.
       Fix it and re-run scripts/release.sh --platform $p --keep-build, then commit project.yml."
  fi
  first=0
done

# 3. Commit the bump (if this run made one) and 4. push.
BUILD=$(build_number)
if ! git diff --quiet -- project.yml; then
  git commit -q -m "TestFlight 0.1.0 ($BUILD): ${PLATFORMS[*]} [skip ci]" -- project.yml
  echo "==> Committed the build number $BUILD"
fi
if (( PUSH )); then
  git push -q && echo "==> Pushed $BRANCH"
fi

echo "==> Done"
printf '    %s\n' "${results[@]}"
