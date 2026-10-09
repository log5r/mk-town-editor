#!/bin/bash
# Build a Developer ID-signed, notarized Universal app. GitHub upload is a separate step.
set -euo pipefail
set +x
umask 077
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/Tools/release-common.sh"
validate_release_metadata
if [[ ! ${RELEASE_BUILD_NUMBER:-} =~ ^[1-9][0-9]*$ ]]; then
    echo 'RELEASE_BUILD_NUMBER must be a positive integer.' >&2
    exit 1
fi
for name in APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_TEAM_ID APPLE_ID APPLE_APP_SPECIFIC_PASSWORD; do
    if [[ -z ${!name:-} ]]; then
        echo "Missing required secret: $name" >&2
        exit 1
    fi
done
if [[ ! $APPLE_TEAM_ID =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'APPLE_TEAM_ID must be a 10-character Apple Team ID.' >&2
    exit 1
fi
mkdir -p "$RELEASE_OUTPUT_DIR"
if [[ -n $(ls -A "$RELEASE_OUTPUT_DIR") ]]; then
    echo 'RELEASE_OUTPUT_DIR must be empty; use a new directory for each build.' >&2
    exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/mktown-release.XXXXXX")
keychain="$work/signing.keychain-db"
original_keychains=()
cleanup() {
    local status=$?
    trap - EXIT
    if [[ ${#original_keychains[@]} -gt 0 ]]; then
        security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
    fi
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -rf -- "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

security list-keychains -d user > "$work/keychains.txt"
python3 - "$work/keychains.txt" > "$work/keychain-paths.txt" <<'PY'
import pathlib, shlex, sys
for path in shlex.split(pathlib.Path(sys.argv[1]).read_text()):
    print(path)
PY
while IFS= read -r path; do
    original_keychains+=("$path")
done < "$work/keychain-paths.txt"
keychain_password=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
python3 - "$work/certificate.p12" <<'PY'
import base64, os, pathlib, sys
try:
    data = base64.b64decode(''.join(os.environ['APPLE_CERTIFICATE_P12_BASE64'].split()), validate=True)
except ValueError:
    sys.exit('APPLE_CERTIFICATE_P12_BASE64 is not valid Base64.')
pathlib.Path(sys.argv[1]).write_bytes(data)
PY
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" \
    -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$keychain_password" "$keychain" >/dev/null
if [[ ${#original_keychains[@]} -gt 0 ]]; then
    security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
else
    security list-keychains -d user -s "$keychain"
fi
security find-identity -v -p codesigning "$keychain" > "$work/identities.txt"
identity=$(python3 - "$work/identities.txt" <<'PY'
import os, pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
identities = re.findall(r'\b([A-Fa-f0-9]{40}) "Developer ID Application: [^"\n]+ \(' +
                        re.escape(os.environ['APPLE_TEAM_ID']) + r'\)"', text)
if len(identities) != 1:
    sys.exit('The P12 must contain exactly one valid Developer ID Application identity for APPLE_TEAM_ID, including its private key.')
print(identities[0])
PY
)

# Build a temporary plist, so local development defaults and tracked files remain untouched.
python3 - "$root/Support/Info.plist" "$work/Info.plist" "$release_version" "$RELEASE_BUILD_NUMBER" <<'PY'
import pathlib, plistlib, sys
info = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
info['CFBundleShortVersionString'] = sys.argv[3]
info['CFBundleVersion'] = sys.argv[4]
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(info))
PY
xcodebuild archive \
    -project "$root/MKTownEditor.xcodeproj" -scheme MKTownEditor -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$work/MKTownEditor.xcarchive" \
    -derivedDataPath "$work/DerivedData" -clonedSourcePackagesDirPath "$work/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    "INFOPLIST_FILE=$work/Info.plist" "MARKETING_VERSION=$release_version" \
    "CURRENT_PROJECT_VERSION=$RELEASE_BUILD_NUMBER" \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp

distribution="$work/MKTownEditor-${RELEASE_TAG#v}"
mkdir -p "$distribution"
app="$distribution/MKTownEditor.app"
ditto "$work/MKTownEditor.xcarchive/Products/Applications/MKTownEditor.app" "$app"
for architecture in arm64 x86_64; do
    lipo "$app/Contents/MacOS/MKTownEditor" -verify_arch "$architecture"
done
codesign --verify --deep --strict --verbose=2 "$app"
codesign --display --verbose=4 "$app" 2> "$work/signature.txt"
python3 - "$app/Contents/Info.plist" "$work/signature.txt" "$release_version" "$RELEASE_BUILD_NUMBER" <<'PY'
import os, pathlib, plistlib, sys
info = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
signature = pathlib.Path(sys.argv[2]).read_text()
if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != tuple(sys.argv[3:5]):
    sys.exit('Archive version does not match the release metadata.')
if ('Authority=Developer ID Application:' not in signature or
        'TeamIdentifier=' + os.environ['APPLE_TEAM_ID'] not in signature or
        'runtime' not in signature or 'Timestamp=' not in signature):
    sys.exit('Archive must have Developer ID signing, the expected Team, Hardened Runtime and a secure timestamp.')
PY

xcrun notarytool store-credentials MKTownEditor-notary --keychain "$keychain" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarization.zip"
# Preserve JSON even on submission failure, and explicitly require Accepted before packaging.
submission_status=0
xcrun notarytool submit "$work/notarization.zip" --keychain-profile MKTownEditor-notary \
    --keychain "$keychain" --wait --timeout 30m --output-format json \
    > "$RELEASE_OUTPUT_DIR/notarization-result.json" || submission_status=$?
submission_id=$(python3 - "$RELEASE_OUTPUT_DIR/notarization-result.json" <<'PY'
import json, pathlib, sys
try:
    print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get('id', ''))
except (ValueError, OSError):
    pass
PY
)
if [[ -n $submission_id ]]; then
    xcrun notarytool log "$submission_id" --keychain-profile MKTownEditor-notary \
        --keychain "$keychain" "$RELEASE_OUTPUT_DIR/notarization-log.json" || true
fi
if [[ $submission_status -ne 0 ]]; then
    echo 'Notarization submission failed or timed out. See notarization-result.json.' >&2
    exit "$submission_status"
fi
python3 - "$RELEASE_OUTPUT_DIR/notarization-result.json" <<'PY'
import json, pathlib, sys
if json.loads(pathlib.Path(sys.argv[1]).read_text()).get('status') != 'Accepted':
    sys.exit('Notarization was not Accepted. See notarization-log.json; no release ZIP was created.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=2 "$app"
cp "$root/LICENSE" "$distribution/LICENSE.txt"
cp "$root/docs/third-party-licenses.md" "$distribution/ThirdPartyLicenses.md"
cp "$work/SourcePackages/checkouts/SwiftMath/LICENSE" "$distribution/SwiftMath-LICENSE.txt"
ditto -c -k --sequesterRsrc --keepParent "$distribution" "$RELEASE_OUTPUT_DIR/$release_asset"
(
    cd "$RELEASE_OUTPUT_DIR"
    shasum -a 256 "$release_asset" > SHA256SUMS.txt
)
echo "Created $RELEASE_OUTPUT_DIR/$release_asset"
