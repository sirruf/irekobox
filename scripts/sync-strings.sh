#!/bin/bash
# Collects every localizable string in the code into the String Catalogs.
#
# Xcode extracts strings only from an app target's own sources; most of the
# UI lives in the AppCore package (and some advice the app shows in
# ContainerKit, ComposeKit and MigrationKit), so this builds with
# SWIFT_EMIT_LOC_STRINGS and syncs the .stringsdata of those packages and
# the app into the app's catalogs,
# and the widgets' into theirs. New strings arrive untranslated; strings no
# longer in the code are marked stale.
#
# Usage: scripts/sync-strings.sh
set -euo pipefail
cd "$(dirname "$0")/.."
data=build/loc
xcodegen >/dev/null
xcodebuild -scheme IrekoboxApp -project Irekobox.xcodeproj -derivedDataPath "$data" \
    -destination 'platform=macOS' SWIFT_EMIT_LOC_STRINGS=YES build -quiet
products="$data/Build/Intermediates.noindex"
app=$(find "$products" -name '*.stringsdata' \( -path '*/AppCore*' -o -path '*/ContainerKit-t*' \
    -o -path '*/ComposeKit-t*' -o -path '*/MigrationKit-t*' -o -path '*/IrekoboxApp.build/*' \))
widgets=$(find "$products" -name '*.stringsdata' -path '*/IrekoboxWidgets.build/*')
# shellcheck disable=SC2086
xcrun xcstringstool sync Sources/Irekobox/Resources/Localizable.xcstrings \
    Sources/Irekobox/Resources/AppShortcuts.xcstrings --stringsdata $app
# shellcheck disable=SC2086
xcrun xcstringstool sync Sources/IrekoboxWidgets/Localizable.xcstrings --stringsdata $widgets
