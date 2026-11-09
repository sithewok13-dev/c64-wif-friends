/* C64 wif Friends: a tiny libretro frontend for the VICE x64sc core.
 * See frontend.h. The core is linked in statically (retro_* symbols). */
#include "frontend.h"
#include "libretro.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ------------------------------------------------------------------ */
/* Settings we force on the core. Everything else keeps VICE's default. */
static const char *const k_overrides[][2] = {
   { "vice_joyport",              "1" },        /* pad 1 -> port 1, pad 2 -> port 2 */
   { "vice_autoloadwarp",         "enabled" },  /* load fast, play at normal speed */
   { "vice_drive_true_emulation", "enabled" },
   { "vice_statusbar",            "disabled" },
   { "vice_statusbar_startup",    "disabled" },
   /* We only ever press fire and directions on the pads; keys come in as
    * real key presses, so no pad button needs a mapping. */
   { "vice_mapper_select", "---" }, { "vice_mapper_start", "---" },
   { "vice_mapper_a", "---" },      { "vice_mapper_y", "---" },
   { "vice_mapper_x", "---" },      { "vice_mapper_l", "---" },
   { "vice_mapper_r", "---" },      { "vice_mapper_l2", "---" },
   { "vice_mapper_r2", "---" },     { "vice_mapper_l3", "---" },
   { "vice_mapper_r3", "---" },
};

/* ------------------------------------------------------------------ */
static char s_system_dir[1024] = ".";
static char s_save_dir[1024] = ".";
static FILE *s_log;
static pthread_mutex_t s_log_lock = PTHREAD_MUTEX_INITIALIZER;
static char s_error[256];

void fe_log(const char *fmt, ...)
{
   va_list ap;
   pthread_mutex_lock(&s_log_lock);
   va_start(ap, fmt);
   vfprintf(stderr, fmt, ap);
   va_end(ap);
   if (s_log) {
      va_start(ap, fmt);
      vfprintf(s_log, fmt, ap);
      va_end(ap);
      fflush(s_log);
   }
   pthread_mutex_unlock(&s_log_lock);
}

static void core_log(enum retro_log_level level, const char *fmt, ...)
{
   static const char *const names[] = { "debug", "info", "warn", "error" };
   char line[1024];
   va_list ap;
   if (level == RETRO_LOG_DEBUG) return;
   va_start(ap, fmt);
   vsnprintf(line, sizeof(line), fmt, ap);
   va_end(ap);
   fe_log("[vice %s] %s", names[level < 4 ? level : 3], line);
   if (!strchr(line, '\n')) fe_log("\n");
}

void fe_setup(const char *system_dir, const char *save_dir, const char *log_path)
{
   snprintf(s_system_dir, sizeof(s_system_dir), "%s", system_dir);
   snprintf(s_save_dir, sizeof(s_save_dir), "%s", save_dir);
   if (log_path && !s_log) s_log = fopen(log_path, "w");
}

const char *fe_last_error(void) { return s_error; }

/* ------------------------------------------------------------------ */
/* Core options: VICE declares them (with defaults); we answer queries. */
#define MAX_OPTS 600
static struct { char *key; char *value; } s_opts[MAX_OPTS];
static int s_nopts;
static bool s_opts_dirty;

static void opt_set(const char *key, const char *value)
{
   int i;
   if (!key || !value) return;
   for (i = 0; i < s_nopts; i++)
      if (!strcmp(s_opts[i].key, key)) {
         free(s_opts[i].value);
         s_opts[i].value = strdup(value);
         return;
      }
   if (s_nopts < MAX_OPTS) {
      s_opts[s_nopts].key = strdup(key);
      s_opts[s_nopts].value = strdup(value);
      s_nopts++;
   }
}

static const char *opt_get(const char *key)
{
   int i;
   size_t j;
   for (j = 0; j < sizeof(k_overrides) / sizeof(k_overrides[0]); j++)
      if (!strcmp(k_overrides[j][0], key)) return k_overrides[j][1];
   for (i = 0; i < s_nopts; i++)
      if (!strcmp(s_opts[i].key, key)) return s_opts[i].value;
   return NULL;
}

static void opts_from_v2(const struct retro_core_options_v2 *o)
{
   const struct retro_core_option_v2_definition *d;
   if (!o || !o->definitions) return;
   for (d = o->definitions; d->key; d++)
      opt_set(d->key, d->default_value ? d->default_value : d->values[0].value);
}

static void opts_from_v1(const struct retro_core_option_definition *d)
{
   if (!d) return;
   for (; d->key; d++)
      opt_set(d->key, d->default_value ? d->default_value : d->values[0].value);
}

