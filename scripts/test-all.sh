#!/usr/bin/env bash
# Run every test suite in the repository.
#
#   scripts/test-all.sh            unit tests of the app and all packages + lint
#   scripts/test-all.sh --live     also contract tests against a running
#                                  container-apiserver (`container system start`)
#   scripts/test-all.sh --ui       also build the Xcode project and run the
#                                  read-only XCUITest suite
#
# Exits non-zero if anything fails.
set -uo pipefail
cd "$(dirname "$0")/.."

LIVE=0
UI=0
for arg in "$@"; do
  case "$arg" in
    --live) LIVE=1 ;;
    --ui) UI=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

failures=()

step() { printf '\n==> %s\n' "$1"; }

# Lint: a user action whose failure is swallowed leaves a button that silently
# does nothing. Actions go through `app.perform { … }` (or a view model that
# records the error) instead of `try? await app.engine.…`. Reads that only fill
# in a suggestion may say so with a `// best-effort` comment.
step "lint: no swallowed engine actions in the UI"
if grep -rn "try? await app\.engine\." Sources/AppCore | grep -v "// best-effort"; then
  failures+=("lint: swallowed engine actions")
else
  echo "ok"
fi

if [[ $LIVE == 1 ]]; then
  export IREKOBOX_LIVE_TESTS=1
  if ! /usr/local/bin/container system status >/dev/null 2>&1; then
    echo "container services are not running; start them with: container system start" >&2
    exit 2
  fi
fi

for package in . ContainerKit ComposeKit StackKit MigrationKit; do
  step "swift test: ${package}"
  if ! (cd "$package" && swift test 2>&1 | tail -n 3); then
    failures+=("swift test: ${package}")
  fi
done

if [[ $UI == 1 ]]; then
  step "XCUITest (read-only suite)"
  xcodegen >/dev/null
  if ! xcodebuild test -project Irekobox.xcodeproj -scheme IrekoboxApp \
      -destination 'platform=macOS' -allowProvisioningUpdates \
      -only-testing:IrekoboxUITests/IrekoboxUITests 2>&1 \
      | grep -E "Test Case .*(passed|failed)|\*\* TEST"; then
    failures+=("XCUITest")
  fi
fi

# pipefail keeps `swift test`/`xcodebuild` failures visible through the pipes.
step "summary"
if (( ${#failures[@]} )); then
  printf 'FAILED: %s\n' "${failures[@]}"
  exit 1
fi
echo "all suites passed"
