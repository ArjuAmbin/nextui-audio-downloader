# Audio Downloader (NextUI Tool pak)

A stripped-down, **download-only** tool for NextUI on the TrimUI Brick.
It can search and download:

- **Music** — searches YouTube Music, downloads best-quality `.m4a` to
  `/Music/Downloaded`
- **Podcast episodes** — searches Apple's iTunes podcast directory, reads the
  show's RSS feed, downloads an episode to `/Podcasts/<Show Name>/`

It has **no playback functionality** at all — it's meant to be used
alongside a separate player that doesn't have its own
downloader.

It was built by extracting the exact search/download commands used
internally by [nborodikhin/nextui-music-player](https://github.com/nborodikhin/nextui-music-player)
(the "Music Player" pak you already have), then wiring them up in a plain
shell script with none of the playback/library/radio code.

This pak's on-screen menus, keyboard, and popups are built on three small,
well-known community tools (`minui-list`, `minui-keyboard`, `minui-presenter`)
by josegonzalez, bundled

   | Tool | Releases page | Download asset | Save as |
   |---|---|---|---|
   | minui-list | https://github.com/josegonzalez/minui-list/releases | `minui-list-tg5040` | `bin/tg5040/minui-list` |
   | minui-keyboard | https://github.com/josegonzalez/minui-keyboard/releases | `minui-keyboard-tg5040` | `bin/tg5040/minui-keyboard` |
   | minui-presenter | https://github.com/josegonzalez/minui-presenter/releases | `minui-presenter-tg5040` | `bin/tg5040/minui-presenter` 

## Installation

1. Copy the whole `Audio Downloader.pak` folder to `/Tools/tg5040/` on your
   SD card.
2. Eject the SD card, boot the device, open **Tools > Audio Downloader**.

## Usage

- **Search Music** → type a search term on the on-screen keyboard → pick a
  result from the list → it downloads to `Music/Downloaded`.
- **Search Podcast** → type a show name → pick the show → pick an episode →
  it downloads to `Podcasts/<Show Name>/`.
- Files already downloaded (matched by sanitized filename) won't be
  re-downloaded.
- Logs are written to `.userdata/tg5040/logs/Audio Downloader.txt` if
  something goes wrong — check there first.

## Known limitations / things to test

I (Claude) don't have a physical TrimUI Brick, and couldn't run the real ARM
binaries in the environment I built this in — so while I:

- extracted the *exact* search/download command lines from the original
  Music Player binary (verified via string analysis of the compiled app),
- syntax-checked the shell script against `dash` (a close match for the
  device's busybox shell),
- and dry-ran the full menu → search → select → download flow against stand-in
  versions of every external tool (including sample iTunes JSON and RSS
  feed data),

...I (Claude) have **not** been able to test it on the actual device. Please treat
the first run as a test, and check the log file if a step doesn't behave
as expected. A few specific things that are best-effort:

... Arju Ambin has tested on a Trimui Brick Hammer and verified by posting logs and making Claude fixing bugs. 

- **RSS parsing** uses plain `grep`/`sed`, not a real XML parser. It
  handles normal `<title>` and `<title><![CDATA[...]]></title>` episodes,
  and matches titles to their `<enclosure url="...">` by position within
  each `<item>` block. Very unusual feeds could parse incorrectly.
- **Duplicate titles**: if two search results have the exact same title,
  the tool will always pick the first match when mapping your selection
  back to a download link.
- The **on-screen keyboard/list/message tools are not bundled** (see setup
  above) — this was the one piece I couldn't fetch or build myself.

## Credits

Search/download logic pattern based on
[nborodikhin/nextui-music-player](https://github.com/nborodikhin/nextui-music-player)
(MIT licensed). `wget` and `yt-dlp` binaries carried over unmodified from
that pak. `minui-list` / `minui-keyboard` / `minui-presenter` by
[josegonzalez](https://github.com/josegonzalez).

Claude for Vibecoding this.
