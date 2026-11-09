# C64 wif Friends

A Commodore 64 for iPhone, made for playing two-player games on two phones
over WiFi. It runs [VICE](https://vice-emu.sourceforge.io/) (the x64sc core
from [libretro/vice-libretro](https://github.com/libretro/vice-libretro)).

**Bring your own games.** No games come with the app: tap *Add game* and pick
a `.d64`, `.t64`, `.tap`, `.prg` or `.crt` from Files. They're kept in
*Files > On My iPhone > C64 wif Friends*.

This app is built with AI assistance.

## Status

- **v0.1 (now):** one phone. The C64 runs the game full screen with touch
  controls. Player 1 is joystick port 1.
- **Next:** two phones. One hosts the game, the other joins from a list of
  nearby phones and plays as player 2 (port 2). No internet needed.

## Controls

- **Left thumb:** a joystick appears where your thumb lands (left side of
  the screen). 8 directions.
- **Right thumb:** FIRE (anywhere on the right side fires).
- **Top row:** F1, F3, F5, F7, SPACE, RETURN, STOP (RUN/STOP), held while
  your finger is down; **ABC** opens letters, digits, C=, comma and full
  stop (for questions like "Y/N?"); **MENU** resets the C64.
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
