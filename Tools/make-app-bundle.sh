#!/bin/bash
# Assemble a minimal MKTownEditor.app from `swift build` products and sign it ad hoc.
#
# Usage: Tools/make-app-bundle.sh PRODUCTS_DIR APP_PATH
#
# PRODUCTS_DIR is the directory printed by `swift build --show-bin-path`. The bundle receives
# Support/Info.plist with its build settings expanded, so Launch Services registers the URL
# scheme, the Markdown document type, the Services menu item and the local network keys.
# The SwiftPM resource bundles go into Contents/Resources, where the generated `Bundle.module`
# accessor looks first (`Bundle.main.resourceURL`), and the compiled string tables are copied
# next to them for the UI language. actool compiles the Icon Composer document Support/AppIcon.icon
# into Assets.car and a fallback AppIcon.icns, as the Xcode build does. See docs/production-launcher.md
# and docs/app-icon.md.
set -euo pipefail

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
    echo "Usage: $0 PRODUCTS_DIR APP_PATH" >&2
    exit 2
fi

products=$1
app=${2%/}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
template="$root/Support/Info.plist"
app_icon="$root/Support/AppIcon.icon"

# Build settings of the MKTownEditor target in MKTownEditor.xcodeproj.
# Tools/test_make_app_bundle.py fails when these drift from the Xcode project.
executable_name=MKTownEditor
product_name=MKTownEditor
bundle_identifier=com.mktown.editor
deployment_target=14.0
app_icon_name=AppIcon
# The source language of Localizable.xcstrings. Its strings are the keys, so no ja.lproj exists;
# naming it the development region lets Japanese systems fall back to the keys instead of English.
development_language=ja

if [[ ! -f "$products/$executable_name" || ! -x "$products/$executable_name" ]]; then
    echo "$0: $products/$executable_name not found; run swift build first" >&2
    exit 1
fi

mkdir -p -- "$(dirname -- "$app")"
# Assemble next to the destination and swap it in at the end. A running copy of the app keeps
# its open files, and overwriting a signed executable in place would get that process killed.
staging=$(mktemp -d "$(dirname -- "$app")/.make-app-bundle.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
bundle="$staging/$(basename -- "$app")"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

sed -e "s/\$(EXECUTABLE_NAME)/$executable_name/g" \
    -e "s/\$(PRODUCT_NAME)/$product_name/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundle_identifier/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$deployment_target/g" \
    -e "s/\$(DEVELOPMENT_LANGUAGE)/$development_language/g" \
    "$template" > "$bundle/Contents/Info.plist"
if unexpanded=$(grep -o '\$([A-Za-z0-9_]*)' "$bundle/Contents/Info.plist"); then
    echo "$0: Support/Info.plist uses build settings this script does not expand:" >&2
    echo "$unexpanded" | sort -u >&2
    exit 1
fi
plutil -lint -s "$bundle/Contents/Info.plist"
printf 'APPL????' > "$bundle/Contents/PkgInfo"

cp -- "$products/$executable_name" "$bundle/Contents/MacOS/$executable_name"
shopt -s nullglob
for resources in "$products"/*.bundle; do
    cp -R -- "$resources" "$bundle/Contents/Resources/"
done
# SwiftUI `Text` and `String(localized:)` look up Bundle.main, not Bundle.module, so the compiled
# string tables have to sit in the app's own Resources as they do in the Xcode build.
# The swiftbuild build system nests the tables under Contents/Resources; the native one does not.
localizations=("$development_language")
module_resources="$products/${executable_name}_$executable_name.bundle"
for table in "$module_resources"/Contents/Resources/*.lproj "$module_resources"/*.lproj; do
    cp -R -- "$table" "$bundle/Contents/Resources/"
    localization=$(basename -- "$table" .lproj)
    [[ "$localization" == "$development_language" ]] || localizations+=("$localization")
done
shopt -u nullglob

# actool reports the icon keys it generated in a partial Info.plist, which Xcode merges the same way.
partial_info="$staging/actool-info.plist"
if ! actool_log=$(xcrun actool --compile "$bundle/Contents/Resources" --platform macosx \
        --minimum-deployment-target "$deployment_target" --app-icon "$app_icon_name" \
        --output-partial-info-plist "$partial_info" --output-format human-readable-text \
        --errors --warnings "$app_icon" 2>&1); then
    echo "$0: actool could not compile $app_icon:" >&2
    echo "$actool_log" >&2
    exit 1
fi
for key in CFBundleIconFile CFBundleIconName; do
    value=$(plutil -extract "$key" raw -o - "$partial_info")
    plutil -replace "$key" -string "$value" "$bundle/Contents/Info.plist"
done
/usr/libexec/PlistBuddy -c "Delete :CFBundleLocalizations" "$bundle/Contents/Info.plist" \
    > /dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$bundle/Contents/Info.plist"
for localization in "${localizations[@]}"; do
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $localization" \
        "$bundle/Contents/Info.plist"
done

codesign --force --sign - --timestamp=none "$bundle"

rm -rf -- "$app"
mv -- "$bundle" "$app"
echo "$app"
