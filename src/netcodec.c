/* C64 wif Friends: packets between the phones. See netcodec.h. */
#include "netcodec.h"

#include <string.h>

static void put16(uint8_t *p, unsigned v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; }
static void put32(uint8_t *p, uint32_t v) { put16(p, v & 0xffff); put16(p + 2, v >> 16); }
static unsigned get16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static uint32_t get32(const uint8_t *p) { return get16(p) | ((uint32_t)get16(p + 2) << 16); }

static void header(uint8_t *p, int type) { p[0] = 'C'; p[1] = '6'; p[2] = (uint8_t)type; }

int nc_type(const uint8_t *p, size_t len)
{
   if (len < NC_HEADER || p[0] != 'C' || p[1] != '6') return 0;
   return p[2];
}

bool nc_newer(uint16_t a, uint16_t b) { return (int16_t)(a - b) > 0; }

/* ---- Pictures ---- */

#define FRAME_HEAD 8

size_t nc_pack_bound(unsigned w, unsigned h) { return FRAME_HEAD + 256 * 3 + (size_t)w * h; }

size_t nc_pack_frame(const uint32_t *px, unsigned w, unsigned h, float aspect,
                     uint8_t *out, size_t cap)
{
   uint32_t pal[256];
   unsigned n = 0, last = 0, bits, i;
   size_t npx = (size_t)w * h, need, k;
   uint8_t *dst;

   if (!w || !h || w > 0xffff || h > 0xffff) return 0;
   /* First pass: the colours. */
   for (k = 0; k < npx; k++) {
      uint32_t c = px[k] & 0xffffff;
      if (n && pal[last] == c) continue;
      for (i = 0; i < n && pal[i] != c; i++) { }
      if (i == n) {
         if (n == 256) return 0;
         pal[n++] = c;
      }
      last = i;
   }
   bits = n <= 16 ? 4 : 8;
   need = FRAME_HEAD + n * 3 + (bits == 4 ? (npx + 1) / 2 : npx);
   if (need > cap) return 0;

   put16(out, w);
   put16(out + 2, h);
   put16(out + 4, (unsigned)(aspect * 1000.0f + 0.5f));
   out[6] = (uint8_t)(n - 1);           /* 1..256 colours */
   out[7] = (uint8_t)bits;
   for (i = 0; i < n; i++) {
      out[FRAME_HEAD + i * 3]     = (pal[i] >> 16) & 0xff;
      out[FRAME_HEAD + i * 3 + 1] = (pal[i] >> 8) & 0xff;
      out[FRAME_HEAD + i * 3 + 2] = pal[i] & 0xff;
   }
   dst = out + FRAME_HEAD + n * 3;
   /* Second pass: the pixels as palette numbers. */
   last = 0;
   for (k = 0; k < npx; k++) {
      uint32_t c = px[k] & 0xffffff;
      if (pal[last] != c)
         for (last = 0; pal[last] != c; last++) { }
      if (bits == 8) dst[k] = (uint8_t)last;
      else if (k & 1) dst[k >> 1] |= (uint8_t)(last << 4);
      else dst[k >> 1] = (uint8_t)last;
   }
   return need;
}

bool nc_unpack_frame(const uint8_t *in, size_t len, uint32_t *dst, size_t max_px,
                     unsigned *w, unsigned *h, float *aspect)
{
   uint32_t pal[256];
   unsigned n, bits, i;
   size_t npx, k;
   const uint8_t *src;

   if (len < FRAME_HEAD) return false;
   *w = get16(in);
   *h = get16(in + 2);
   *aspect = get16(in + 4) / 1000.0f;
   n = in[6] + 1u;
   bits = in[7];
   npx = (size_t)*w * *h;
   if (!npx || npx > max_px || (bits != 4 && bits != 8) || (bits == 4 && n > 16)) return false;
   if (len < FRAME_HEAD + n * 3 + (bits == 4 ? (npx + 1) / 2 : npx)) return false;
   for (i = 0; i < n; i++)
      pal[i] = 0xff000000u | (uint32_t)in[FRAME_HEAD + i * 3] << 16
             | (uint32_t)in[FRAME_HEAD + i * 3 + 1] << 8 | in[FRAME_HEAD + i * 3 + 2];
   for (; i < 256; i++) pal[i] = 0xff000000u;
   src = in + FRAME_HEAD + n * 3;
   for (k = 0; k < npx; k++) {
      unsigned idx = bits == 8 ? src[k] : ((k & 1) ? src[k >> 1] >> 4 : src[k >> 1] & 15);
      dst[k] = pal[idx];
   }
   return true;
}

/* ---- Chunks ---- */

#define VHEAD (NC_HEADER + 4)

unsigned nc_chunk_count(size_t msg_len) { return (unsigned)((msg_len + NC_CHUNK - 1) / NC_CHUNK); }

