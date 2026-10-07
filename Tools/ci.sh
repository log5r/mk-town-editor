#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

python3 -B -m unittest discover -s Tools -p 'test_*.py' -v
swift test --force-resolved-versions
swift build --configuration release --force-resolved-versions
