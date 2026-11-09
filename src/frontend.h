/* C64 wif Friends: a tiny libretro frontend for the VICE x64sc core.
 *
 * Plain C, no UI: the iOS layer (ios/) owns the window, sound output and
 * touch controls, and talks to the emulator only through these calls.
 *
 * Threads: fe_start(), fe_run_frame() and fe_reset() run on the emulator
 * thread. fe_set_joy(), fe_key(), fe_copy_frame() and fe_audio_read() are
 * safe from any thread.
 */
#ifndef C64WIF_FRONTEND_H
#define C64WIF_FRONTEND_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Joystick bits, the same as RetroPad ids (B is fire). */
enum {
   FE_JOY_FIRE  = 1u << 0,   /* RETRO_DEVICE_ID_JOYPAD_B */
   FE_JOY_UP    = 1u << 4,
   FE_JOY_DOWN  = 1u << 5,
   FE_JOY_LEFT  = 1u << 6,
   FE_JOY_RIGHT = 1u << 7
};

/* Directories for VICE's own files and the log. Call once, first. */
void fe_setup(const char *system_dir, const char *save_dir, const char *log_path);

/* Boots the C64 and loads a disk/tape/program file. False if the core
 * refused it (fe_last_error() says why). Emulator thread. */
bool fe_start(const char *game_path);
const char *fe_last_error(void);

void fe_run_frame(void);       /* one video frame. Emulator thread. */
void fe_reset(void);           /* hard reset of the C64. Emulator thread. */

double fe_fps(void);           /* ~50.12 for PAL */
double fe_sample_rate(void);
float  fe_aspect(void);        /* display aspect of the picture */
bool   fe_fast_forward(void);  /* VICE asks for warp while it loads */

/* Input. Players are 0 (port 1) and 1 (port 2). Every press is held for at
 * least FE_MIN_HOLD_FRAMES frames, so a quick tap is never missed. */
#define FE_MIN_HOLD_FRAMES 5
void fe_set_joy(int player, uint32_t bits);
void fe_key(unsigned retrok, bool down);      /* a libretro RETROK_* code */

/* Changes a VICE setting (any thread). Before fe_start() it applies from
 * boot; later, VICE picks it up before the next frame. */
void fe_set_option(const char *key, const char *value);

/* Copies the newest picture (XRGB8888, little-endian) into dst if it has
 * changed since *seq. dst must hold 512*320 pixels. Returns true if copied. */
#define FE_MAX_W 512
#define FE_MAX_H 320
bool fe_copy_frame(uint32_t *dst, unsigned *w, unsigned *h, uint64_t *seq);

/* Sound: interleaved stereo int16. Fills `frames` frames, padding with
 * silence when the emulator is behind. Returns frames really read. */
size_t fe_audio_read(int16_t *out, size_t frames);
size_t fe_audio_buffered(void); /* frames waiting */

void fe_log(const char *fmt, ...);

#endif
