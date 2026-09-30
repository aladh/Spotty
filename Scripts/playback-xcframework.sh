# Shared read-only lookup for the selected SpottyPlaybackCore XCFramework. Keep the SwiftPM
# artifact lookup here so build, verification, packaging, and size reporting inspect the same
# binary/header pair. This file is sourced by the entry-point scripts.

# Read the two literal dependency declarations without evaluating the Swift package.
spotty_playback_pin_value() {
    case "$1" in
        url) pin_name=generatedPlaybackArtifactURL ;;
        checksum) pin_name=generatedPlaybackArtifactChecksum ;;
        *) return 1 ;;
    esac
    PIN_NAME="$pin_name" perl -0777 -ne '
        my @values = /private\s+let\s+\Q$ENV{PIN_NAME}\E\s*=\s*"([^"]+)"/g;
        die "Expected one playback pin declaration\n" unless @values == 1;
        if ($ENV{PIN_NAME} eq "generatedPlaybackArtifactURL" && $values[0] !~
            m{\Ahttps://github\.com/aladh/Spotty/releases/download/playback-v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)/SpottyPlaybackCore\.xcframework\.zip\z}) {
            die "Playback pin must name a canonical Spotty playback-vMAJOR.MINOR.PATCH release asset\n";
        }
        if ($ENV{PIN_NAME} eq "generatedPlaybackArtifactChecksum" && $values[0] !~ /\A[0-9a-fA-F]{64}\z/) {
            die "Playback pin checksum must contain exactly 64 hexadecimal characters\n";
        }
        print "$values[0]\n";
    ' "$project_root/Package.swift"
}

spotty_playback_resolve_xcframework() {
    if [ -z "${project_root:-}" ]; then
        echo "project_root must be set before resolving SpottyPlaybackCore" >&2
        return 1
    fi

    if [ -n "${SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK:-}" ]; then
        local_playback_path="$SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK"
        while [ "${local_playback_path%/}" != "$local_playback_path" ]; do
            local_playback_path="${local_playback_path%/}"
        done
        case "$local_playback_path" in
            /*) ;;
            *) local_playback_path="$project_root/$local_playback_path" ;;
        esac
        if [ ! -d "$local_playback_path" ] || [ "${local_playback_path##*.}" != "xcframework" ]; then
            echo "SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK must point to an existing .xcframework directory" >&2
            return 1
        fi
        (cd "$local_playback_path" && pwd -P)
        return 0
    fi

    manifest_url="$(spotty_playback_pin_value url)" || return 1
    manifest_checksum="$(spotty_playback_pin_value checksum)" || return 1

    # Remote binary targets are downloaded by SwiftPM. Resolve on every lookup so a changed
    # package pin cannot leave an old workspace-state path selected; do not guess from the
    # ignored local producer directory.
    local_workspace_state="$project_root/.build/workspace-state.json"
    if ! SPOTTY_PACKAGE_GRAPH=full swift package resolve --package-path "$project_root" >&2; then
        echo "SwiftPM could not resolve the pinned SpottyPlaybackCore artifact" >&2
        return 1
    fi
    if [ ! -f "$local_workspace_state" ]; then
        echo "SwiftPM did not write workspace state for the SpottyPlaybackCore artifact" >&2
        return 1
    fi

    # Parse the bounded artifact array once, after resolution. Selection still requires exactly
    # one remote entry, an existing XCFramework, and the current manifest URL/checksum.
    python3 "$project_root/Scripts/playback_artifact.py" resolve \
        "$project_root" "$local_workspace_state" "$manifest_url" "$manifest_checksum"
}

spotty_playback_slice_path() {
    local_playback_path="$1"
    local_playback_slice="$local_playback_path/macos-arm64"
    if [ ! -d "$local_playback_slice" ]; then
        echo "SpottyPlaybackCore is missing its macos-arm64 slice: $local_playback_path" >&2
        return 1
    fi
    printf '%s\n' "$local_playback_slice"
}

spotty_playback_archive_path() {
    local_playback_slice="$1"
    local_playback_framework="$(dirname "$local_playback_slice")"
    local_playback_info="$local_playback_framework/Info.plist"
    if [ ! -f "$local_playback_info" ]; then
        echo "SpottyPlaybackCore metadata is missing: $local_playback_info" >&2
        return 1
    fi
    if [ "$(plutil -extract 'AvailableLibraries.0.LibraryIdentifier' raw -o - "$local_playback_info" 2>/dev/null || true)" != "macos-arm64" ]; then
        echo "SpottyPlaybackCore metadata must identify the macos-arm64 slice" >&2
        return 1
    fi
    local_playback_library_path="$(plutil -extract 'AvailableLibraries.0.LibraryPath' raw -o - "$local_playback_info" 2>/dev/null || true)"
    case "$local_playback_library_path" in
        ""|/*|*..*|*/*)
            echo "SpottyPlaybackCore metadata has an unsafe library path: ${local_playback_library_path:-<empty>}" >&2
            return 1
            ;;
    esac
    local_playback_archive="$local_playback_slice/$local_playback_library_path"
    if [ ! -f "$local_playback_archive" ]; then
        echo "SpottyPlaybackCore archive is missing: $local_playback_archive" >&2
        return 1
    fi
    printf '%s\n' "$local_playback_archive"
}

spotty_playback_headers_path() {
    local_playback_slice="$1"
    local_playback_headers="$local_playback_slice/Headers"
    if [ ! -d "$local_playback_headers" ]; then
        echo "SpottyPlaybackCore headers are missing: $local_playback_headers" >&2
        return 1
    fi
    for local_playback_header in spotty_playback.h spotty_playback_generated.h spotty_playback_annotations.h module.modulemap; do
        if [ ! -f "$local_playback_headers/$local_playback_header" ]; then
            echo "SpottyPlaybackCore header is missing: $local_playback_headers/$local_playback_header" >&2
            return 1
        fi
    done
    printf '%s\n' "$local_playback_headers"
}

spotty_playback_validate_xcframework() {
    local_playback_path="$1"
    local_playback_validator="${project_root:-}/Backend/spotty-playback/validate-xcframework.sh"
    if [ ! -x "$local_playback_validator" ]; then
        echo "XCFramework validator is missing or not executable: $local_playback_validator" >&2
        return 1
    fi
    if [ -n "${SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK:-}" ]; then
        # A source-built local artifact intentionally differs from the published remote pin.
        "$local_playback_validator" "$local_playback_path"
    else
        "$local_playback_validator" "$local_playback_path" --published
    fi
}
