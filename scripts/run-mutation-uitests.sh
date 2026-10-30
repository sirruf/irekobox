#!/usr/bin/env bash
# Run the mutation/lifecycle UI suite.
#
# WHY THIS WRAPPER EXISTS
# -----------------------
# The XCUITest runner (IrekoboxUITests-Runner.app) is SANDBOXED by the
# XCTest template, with mach-lookup exceptions only for test-infrastructure
# services. It therefore CANNOT reach the `container-apiserver` XPC service:
# any `container …` call spawned from inside the test process fails with
#   Error: interrupted: "XPC connection error: Connection invalid".
# The app under test is NOT sandboxed (ENABLE_APP_SANDBOX: NO) so it reaches the
# apiserver fine — that's why driving the UI works.
#
# Consequence: container fixtures (which have no in-app "create" affordance
# without an image-run flow) must be created/destroyed OUTSIDE the runner. This
# script creates them here, runs the suite, then force-cleans and prints the
# backend truth to confirm zero leftovers.
#
# Volume/network create+delete and the duplicate-volume error toast are driven
# entirely THROUGH THE UI (the app performs those CLI calls), so they need no
# pre-seeding.
set -uo pipefail

CTR=/usr/local/bin/container
PROJ=Irekobox.xcodeproj
SCHEME=IrekoboxApp

# Container fixtures the UI suite expects to already exist.
WEB=ib-uitest-web      # starts STOPPED  (lifecycle-from-list)
DEL=ib-uitest-del      # starts RUNNING  (delete-without-confirm)
DET=ib-uitest-det      # starts STOPPED  (detail-view lifecycle)
EDIT=ib-uitest-edit    # starts RUNNING  (edit sheet)

cleanup() {
  for c in "$WEB" "$DEL" "$DET" "$EDIT"; do
    "$CTR" delete --force "$c" >/dev/null 2>&1
  done
  # UI-created disposables (best-effort; the tests also delete them via the UI).
  "$CTR" volume  delete ib-uitest-vol  >/dev/null 2>&1
  "$CTR" volume  delete ib-uitest-dup  >/dev/null 2>&1
  "$CTR" network delete ib-uitest-net  >/dev/null 2>&1
}

# Select the U.S. keyboard layout. XCUITest types Latin letters by KEYCODE; if a
# non-Latin input source is active, letters
# map through that layout and arrive as Cyrillic/garbage or get dropped, so every
# UI "create" flow that types a name silently fails. (Digits/symbols are
# unaffected, which is why the failure looks selective.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "==> Select U.S. keyboard layout (deterministic XCUITest typing)"
swift "$SCRIPT_DIR/select-us-keyboard.swift" || echo "WARN: could not select US layout"
# Also disable press-and-hold so synthesized letter keys never open the accent
# popover (belt-and-suspenders); the previous setting comes back on exit.
PRESS_AND_HOLD=$(defaults read -g ApplePressAndHoldEnabled 2>/dev/null || echo unset)
restore_press_and_hold() {
  if [ "$PRESS_AND_HOLD" = unset ]; then defaults delete -g ApplePressAndHoldEnabled 2>/dev/null
  else defaults write -g ApplePressAndHoldEnabled -bool "$PRESS_AND_HOLD"; fi
}
trap restore_press_and_hold EXIT
defaults write -g ApplePressAndHoldEnabled -bool false

echo "==> Pre-clean any stale fixtures"
cleanup

echo "==> Create container fixtures (out-of-process; runner is sandboxed)"
"$CTR" run -d --name "$WEB"  alpine sleep 600 >/dev/null && "$CTR" stop "$WEB" >/dev/null
"$CTR" run -d --name "$DEL"  alpine sleep 600 >/dev/null
"$CTR" run -d --name "$DET"  alpine sleep 600 >/dev/null && "$CTR" stop "$DET" >/dev/null
"$CTR" run -d --name "$EDIT" alpine sleep 600 >/dev/null

echo "==> Fixture state before tests:"
"$CTR" list --all | grep ib-uitest- || true

echo "==> Run UI suite"
xcodebuild test \
  -project "$PROJ" -scheme "$SCHEME" -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  "$@"
RC=$?

echo "==> Post-test cleanup"
cleanup

echo "==> Backend truth after cleanup (expect NO ib-uitest-* rows):"
echo "--- containers ---"; "$CTR" list --all
echo "--- volumes ---";    "$CTR" volume list
echo "--- networks ---";   "$CTR" network list

exit $RC