size_t nc_video_packet(uint16_t frame, const uint8_t *msg, size_t msg_len, unsigned index,
                       uint8_t *out, size_t cap)
{
   unsigned count = nc_chunk_count(msg_len);
   size_t off = (size_t)index * NC_CHUNK, n;
   if (index >= count || count > 256 || cap < VHEAD + NC_CHUNK) return 0;
   n = msg_len - off < NC_CHUNK ? msg_len - off : NC_CHUNK;
   header(out, NC_VIDEO);
   put16(out + 3, frame);
   out[5] = (uint8_t)index;
   out[6] = (uint8_t)(count - 1);
   memcpy(out + VHEAD, msg + off, n);
   return VHEAD + n;
}

void nc_reasm_init(nc_reasm *r) { r->active = false; }

size_t nc_reasm_add(nc_reasm *r, const uint8_t *p, size_t len, const uint8_t **msg)
{
   uint16_t frame;
   unsigned index, count;
   size_t n, off;
   if (nc_type(p, len) != NC_VIDEO || len < VHEAD) return 0;
   frame = (uint16_t)get16(p + 3);
   index = p[5];
   count = p[6] + 1u;
   n = len - VHEAD;
   if (index >= count || n > NC_CHUNK || (index + 1 < count && n != NC_CHUNK)) return 0;
   if (r->active && frame != r->frame && !nc_newer(frame, r->frame)) return 0;   /* stale */
   if (!r->active || frame != r->frame) {
      r->active = true;
      r->frame = frame;
      r->count = count;
      r->have = 0;
      r->len = 0;
      memset(r->got, 0, sizeof(r->got));
   }
   if (count != r->count || r->got[index]) return 0;
   off = (size_t)index * NC_CHUNK;
   memcpy(r->buf + off, p + VHEAD, n);
   r->got[index] = 1;
   r->have++;
   if (index + 1 == count) r->len = off + n;
   if (r->have < r->count) return 0;
   r->have = r->count + 1;   /* done: late repeats of this picture are ignored */
   *msg = r->buf;
   return r->len;
}

/* ---- Input ---- */

size_t nc_input_packet(uint16_t seq, uint8_t joy, const uint16_t *keys, unsigned nkeys,
                       uint8_t *out, size_t cap)
{
   unsigned i;
   if (nkeys > NC_MAX_KEYS) nkeys = NC_MAX_KEYS;
   if (cap < NC_HEADER + 4 + 2 * nkeys) return 0;
   header(out, NC_INPUT);
   put16(out + 3, seq);
   out[5] = joy;
   out[6] = (uint8_t)nkeys;
   for (i = 0; i < nkeys; i++) put16(out + 7 + 2 * i, keys[i]);
   return NC_HEADER + 4 + 2 * nkeys;
}

bool nc_input_parse(const uint8_t *p, size_t len, uint16_t *seq, uint8_t *joy,
                    uint16_t *keys, unsigned *nkeys)
{
   unsigned i, n;
   if (nc_type(p, len) != NC_INPUT || len < NC_HEADER + 4) return false;
   n = p[6];
   if (n > NC_MAX_KEYS || len < NC_HEADER + 4 + 2 * n) return false;
   *seq = (uint16_t)get16(p + 3);
   *joy = p[5];
   for (i = 0; i < n; i++) keys[i] = (uint16_t)get16(p + 7 + 2 * i);
   *nkeys = n;
   return true;
}

/* ---- Sound ---- */

size_t nc_audio_packet(uint16_t seq, uint32_t rate, const int16_t *mono, unsigned n,
                       uint8_t *out, size_t cap)
{
   unsigned i;
   if (n > NC_MAX_AUDIO) n = NC_MAX_AUDIO;
   if (cap < NC_HEADER + 8 + 2 * (size_t)n) return 0;
   header(out, NC_AUDIO);
   put16(out + 3, seq);
   put32(out + 5, rate);
   put16(out + 9, n);
   for (i = 0; i < n; i++) put16(out + 11 + 2 * i, (uint16_t)mono[i]);
   return NC_HEADER + 8 + 2 * (size_t)n;
}

bool nc_audio_parse(const uint8_t *p, size_t len, uint16_t *seq, uint32_t *rate,
                    const uint8_t **samples, unsigned *n)
{
   if (nc_type(p, len) != NC_AUDIO || len < NC_HEADER + 8) return false;
   *seq = (uint16_t)get16(p + 3);
   *rate = get32(p + 5);
   *n = get16(p + 9);
   if (*n > NC_MAX_AUDIO || len < NC_HEADER + 8 + 2 * (size_t)*n || *rate < 8000 || *rate > 192000) return false;
   *samples = p + 11;
   return true;
}
