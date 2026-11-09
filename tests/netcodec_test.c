/* Tests for src/netcodec.c. Run: cc -I src tests/netcodec_test.c src/netcodec.c && ./a.out */
#include "netcodec.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static uint32_t c64[16] = { 0x000000, 0xffffff, 0x68372b, 0x70a4b2, 0x6f3d86, 0x588d43, 0x352879, 0xb8c76f,
                            0x6f4f25, 0x433900, 0x9a6759, 0x444444, 0x6c6c6c, 0x9ad284, 0x6c5eb5, 0x959595 };

static void shuffle(int *order, int n) {
   for (int i = n - 1; i > 0; i--) { int j = rand() % (i + 1), t = order[i]; order[i] = order[j]; order[j] = t; }
}

int main(void) {
   static uint32_t px[384 * 272], back[512 * 320];
   static uint8_t packed[400000], pkt[2000];
   unsigned w, h; float a;
   srand(7);
   /* 1. A C64 picture (16 colours, odd width) round-trips in 4 bits. */
   for (int i = 0; i < 321 * 201; i++) px[i] = 0xff000000u | c64[(i / 7 + i % 13) % 16];
   size_t n = nc_pack_frame(px, 321, 201, 1.512f, packed, sizeof(packed));
   CHECK(n > 0 && n < 321 * 201 / 2 + 100);
   CHECK(nc_unpack_frame(packed, n, back, 512 * 320, &w, &h, &a));
   CHECK(w == 321 && h == 201 && a > 1.511f && a < 1.513f);
   CHECK(memcmp(px, back, 321 * 201 * 4) == 0);
   /* 2. 200 colours: 8 bits. 300 colours: refused. */
   for (int i = 0; i < 384 * 272; i++) px[i] = 0xff000000u | (i % 200) * 997;
   n = nc_pack_frame(px, 384, 272, 1.333f, packed, sizeof(packed));
   CHECK(n == 8 + 200 * 3 + 384 * 272);
   CHECK(nc_unpack_frame(packed, n, back, 512 * 320, &w, &h, &a) && memcmp(px, back, 384 * 272 * 4) == 0);
   for (int i = 0; i < 384 * 272; i++) px[i] = (i % 300) * 997;
   CHECK(nc_pack_frame(px, 384, 272, 1.333f, packed, sizeof(packed)) == 0);
   /* 3. Truncated or too-big input is refused. */
   for (int i = 0; i < 320 * 200; i++) px[i] = c64[i % 16];
   n = nc_pack_frame(px, 320, 200, 1.6f, packed, sizeof(packed));
   CHECK(!nc_unpack_frame(packed, n - 1, back, 512 * 320, &w, &h, &a));
   CHECK(!nc_unpack_frame(packed, n, back, 100, &w, &h, &a));
   CHECK(nc_pack_frame(px, 320, 200, 1.6f, packed, 100) == 0);
   /* 4. Chunks arrive shuffled, with duplicates and an older picture's chunks mixed in. */
   static nc_reasm r; nc_reasm_init(&r);
   const uint8_t *msg; size_t got = 0; int completions = 0;
   unsigned count = nc_chunk_count(n);
   int order[256]; for (unsigned i = 0; i < count; i++) order[i] = i;
   shuffle(order, count);
   size_t old = nc_video_packet(41, packed, n, 0, pkt, sizeof(pkt));
   CHECK(old > 0);
   for (unsigned i = 0; i < count; i++) {
      size_t m = nc_video_packet(42, packed, n, order[i], pkt, sizeof(pkt));
      CHECK(m > 0 && m <= NC_HEADER + 4 + NC_CHUNK);
      size_t k = nc_reasm_add(&r, pkt, m, &msg);
      if (k) { got = k; completions++; }
      if (i == 2) { nc_reasm_add(&r, pkt, m, &msg); }            /* duplicate */
      if (i == 3) { nc_video_packet(41, packed, n, 0, pkt, sizeof(pkt)); CHECK(nc_reasm_add(&r, pkt, old, &msg) == 0); }
   }
   CHECK(completions == 1 && got == n && memcmp(msg, packed, n) == 0);
   /* A late repeat of the finished picture doesn't complete it again. */
   size_t m = nc_video_packet(42, packed, n, 0, pkt, sizeof(pkt));
   CHECK(nc_reasm_add(&r, pkt, m, &msg) == 0);
   /* A lost chunk: that picture never completes, the next one does. */
   for (unsigned i = 1; i < count; i++) { m = nc_video_packet(43, packed, n, i, pkt, sizeof(pkt)); CHECK(nc_reasm_add(&r, pkt, m, &msg) == 0); }
   completions = 0;
   for (unsigned i = 0; i < count; i++) { m = nc_video_packet(44, packed, n, i, pkt, sizeof(pkt)); if (nc_reasm_add(&r, pkt, m, &msg)) completions++; }
   CHECK(completions == 1);
   /* Wrap-around of the picture number. */
   CHECK(nc_newer(2, 65535) && !nc_newer(65535, 2));
   /* 5. Input and sound. */
   uint16_t keys[3] = { 13, 32, 282 }, k2[NC_MAX_KEYS], seq; uint8_t joy; unsigned nk;
   m = nc_input_packet(9, 0x91, keys, 3, pkt, sizeof(pkt));
   CHECK(nc_input_parse(pkt, m, &seq, &joy, k2, &nk) && seq == 9 && joy == 0x91 && nk == 3 && k2[2] == 282);
   CHECK(!nc_input_parse(pkt, m - 1, &seq, &joy, k2, &nk));
   int16_t mono[NC_MAX_AUDIO]; for (int i = 0; i < NC_MAX_AUDIO; i++) mono[i] = (int16_t)(i * 50 - 15000);
   m = nc_audio_packet(5, 48000, mono, NC_MAX_AUDIO, pkt, sizeof(pkt));
   uint32_t rate; const uint8_t *s; unsigned ns;
   CHECK(m > 0 && m < 1300 && nc_audio_parse(pkt, m, &seq, &rate, &s, &ns) && rate == 48000 && ns == NC_MAX_AUDIO);
   CHECK((int16_t)(s[2 * 10] | s[2 * 10 + 1] << 8) == mono[10]);
   CHECK(nc_type((const uint8_t *)"XYZ", 3) == 0);
   printf(fails ? "%d FAILED\n" : "all netcodec tests passed\n", fails);
   return fails != 0;
}
