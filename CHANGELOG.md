# Changelog

All notable changes to Peerdeck are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

Each release's section is generated from its commits by `scripts/release.sh` (see `cliff.toml`)
and used as its GitHub Release notes.

## [Unreleased]

## [0.1.0] - 2026-11-23

First preview release.

**Before deleting files:** Peerdeck recognizes shared data by infohash or name. It can't detect renamed cross-seeds, torrents that share only some files, or clients you haven't added. If any of your servers is offline, turned off or can't be checked, only the torrent is removed and its files are kept.

### macOS

- One list for every torrent across several qBittorrent, Transmission and Flood servers, tested with 20,000 torrents per server.
- Sidebar views by state, server, site, category and tag, with live counts.
- Problem views for torrents the tracker rejects, likely unregistered torrents, and trackers unreachable for a long time.
- Clean up likely unregistered torrents in one step; torrents whose data is shared with a cross-seed are kept, and each one is checked again before it is removed.
- Deletes wait 10 seconds and can be undone.
- Add torrents from magnet links, `.torrent` files or URLs, with a per-site default server; choose which files to download once added.
- Replace tracker URLs in bulk, with undo.
- Menu bar panel with current speeds and problems; notifications for finished downloads.

### iOS

- Overview with current speeds, all-time totals, and a "Needs Attention" page that groups problems by the tracker's own message.
- Torrent list with filters, search, multi-select and swipe actions.
- Sites tab with problem counts and per-site uploaded, downloaded and size totals.
- Servers tab with status, speeds, free space and alternative speed limits.
- Share extension for adding magnet links and `.torrent` files from other apps (needs signing with the App Group and shared Keychain; unavailable in sideloaded builds of the unsigned ipa).
- Supports iOS 17 and later; uses Liquid Glass on iOS 26.

### Installation

- macOS: Homebrew cask or dmg (ad-hoc signed, not notarized).
- iOS: unsigned ipa with an AltStore / SideStore source; TrollStore works on iOS 17.0 only.

### Connections

- qBittorrent, Transmission, and Flood (for rTorrent). Through Flood, tracker problems and cleanup work with rTorrent and Transmission only.
- Each server can have several routes (LAN, overlay network, DDNS, reverse proxy); the highest-priority route that is reachable is used.
- Self-signed HTTPS certificates can be trusted by fingerprint.
- Passwords are stored in the Keychain.

[Unreleased]: ../../compare/v0.1.0...HEAD
[0.1.0]: ../../releases/tag/v0.1.0