static void opts_from_v0(const struct retro_variable *v)
{
   /* "Description; first|second|third": the first is the default. */
   if (!v) return;
   for (; v->key; v++) {
      const char *p = v->value ? strstr(v->value, "; ") : NULL;
      char first[256];
      size_t n;
      if (!p) continue;
      p += 2;
      n = strcspn(p, "|");
      if (n >= sizeof(first)) n = sizeof(first) - 1;
      memcpy(first, p, n);
      first[n] = 0;
      opt_set(v->key, first);
   }
}

/* ------------------------------------------------------------------ */
/* Video */
static pthread_mutex_t s_video_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t s_frame[FE_MAX_W * FE_MAX_H];
static unsigned s_fw, s_fh;
static uint64_t s_fseq;
static enum retro_pixel_format s_pixfmt = RETRO_PIXEL_FORMAT_0RGB1555;
static struct retro_system_av_info s_av;

static void video_refresh(const void *data, unsigned w, unsigned h, size_t pitch)
{
   unsigned y, x;
   if (!data || data == RETRO_HW_FRAME_BUFFER_VALID) return;
   if (w > FE_MAX_W) w = FE_MAX_W;
   if (h > FE_MAX_H) h = FE_MAX_H;
   pthread_mutex_lock(&s_video_lock);
   for (y = 0; y < h; y++) {
      const uint8_t *row = (const uint8_t *)data + y * pitch;
      uint32_t *out = s_frame + y * w;
      if (s_pixfmt == RETRO_PIXEL_FORMAT_XRGB8888) {
         memcpy(out, row, w * 4);
      } else if (s_pixfmt == RETRO_PIXEL_FORMAT_RGB565) {
         const uint16_t *in = (const uint16_t *)row;
         for (x = 0; x < w; x++) {
            uint32_t p = in[x];
            uint32_t r = (p >> 11) & 31, g = (p >> 5) & 63, b = p & 31;
            out[x] = ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2);
         }
      } else {
         const uint16_t *in = (const uint16_t *)row;
         for (x = 0; x < w; x++) {
            uint32_t p = in[x];
            uint32_t r = (p >> 10) & 31, g = (p >> 5) & 31, b = p & 31;
            out[x] = ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2);
         }
      }
   }
   s_fw = w;
   s_fh = h;
   s_fseq++;
   pthread_mutex_unlock(&s_video_lock);
}

bool fe_copy_frame(uint32_t *dst, unsigned *w, unsigned *h, uint64_t *seq)
{
   bool copied = false;
   pthread_mutex_lock(&s_video_lock);
   if (s_fseq != *seq && s_fw && s_fh) {
      memcpy(dst, s_frame, (size_t)s_fw * s_fh * 4);
      *w = s_fw;
      *h = s_fh;
      *seq = s_fseq;
      copied = true;
   }
   pthread_mutex_unlock(&s_video_lock);
   return copied;
}

double fe_fps(void) { return s_av.timing.fps > 1 ? s_av.timing.fps : 50.0; }
double fe_sample_rate(void) { return s_av.timing.sample_rate > 1000 ? s_av.timing.sample_rate : 48000.0; }

float fe_aspect(void)
{
   if (s_av.geometry.aspect_ratio > 0.1f) return s_av.geometry.aspect_ratio;
   if (s_av.geometry.base_height) return (float)s_av.geometry.base_width / s_av.geometry.base_height;
   return 4.0f / 3.0f;
}

/* ------------------------------------------------------------------ */
/* Sound: a ring of stereo frames. */
#define RING_FRAMES 16384
static int16_t s_ring[RING_FRAMES * 2];
static size_t s_rhead, s_rtail;   /* in frames; head = write */
static pthread_mutex_t s_audio_lock = PTHREAD_MUTEX_INITIALIZER;
static bool s_ff;                  /* fast-forward (warp) requested by the core */

static size_t audio_batch(const int16_t *data, size_t frames)
{
   size_t i;
   if (s_ff) return frames;        /* warp: no sound, as on a real VICE */
   pthread_mutex_lock(&s_audio_lock);
   for (i = 0; i < frames; i++) {
      size_t next = (s_rhead + 1) % RING_FRAMES;
      if (next == s_rtail) break;  /* full: drop the rest */
      s_ring[s_rhead * 2] = data[i * 2];
      s_ring[s_rhead * 2 + 1] = data[i * 2 + 1];
      s_rhead = next;
   }
   pthread_mutex_unlock(&s_audio_lock);
   return frames;
}

static void audio_sample(int16_t l, int16_t r)
{
   int16_t f[2] = { l, r };
   audio_batch(f, 1);
}

