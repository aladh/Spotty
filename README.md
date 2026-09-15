<p align="center">
  <img src="Assets/SpottyIcon.png" width="112" height="112" alt="Spotty">
</p>

# Spotty

**Your Spotify music. A native Mac app.**

Listen in a familiar Spotify layout with the menus, keyboard shortcuts, and track selection
you expect on a Mac.

**[Download Spotty](https://github.com/aladh/Spotty/releases/latest)**

Requires **macOS 15 or newer**, an **Apple Silicon Mac**, and **Spotify Premium**.

![Spotty showing a playlist details page with synthetic demo data](Assets/PlaylistScreenshot.jpg)

## Why Spotty?

- **Explore your music.** Search Spotify, browse your playlists and Liked Songs, and discover
  albums and artists through pages built around their artwork.
- **Keep the music flowing.** Play on your Mac at 320 kbps with gapless transitions and shuffle that
  favors fewer repeats.
- **Make the queue yours.** Add tracks to your queue and add or remove songs from playlists you own.
- **Choose where it plays.** Switch playback between your Mac and Spotify Connect devices.
- **No analytics or ads.** Spotty connects directly to Spotify, with no Spotty-operated server.
  [Read the privacy details](PRIVACY.md).

## Download and install

1. Download `Spotty-<version>.zip` from the [latest release](https://github.com/aladh/Spotty/releases/latest).
2. Unzip it and drag **Spotty.app** into **Applications**.
3. Open Spotty, choose **Connect Spotify**, and finish signing in through your browser.

Already using Spotty? Choose **Spotty → Check for Updates…**.
You can also [verify the download's checksum](docs/development/releases.md#verify-a-download).

### First launch on macOS

Spotty is not notarized or Developer ID signed, so macOS may block the first launch. If you trust
this download, allow it through System Settings:

1. If the first launch is blocked, dismiss the alert without moving Spotty to Trash.
2. Open **System Settings → Privacy & Security** and choose **Open Anyway** for Spotty.
3. Authenticate if asked, then confirm that you want to open it.

See [Apple's first-open guidance](https://support.apple.com/en-us/102445) for details.

## About the project

Spotty is an independent, unofficial client for personal, non-commercial experimentation.
It is not affiliated with Spotify and uses private Spotify interfaces.

The [MIT license](LICENSE) covers Spotty's code, not rights to Spotify's service, content,
trademarks, or private interfaces. Review Spotify's [Developer Policy](https://developer.spotify.com/policy)
before considering distribution. Credits and dependency notices are in [NOTICE](NOTICE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

[Build from source](docs/development/setup.md#fresh-clone) · [Documentation](docs/README.md) ·
[Report a security issue privately](SECURITY.md)
