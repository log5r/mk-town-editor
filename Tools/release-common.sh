#!/bin/bash
# Sourced by the build and upload scripts. Values come from env, never shell evaluation.

validate_release_metadata() {
    local tag_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'
    if [[ ! ${RELEASE_TAG:-} =~ $tag_pattern ]]; then
        echo 'RELEASE_TAG must be vMAJOR.MINOR.PATCH, optionally followed by -beta.1 or another prerelease suffix.' >&2
        return 1
    fi
    release_version=${RELEASE_TAG#v}
    release_version=${release_version%%-*}
    if [[ ! ${RELEASE_OUTPUT_DIR:-} = /* ]]; then
        echo 'RELEASE_OUTPUT_DIR must be an absolute path.' >&2
        return 1
    fi
    release_asset="MKTownEditor-${RELEASE_TAG#v}-macOS-universal.zip"
}