size_t fe_audio_read(int16_t *out, size_t frames)
{
   size_t n = 0;
   pthread_mutex_lock(&s_audio_lock);
   while (n < frames && s_rtail != s_rhead) {
      out[n * 2] = s_ring[s_rtail * 2];
      out[n * 2 + 1] = s_ring[s_rtail * 2 + 1];
      s_rtail = (s_rtail + 1) % RING_FRAMES;
      n++;
   }
   pthread_mutex_unlock(&s_audio_lock);
   if (n < frames) memset(out + n * 2, 0, (frames - n) * 4);
   return n;
}

size_t fe_audio_buffered(void)
{
   size_t n;
   pthread_mutex_lock(&s_audio_lock);
   n = (s_rhead + RING_FRAMES - s_rtail) % RING_FRAMES;
   pthread_mutex_unlock(&s_audio_lock);
   return n;
}

bool fe_fast_forward(void) { return s_ff; }

/* ------------------------------------------------------------------ */
/* Input */
static pthread_mutex_t s_input_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t s_joy_now[2], s_joy_new[2];   /* held now; pressed since last frame */
static uint32_t s_joy_active[2];              /* what the core sees (emu thread) */
static uint64_t s_joy_start[2][16];
static uint64_t s_frame_no;

#define KEYQ 256
static struct { unsigned code; bool down; } s_keyq[KEYQ];
static unsigned s_kq_head, s_kq_tail;
static bool s_key_state[RETROK_LAST];
static uint64_t s_key_down_frame[RETROK_LAST];
static retro_keyboard_event_t s_keyboard_cb;

void fe_set_joy(int player, uint32_t bits)
{
   if (player < 0 || player > 1) return;
   pthread_mutex_lock(&s_input_lock);
   s_joy_new[player] |= bits & ~s_joy_now[player];
   s_joy_now[player] = bits;
   pthread_mutex_unlock(&s_input_lock);
}

void fe_key(unsigned retrok, bool down)
{
   if (retrok == 0 || retrok >= RETROK_LAST) return;
   pthread_mutex_lock(&s_input_lock);
   if ((s_kq_head + 1) % KEYQ != s_kq_tail) {
      s_keyq[s_kq_head].code = retrok;
      s_keyq[s_kq_head].down = down;
      s_kq_head = (s_kq_head + 1) % KEYQ;
   }
   pthread_mutex_unlock(&s_input_lock);
}

/* Before each frame: settle what the core sees this frame. */
static void input_settle(void)
{
   int p, b;
   pthread_mutex_lock(&s_input_lock);
   for (p = 0; p < 2; p++) {
      uint32_t held = s_joy_now[p] | s_joy_new[p];
      s_joy_new[p] = 0;
      for (b = 0; b < 16; b++) {
         uint32_t m = 1u << b;
         if (held & m) {
            if (!(s_joy_active[p] & m)) {
               s_joy_active[p] |= m;
               s_joy_start[p][b] = s_frame_no;
            }
         } else if ((s_joy_active[p] & m) && s_frame_no - s_joy_start[p][b] >= FE_MIN_HOLD_FRAMES) {
            s_joy_active[p] &= ~m;
         }
      }
   }
   /* Keys in order; a release waits until its key has been down long enough. */
   while (s_kq_tail != s_kq_head) {
      unsigned code = s_keyq[s_kq_tail].code;
      bool down = s_keyq[s_kq_tail].down;
      if (!down && s_key_state[code] && s_frame_no - s_key_down_frame[code] < FE_MIN_HOLD_FRAMES)
         break;
      s_kq_tail = (s_kq_tail + 1) % KEYQ;
      if (s_key_state[code] == down) continue;
      s_key_state[code] = down;
      if (down) s_key_down_frame[code] = s_frame_no;
      pthread_mutex_unlock(&s_input_lock);
      if (s_keyboard_cb) s_keyboard_cb(down, code, 0, 0);
      pthread_mutex_lock(&s_input_lock);
   }
   pthread_mutex_unlock(&s_input_lock);
}

static void input_poll(void) { }

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
   (void)index;
   if (device == RETRO_DEVICE_KEYBOARD)
      return (id < RETROK_LAST && s_key_state[id]) ? 1 : 0;
   if ((device & RETRO_DEVICE_MASK) != RETRO_DEVICE_JOYPAD || port > 1) return 0;
   if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)s_joy_active[port];
   return (id < 16 && (s_joy_active[port] & (1u << id))) ? 1 : 0;
}

