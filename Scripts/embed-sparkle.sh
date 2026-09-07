# Shared by shipping and isolated demo packaging. Sign nested code before the host.
spotty_embed_sparkle() {
    local destination_app="$1"
    local signing_identity="$2"
    shift 2
    local source_framework="$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    local framework="$destination_app/Contents/Frameworks/Sparkle.framework"
    [[ -d "$source_framework" ]] || { print -u2 "Missing resolved Sparkle framework"; return 1; }
    mkdir -p "$destination_app/Contents/Frameworks"
    ditto "$source_framework" "$framework"
    local nested
    for nested in \
        "$framework/Versions/B/XPCServices/Downloader.xpc" \
        "$framework/Versions/B/XPCServices/Installer.xpc" \
        "$framework/Versions/B/Autoupdate" \
        "$framework/Versions/B/Updater.app" \
        "$framework"; do
        codesign --force --options runtime --preserve-metadata=entitlements --sign "$signing_identity" "$@" "$nested"
    done
    codesign --verify --deep --strict "$framework"
}
