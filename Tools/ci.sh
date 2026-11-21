#!/bin/bash
# Usage: ci.sh [python|test|release]...
# 引数なしでは全ステージを順に実行する。CIは各ステージを別ジョブで並列に実行する。
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

if [[ $# -eq 0 ]]; then
    set -- python test release
fi

for stage in "$@"; do
    case "$stage" in
        python | test | release) ;;
        *)
            echo "Unknown CI stage: $stage (expected python, test, or release)" >&2
            exit 64
            ;;
    esac
done

for stage in "$@"; do
    case "$stage" in
        python) python3 -B -m unittest discover -s Tools -p 'test_*.py' -v ;;
        test) swift test --force-resolved-versions ;;
        release) swift build --configuration release --force-resolved-versions ;;
    esac
done
