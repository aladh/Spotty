#!/bin/sh

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

    # Remote binary targets are downloaded by SwiftPM. Resolve on every lookup so a changed
    # package pin cannot leave an old workspace-state path selected; do not guess from the
    # ignored local producer directory.
    local_workspace_state="$project_root/.build/workspace-state.json"
    if ! swift package resolve --package-path "$project_root" >&2; then
        echo "SwiftPM could not resolve the pinned SpottyPlaybackCore artifact" >&2
        return 1
    fi
    if [ ! -f "$local_workspace_state" ]; then
        echo "SwiftPM did not write workspace state for the SpottyPlaybackCore artifact" >&2
        return 1
    fi

    # The workspace state stores binary artifacts under object.artifacts. Walk its bounded
    # array with plutil so app-only checks require the Apple toolchain alone. Select exactly the
    # SpottyPlaybackCore remote entry and its recorded path; never accept another artifact or a
    # local producer path left under this checkout. The URL/checksum comparison below also rejects
    # a state entry that belongs to an older package pin.
    local_resolved_path=""
    local_resolved_count=0
    local_resolved_index=""
    artifact_index=0
    while [ "$artifact_index" -lt 64 ]; do
        artifact_target="$(plutil -extract "object.artifacts.$artifact_index.targetName" raw -o - "$local_workspace_state" 2>/dev/null || true)"
        if [ -z "$artifact_target" ]; then
            break
        fi
        if [ "$artifact_target" != "SpottyPlaybackCore" ]; then
            artifact_index=$((artifact_index + 1))
            continue
        fi
        artifact_source="$(plutil -extract "object.artifacts.$artifact_index.source.type" raw -o - "$local_workspace_state" 2>/dev/null || true)"
        case "$artifact_source" in
            remote|url) ;;
            *)
                echo "SwiftPM SpottyPlaybackCore entry is not a remote artifact" >&2
                return 1
                ;;
        esac
        artifact_path="$(plutil -extract "object.artifacts.$artifact_index.path" raw -o - "$local_workspace_state" 2>/dev/null || true)"
        if [ -z "$artifact_path" ]; then
            echo "SwiftPM SpottyPlaybackCore entry has no artifact path" >&2
            return 1
        fi
        case "$artifact_path" in
            /*) candidate_path="$artifact_path" ;;
            *) candidate_path="$project_root/$artifact_path" ;;
        esac
        if [ ! -d "$candidate_path" ] || [ "${candidate_path##*.}" != "xcframework" ]; then
            echo "SwiftPM SpottyPlaybackCore artifact path is missing: $artifact_path" >&2
            return 1
        fi
        local_resolved_path="$(cd "$candidate_path" && pwd -P)"
        local_resolved_index="$artifact_index"
        local_resolved_count=$((local_resolved_count + 1))
        artifact_index=$((artifact_index + 1))
    done

    if [ "$local_resolved_count" -ne 1 ]; then
        echo "Expected one resolved remote SpottyPlaybackCore artifact in SwiftPM workspace state; found $local_resolved_count" >&2
        return 1
    fi

    # Reject a stale resolved artifact after a Package.swift pin change.
    manifest_url="$(spotty_playback_pin_value url)" || return 1
    manifest_checksum="$(spotty_playback_pin_value checksum)" || return 1
    state_url="$(plutil -extract "object.artifacts.$local_resolved_index.source.url" raw -o - "$local_workspace_state" 2>/dev/null || true)"
    state_checksum="$(plutil -extract "object.artifacts.$local_resolved_index.source.checksum" raw -o - "$local_workspace_state" 2>/dev/null || true)"
    if [ -z "$manifest_url" ] || [ -z "$manifest_checksum" ] || [ -z "$state_url" ] || [ -z "$state_checksum" ]; then
        echo "SwiftPM SpottyPlaybackCore state or package pin is missing its remote URL/checksum" >&2
        return 1
    fi
    if [ "$state_url" != "$manifest_url" ] || [ "$(printf '%s' "$state_checksum" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$manifest_checksum" | tr '[:upper:]' '[:lower:]')" ]; then
        echo "SwiftPM SpottyPlaybackCore state does not match Package.swift" >&2
        return 1
    fi
    printf '%s\n' "$local_resolved_path"
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
