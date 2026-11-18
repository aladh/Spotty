"""Configure an optional, independently signed Rune release channel before signing the bundle."""
import base64
import os
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlsplit


def configure(info, upstream, env):
    number = env.get("SPOTTY_RUNE_BUILD_NUMBER", info["CFBundleVersion"])
    if not (number.isascii() and number.isdigit() and int(number) > 0):
        raise ValueError("SPOTTY_RUNE_BUILD_NUMBER must be a positive integer")
    info["CFBundleVersion"] = number
    feed = env.get("SPOTTY_RUNE_UPDATE_FEED_URL", "")
    key = env.get("SPOTTY_RUNE_UPDATE_PUBLIC_KEY", "")
    if not (feed or key):
        return
    url = urlsplit(feed)
    if (url.scheme != "https" or not url.hostname or url.username is not None or
            url.password is not None or url.fragment or feed == upstream["SUFeedURL"]):
        raise ValueError("Set SPOTTY_RUNE_UPDATE_FEED_URL to the dedicated HTTPS Rune appcast")
    public_key = base64.b64decode(key, validate=True)
    if len(public_key) != 32 or public_key == base64.b64decode(upstream["SUPublicEDKey"]):
        raise ValueError("Set SPOTTY_RUNE_UPDATE_PUBLIC_KEY to the dedicated Rune Ed25519 public key")
    info.update(SpottyRuneUpdateChannel="rune", SUFeedURL=feed, SUPublicEDKey=key,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                SUEnableAutomaticChecks=True, SUAllowsAutomaticUpdates=False,
                SUSendProfileInfo=False)


if __name__ == "__main__":
    target, upstream = map(Path, sys.argv[1:])
    info = plistlib.loads(target.read_bytes())
    try:
        configure(info, plistlib.loads(upstream.read_bytes()), os.environ)
    except ValueError as error:
        raise SystemExit(error)
    target.write_bytes(plistlib.dumps(info, sort_keys=False))
