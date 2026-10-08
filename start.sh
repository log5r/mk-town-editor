#!/bin/bash
# Build a Release MKTownEditor.app from the Swift package and open it, optionally with documents.
# See docs/production-launcher.md.
set -euo pipefail

usage() {
    echo "Usage: $0 [rebuild] [FILE ...]" >&2
    exit 2
}

rebuild=false
if [[ $# -gt 0 && "$1" == "rebuild" ]]; then
    rebuild=true
    shift
fi

documents=()
for document in "$@"; do
    if [[ -z "$document" || ! -f "$document" ]]; then
        echo "$0: not a file: '$document'" >&2
        usage
    fi
    [[ "$document" == /* ]] || document="$PWD/$document"
    documents+=("$document")
done

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

if $rebuild; then
    swift package clean
fi

swift build --configuration release
products=$(swift build --configuration release --show-bin-path)
app="$PWD/.build/MKTownEditor.app"
Tools/make-app-bundle.sh "$products" "$app" > /dev/null

if ps -axo command= | grep -Fq -- "$app/Contents/MacOS/MKTownEditor"; then
    echo "$0: MKTownEditor is already running from $app; quit it to use the new build." >&2
fi

exec open -a "$app" ${documents[@]+"${documents[@]}"}
