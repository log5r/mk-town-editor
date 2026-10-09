#!/bin/bash
# Upload verified output as a draft; a published release is never replaced.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/Tools/release-common.sh"
validate_release_metadata
cd "$RELEASE_OUTPUT_DIR"
# Verify assets before creating a draft, including on workflow reruns.
test -s "$release_asset"
test -s SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
if existing=$(gh release view "$RELEASE_TAG" --json isDraft); then
    python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1])["isDraft"] else "Refusing to replace a published release. Use a new version tag.")' "$existing"
    gh release upload "$RELEASE_TAG" "$release_asset" SHA256SUMS.txt --clobber
else
    notes=$(mktemp)
    trap 'rm -f -- "$notes"' EXIT
    cat > "$notes" <<'NOTES'
macOS 14以降 / Apple Silicon・Intel対応（Universal）

ZIPを展開し、MKTownEditor.appをApplicationsフォルダへ移動してください。
アプリはDeveloper IDで署名し、Appleの公証チケットを添付しています。
SHA256SUMS.txtでZIPのチェックサムを確認できます。

公開前に、変更内容を追記し、ダウンロードしたアプリの起動・書類操作を確認してください。
NOTES
    options=(--verify-tag --draft)
    if [[ $RELEASE_TAG == *-* ]]; then
        options+=(--prerelease)
    fi
    gh release create "$RELEASE_TAG" "$release_asset" SHA256SUMS.txt \
        --title "MKTownEditor ${RELEASE_TAG#v}" \
        --notes-file "$notes" "${options[@]}"
fi
