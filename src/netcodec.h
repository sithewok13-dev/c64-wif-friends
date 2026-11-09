/* C64 wif Friends: what the two phones send each other over WiFi.
 *
 * Plain C (no networking here), so it can be tested anywhere.
 *
 * Every packet starts with 'C', '6' and a type byte. All numbers are
 * little-endian.
 *
 *   Guest -> host, many times a second (UDP, so any one may be lost):
 *     'I' u16 seq, u8 joystick bits (FE_JOY_*), u8 n, n x u16 held keys
 *         The whole input state every time, so a lost packet costs nothing.
 *
 *   Host -> guest:
 *     'V' u16 frame, u8 chunk index, u8 chunk count, chunk bytes
 *         One picture, cut into chunks of NC_CHUNK bytes. A picture is
 *         [u8 compressed?][u32 packed size][packed or compressed bytes];
 *         a packed picture is nc_pack_frame()'s output.
 *     'A' u16 seq, u32 sample rate, u16 n, n x i16 mono samples
 *     'B' bye (either way): the other side is leaving.
 */
#ifndef C64WIF_NETCODEC_H
#define C64WIF_NETCODEC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define NC_SERVICE "_c64wif._udp"
#define NC_CHUNK 1100            /* bytes of picture per packet: no IP fragments */
#define NC_HEADER 3
#define NC_MAX_KEYS 16
#define NC_MAX_AUDIO 600         /* samples per audio packet */

enum { NC_INPUT = 'I', NC_VIDEO = 'V', NC_AUDIO = 'A', NC_BYE = 'B' };

/* The packet type, or 0 if it isn't one of ours. */
int nc_type(const uint8_t *p, size_t len);

/* ---- Pictures ---- */

/* Packs an XRGB8888 picture as a palette plus 4-bit (up to 16 colours,
 * which is every C64 picture) or 8-bit pixels:
 *   u16 w, u16 h, u16 aspect*1000, u8 colours, u8 bits, colours x RGB, pixels
 * Returns the size, or 0 if it doesn't fit or has over 256 colours. */
size_t nc_pack_frame(const uint32_t *px, unsigned w, unsigned h, float aspect,
                     uint8_t *out, size_t cap);
/* The other way. dst must hold w*h pixels (at most max_px). */
bool nc_unpack_frame(const uint8_t *in, size_t len, uint32_t *dst, size_t max_px,
                     unsigned *w, unsigned *h, float *aspect);
/* Worst-case packed size for a w x h picture. */
size_t nc_pack_bound(unsigned w, unsigned h);

/* Cutting a picture into packets. Writes packet `index` of `msg` into out
 * (cap >= NC_HEADER + 4 + NC_CHUNK) and returns its size. */
unsigned nc_chunk_count(size_t msg_len);
size_t nc_video_packet(uint16_t frame, const uint8_t *msg, size_t msg_len, unsigned index,
                       uint8_t *out, size_t cap);

/* Putting it back together. Newer pictures replace older unfinished ones. */
#define NC_MAX_MSG (256 * NC_CHUNK)
typedef struct {
   bool active;
   uint16_t frame;
   unsigned count, have;
   size_t len;
   uint8_t got[256];
   uint8_t buf[NC_MAX_MSG];
} nc_reasm;
void nc_reasm_init(nc_reasm *r);
/* Feeds one 'V' packet. Returns the finished picture's length (and points
 * *msg at it) when this packet completes one, else 0. */
size_t nc_reasm_add(nc_reasm *r, const uint8_t *p, size_t len, const uint8_t **msg);

/* ---- Input ---- */
size_t nc_input_packet(uint16_t seq, uint8_t joy, const uint16_t *keys, unsigned nkeys,
                       uint8_t *out, size_t cap);
bool nc_input_parse(const uint8_t *p, size_t len, uint16_t *seq, uint8_t *joy,
                    uint16_t *keys, unsigned *nkeys);

/* ---- Sound ---- */
size_t nc_audio_packet(uint16_t seq, uint32_t rate, const int16_t *mono, unsigned n,
                       uint8_t *out, size_t cap);
bool nc_audio_parse(const uint8_t *p, size_t len, uint16_t *seq, uint32_t *rate,
                    const uint8_t **samples, unsigned *n);

/* True if sequence number a is newer than b (with wrap-around). */
bool nc_newer(uint16_t a, uint16_t b);

#endif