/* ------------------------------------------------------------------ */
/* Environment */
static retro_time_t perf_time_usec(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return (retro_time_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static bool environment(unsigned cmd, void *data)
{
   switch (cmd) {
   case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
      ((struct retro_log_callback *)data)->log = core_log;
      return true;
   case RETRO_ENVIRONMENT_GET_PERF_INTERFACE: {
      struct retro_perf_callback *p = data;
      memset(p, 0, sizeof(*p));
      p->get_time_usec = perf_time_usec;
      return true;
   }
   case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
      *(const char **)data = s_system_dir;
      return true;
   case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
      *(const char **)data = s_save_dir;
      return true;
   case RETRO_ENVIRONMENT_GET_CONTENT_DIRECTORY:
      return false;
   case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      enum retro_pixel_format f = *(const enum retro_pixel_format *)data;
      if (f > RETRO_PIXEL_FORMAT_RGB565) return false;
      s_pixfmt = f;
      return true;
   }
   case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
      *(unsigned *)data = 2;
      return true;
   case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
      opts_from_v2(data);
      return true;
   case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
      opts_from_v2(((const struct retro_core_options_v2_intl *)data)->us);
      return true;
   case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
      opts_from_v1(data);
      return true;
   case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
      opts_from_v1(((const struct retro_core_options_intl *)data)->us);
      return true;
   case RETRO_ENVIRONMENT_SET_VARIABLES:
      opts_from_v0(data);
      return true;
   case RETRO_ENVIRONMENT_GET_VARIABLE: {
      struct retro_variable *v = data;
      v->value = v->key ? opt_get(v->key) : NULL;
      return v->value != NULL;
   }
   case RETRO_ENVIRONMENT_SET_VARIABLE: {
      const struct retro_variable *v = data;
      if (!v) return true;              /* "is this supported?" */
      opt_set(v->key, v->value);
      return true;
   }
   case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
      *(bool *)data = s_opts_dirty;
      s_opts_dirty = false;
      return true;
   case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
   case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
   case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
   case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
   case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
   case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
   case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
   case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
   case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE:
      return true;
   case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
      *(unsigned *)data = 1;
      return true;
   case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
      return true;
   case RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK:
      s_keyboard_cb = ((const struct retro_keyboard_callback *)data)->callback;
      return true;
   case RETRO_ENVIRONMENT_SET_FASTFORWARDING_OVERRIDE: {
      const struct retro_fastforwarding_override *o = data;
      if (!o) return true;
      s_ff = o->fastforward;
      return true;
   }
   case RETRO_ENVIRONMENT_GET_FASTFORWARDING:
      *(bool *)data = s_ff;
      return true;
   case RETRO_ENVIRONMENT_SET_GEOMETRY:
      s_av.geometry = *(const struct retro_game_geometry *)data;
      return true;
   case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
      s_av = *(const struct retro_system_av_info *)data;
      return true;
   case RETRO_ENVIRONMENT_SET_MESSAGE: {
      const struct retro_message *m = data;
      if (m && m->msg) fe_log("[vice message] %s\n", m->msg);
      return true;
   }
   case RETRO_ENVIRONMENT_SHUTDOWN:
      fe_log("core asked to shut down\n");
      return true;
   default:
      return false;
   }
}

/* ------------------------------------------------------------------ */
static bool s_started;

bool fe_start(const char *game_path)
{
   struct retro_system_info si;
   struct retro_game_info gi;
   void *buf = NULL;

   if (s_started) return true;
   retro_set_environment(environment);
   retro_set_video_refresh(video_refresh);
   retro_set_audio_sample(audio_sample);
   retro_set_audio_sample_batch(audio_batch);
   retro_set_input_poll(input_poll);
   retro_set_input_state(input_state);
   retro_init();

   memset(&si, 0, sizeof(si));
   retro_get_system_info(&si);
   fe_log("core %s %s, loading %s\n", si.library_name, si.library_version, game_path);

   memset(&gi, 0, sizeof(gi));
   gi.path = game_path;
   if (!si.need_fullpath) {
      FILE *f = fopen(game_path, "rb");
      long n;
      if (!f) { snprintf(s_error, sizeof(s_error), "Could not open the game file."); return false; }
      fseek(f, 0, SEEK_END);
      n = ftell(f);
      fseek(f, 0, SEEK_SET);
      buf = malloc(n > 0 ? (size_t)n : 1);
      if (fread(buf, 1, (size_t)n, f) != (size_t)n) n = 0;
      fclose(f);
      gi.data = buf;
      gi.size = (size_t)n;
   }
   if (!retro_load_game(&gi)) {
      snprintf(s_error, sizeof(s_error), "The C64 could not load this file.");
      free(buf);
      return false;
   }
   retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
   retro_set_controller_port_device(1, RETRO_DEVICE_JOYPAD);
   retro_get_system_av_info(&s_av);
   fe_log("video %ux%u aspect %.3f, %.3f fps, sound %.0f Hz\n",
          s_av.geometry.base_width, s_av.geometry.base_height,
          s_av.geometry.aspect_ratio, s_av.timing.fps, s_av.timing.sample_rate);
   s_started = true;
   return true;
}

void fe_run_frame(void)
{
   if (!s_started) return;
   input_settle();
   retro_run();
   s_frame_no++;
}

void fe_reset(void)
{
   if (s_started) retro_reset();
}
