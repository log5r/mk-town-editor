#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 ]] || [[ $# -eq 1 && "$1" != "rebuild" ]]; then
    echo "Usage: $0 [rebuild]" >&2
    exit 2
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

if [[ "${1:-}" == "rebuild" ]]; then
    swift package clean
fi

exec swift run --configuration release MKTownEditor
