# C64 wif Friends

A Commodore 64 for iPhone, made for playing two-player games on two phones
over WiFi. It runs [VICE](https://vice-emu.sourceforge.io/) (the x64sc core
from [libretro/vice-libretro](https://github.com/libretro/vice-libretro)).

**Bring your own games.** No games come with the app: tap *Add game* and pick
a `.d64`, `.t64`, `.tap`, `.prg` or `.crt` from Files. They're kept in
*Files > On My iPhone > C64 wif Friends*.

This app is built with AI assistance.

## Status

- **One phone:** the C64 runs the game full screen with touch controls.
  Player 1 is joystick port 1.
- **Two phones (new, not yet tried on real phones):** open a game on phone
  1; on phone 2 tap *Join a friend* and pick it. Phone 2 is player 2
  (port 2): it shows phone 1's picture, plays its sound and sends its
  stick, fire and keys back. No internet needed; the same WiFi is best.

## How two phones play

Phone 1 runs the C64. Every picture is packed as a 16-colour palette with
4-bit pixels, LZ4-compressed, cut into 1100-byte UDP packets and sent to
phone 2; unchanged pictures are only resent every 10 frames. Sound goes as
mono 16-bit samples. Phone 2 sends its whole input state 30 times a second
plus on every change, so a lost packet never leaves a key stuck. Either
side counts the other as gone after 3 seconds of silence. Packet formats:
`src/netcodec.h` (tested by `tests/netcodec_test.c`, run in CI). The
networking is `ios/Net.m` (Network framework, Bonjour `_c64wif._udp`,
peer-to-peer WiFi allowed).

## Controls

- **Left thumb:** a joystick appears where your thumb lands (left side of
  the screen). 8 directions.
- **Right thumb:** FIRE (anywhere on the right side fires).
- **Portrait:** the picture fills the width at the top. Under it: F1, F3,
  F5, F7, SPACE, RETURN, STOP (RUN/STOP), held while your finger is down;
  **ABC** opens letters, digits, C=, comma and full stop (for questions
  like "Y/N?"); **MENU**.
- **Landscape:** the picture fills the height. **KEYS** (top right) opens
  the F-keys, SPACE, RETURN, STOP and the letters; **MENU** sits under it.
- **MENU:** reset the C64, or show/hide the C64's border. It's hidden by
  default, so the game itself is as big as the screen allows.
- Every press lasts at least 5 frames, so a quick tap always counts.

## Install

Every push builds an unsigned IPA on the
[ios-latest](../../releases/tag/ios-latest) release. Install it the way you
sideload other apps (AltStore, Sideloadly and so on). iOS 15 or newer.

## Building

On a Mac with Xcode: `ios/build.sh`. It fetches vice-libretro at a pinned
commit, builds it as a static library, compiles the app (`ios/`, `src/`) and
zips `build/C64wifFriends.ipa`. CI does the same: `.github/workflows/ios.yml`.

- `src/frontend.c`: a small libretro frontend (core options, video, sound
  ring, input with a minimum hold time, key events).
- `ios/main.m`: game list, the C64 screen, sound output, menu.
- `ios/TouchOverlay.m`: the touch controls.
- `ios/make_icon.py`: draws the icon.

## Licence

GPL v2 or later, like VICE (see `COPYING`). `src/libretro.h` is MIT
(libretro). The game files you add are yours and never leave your phone.
