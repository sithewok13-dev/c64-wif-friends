// C64 wif Friends: WiFi play. See Net.h.
#import "Net.h"
#include <compression.h>
#include <stdatomic.h>
#include "frontend.h"
#include "netcodec.h"

static const double kTimeout = 3.0;          // seconds of silence = gone
static const int kRepeatEvery = 10;          // resend an unchanged picture every N frames

static nw_parameters_t UdpParams(void) {
   nw_parameters_t p = nw_parameters_create_secure_udp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                       NW_PARAMETERS_DEFAULT_CONFIGURATION);
   nw_parameters_set_include_peer_to_peer(p, true);
   return p;
}

static void SendBytes(nw_connection_t c, const void *bytes, size_t len, dispatch_queue_t q) {
   if (!c || !len) return;
   dispatch_data_t d = dispatch_data_create(bytes, len, q, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
   nw_connection_send(c, d, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, NW_CONNECTION_SEND_IDEMPOTENT_CONTENT);
}

// Calls block with the bytes of a received message.
static void WithBytes(dispatch_data_t content, void (^block)(const uint8_t *p, size_t len)) {
   const void *buf = NULL;
   size_t len = 0;
   dispatch_data_t map = dispatch_data_create_map(content, &buf, &len);
   if (map && buf) block(buf, len);
   (void)map;   // keeps the bytes alive until here
}

static NSString *ProblemText(nw_error_t e) {
   if (!e) return @"";
   if (nw_error_get_error_domain(e) == nw_error_domain_dns)
      return @"Allow Local Network for C64 wif Friends in Settings > Privacy & Security > Local Network.";
   return [NSString stringWithFormat:@"WiFi problem (%d).", nw_error_get_error_code(e)];
}

#pragma mark - Host

@implementation NetHost {
   dispatch_queue_t _q;
   nw_listener_t _listener;
   nw_connection_t _guest;          // on _q
   CFAbsoluteTime _lastHeard;       // on _q
   uint16_t _lastSeq;
   BOOL _haveSeq;
   uint16_t _heldKeys[NC_MAX_KEYS];
   unsigned _nHeld;
   dispatch_source_t _timer;
   atomic_bool _sending;            // read on the emulator thread
   // Emulator thread only:
   uint32_t *_px;
   uint64_t _seq;
   uint8_t *_packed, *_prev, *_msg;
   size_t _prevLen;
   int _sinceSent;
   uint16_t _frameNo, _audioSeq;
   int16_t _mono[4096];
   size_t _nMono;
   NSString *_status;
}

static void HostAudioTap(const int16_t *stereo, size_t frames, void *user) {
   NetHost *h = (__bridge NetHost *)user;
   [h tapAudio:stereo frames:frames];
}

- (instancetype)initWithGameName:(NSString *)game {
   if ((self = [super init])) {
      static const char letters[] = "ABCDEFGHJKLMNPQRSTUVWXYZ";
      char code[5] = {0};
      for (int i = 0; i < 4; i++) code[i] = letters[arc4random_uniform(sizeof(letters) - 1)];
      _code = [NSString stringWithUTF8String:code];
      _q = dispatch_queue_create("c64wif.host", DISPATCH_QUEUE_SERIAL);
      _px = malloc(FE_MAX_W * FE_MAX_H * 4);
      size_t bound = nc_pack_bound(FE_MAX_W, FE_MAX_H);
      _packed = malloc(bound);
      _prev = malloc(bound);
      _msg = malloc(bound + 16);
      atomic_store(&_sending, false);
      _status = [NSString stringWithFormat:@"Player 2 can join: room %@", _code];
      fe_set_audio_tap(HostAudioTap, (__bridge void *)self);

      NSString *base = game.stringByDeletingPathExtension;
      if (base.length > 40) base = [base substringToIndex:40];
      NSString *service = [NSString stringWithFormat:@"%@ (%@)", base, _code];
      _listener = nw_listener_create(UdpParams());
      nw_listener_set_advertise_descriptor(_listener,
         nw_advertise_descriptor_create_bonjour_service(service.UTF8String, NC_SERVICE, NULL));
      nw_listener_set_queue(_listener, _q);
      __weak NetHost *ws = self;
      nw_listener_set_state_changed_handler(_listener, ^(nw_listener_state_t state, nw_error_t error) {
         if (state == nw_listener_state_failed) [ws setStatus:[@"Player 2 can't join. " stringByAppendingString:ProblemText(error)]];
      });
      nw_listener_set_new_connection_handler(_listener, ^(nw_connection_t c) { [ws accept:c]; });
      nw_listener_start(_listener);

      _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
      dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
      dispatch_source_set_event_handler(_timer, ^{ [ws checkGuest]; });
      dispatch_resume(_timer);
   }
   return self;
}

- (NSString *)statusText { return _status; }

- (void)setStatus:(NSString *)s {
   dispatch_async(dispatch_get_main_queue(), ^{
      if ([s isEqualToString:self->_status]) return;
      self->_status = s;
      if (self.onStatus) self.onStatus(s);
   });
}

// _q
- (void)accept:(nw_connection_t)c {
   if (_guest) {   // one player 2 at a time
      nw_connection_cancel(c);
      return;
   }
   _guest = c;
   _haveSeq = NO;
   _lastHeard = CFAbsoluteTimeGetCurrent();
   nw_connection_set_queue(c, _q);
   __weak NetHost *ws = self;
   nw_connection_set_state_changed_handler(c, ^(nw_connection_state_t state, nw_error_t error) {
      if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) [ws dropGuest:c];
   });
   nw_connection_start(c);
   [self receiveOn:c];
}

- (void)receiveOn:(nw_connection_t)c {
   __weak NetHost *ws = self;
   nw_connection_receive_message(c, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t error) {
      NetHost *s = ws;
      if (!s) return;
      if (content) WithBytes(content, ^(const uint8_t *p, size_t len) { [s handle:p len:len from:c]; });
      if (!error) [s receiveOn:c];
   });
}

// _q
- (void)handle:(const uint8_t *)p len:(size_t)len from:(nw_connection_t)c {
   if (c != _guest) return;
   int type = nc_type(p, len);
   if (type == NC_BYE) { [self dropGuest:c]; return; }
   uint16_t seq, keys[NC_MAX_KEYS];
   uint8_t joy;
   unsigned n;
   if (type != NC_INPUT || !nc_input_parse(p, len, &seq, &joy, keys, &n)) return;
   _lastHeard = CFAbsoluteTimeGetCurrent();
   if (!atomic_load(&_sending)) {
      atomic_store(&_sending, true);
      [self setStatus:[NSString stringWithFormat:@"Player 2 joined (room %@)", _code]];
   }
   if (_haveSeq && !nc_newer(seq, _lastSeq)) return;   // late packet
   _haveSeq = YES;
   _lastSeq = seq;
   fe_set_joy(1, joy);
   // Keys: press the new ones, let go of the ones no longer held.
   for (unsigned i = 0; i < _nHeld; i++) {
      BOOL still = NO;
      for (unsigned j = 0; j < n; j++) if (keys[j] == _heldKeys[i]) still = YES;
      if (!still) fe_key(_heldKeys[i], false);
   }
   for (unsigned j = 0; j < n; j++) {
      BOOL was = NO;
      for (unsigned i = 0; i < _nHeld; i++) if (keys[j] == _heldKeys[i]) was = YES;
      if (!was) fe_key(keys[j], true);
   }
   memcpy(_heldKeys, keys, n * sizeof(uint16_t));
   _nHeld = n;
}

// _q
- (void)checkGuest {
   if (_guest && CFAbsoluteTimeGetCurrent() - _lastHeard > kTimeout) [self dropGuest:_guest];
}

// _q
- (void)dropGuest:(nw_connection_t)c {
   if (!c || c != _guest) return;
   _guest = nil;
   nw_connection_cancel(c);
   atomic_store(&_sending, false);
   fe_set_joy(1, 0);
   for (unsigned i = 0; i < _nHeld; i++) fe_key(_heldKeys[i], false);
   _nHeld = 0;
   [self setStatus:[NSString stringWithFormat:@"Player 2 left. They can join again: room %@", _code]];
}

#pragma mark Host: sending (emulator thread)

- (void)tapAudio:(const int16_t *)stereo frames:(size_t)frames {
   if (!atomic_load(&_sending)) { _nMono = 0; return; }
   for (size_t i = 0; i < frames && _nMono < sizeof(_mono) / sizeof(_mono[0]); i++)
      _mono[_nMono++] = (int16_t)(((int)stereo[i * 2] + stereo[i * 2 + 1]) / 2);
}

- (void)afterFrame {
   if (!atomic_load(&_sending)) return;
   uint32_t rate = (uint32_t)(fe_sample_rate() + 0.5);
   // Sound first: it matters most that it never stops.
   for (size_t off = 0; off < _nMono; off += NC_MAX_AUDIO) {
      unsigned n = (unsigned)MIN((size_t)NC_MAX_AUDIO, _nMono - off);
      uint8_t pkt[NC_HEADER + 8 + 2 * NC_MAX_AUDIO];
      size_t len = nc_audio_packet(_audioSeq++, rate, _mono + off, n, pkt, sizeof(pkt));
      [self send:pkt len:len];
   }
   _nMono = 0;

   unsigned w, h;
   if (!fe_copy_frame(_px, &w, &h, &_seq)) return;
   size_t bound = nc_pack_bound(FE_MAX_W, FE_MAX_H);
   size_t packed = nc_pack_frame(_px, w, h, fe_aspect(), _packed, bound);
   if (!packed) return;
   // Unchanged pictures are only repeated now and then (in case one was lost).
   if (packed == _prevLen && !memcmp(_packed, _prev, packed) && ++_sinceSent < kRepeatEvery) return;
   _sinceSent = 0;
   memcpy(_prev, _packed, packed);
   _prevLen = packed;

   size_t comp = compression_encode_buffer(_msg + 5, bound, _packed, packed, NULL, COMPRESSION_LZ4);
   size_t msgLen;
   if (comp > 0 && comp < packed) {
      _msg[0] = 1;
      msgLen = 5 + comp;
   } else {
      _msg[0] = 0;
      memcpy(_msg + 5, _packed, packed);
      msgLen = 5 + packed;
   }
   _msg[1] = packed & 0xff; _msg[2] = (packed >> 8) & 0xff; _msg[3] = (packed >> 16) & 0xff; _msg[4] = (packed >> 24) & 0xff;
   unsigned count = nc_chunk_count(msgLen);
   if (count > 256) return;
   uint16_t frame = _frameNo++;
   for (unsigned i = 0; i < count; i++) {
      uint8_t pkt[NC_HEADER + 4 + NC_CHUNK];
      size_t len = nc_video_packet(frame, _msg, msgLen, i, pkt, sizeof(pkt));
      [self send:pkt len:len];
   }
}

- (void)send:(const uint8_t *)p len:(size_t)len {
   if (!len) return;
   dispatch_data_t d = dispatch_data_create(p, len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
   dispatch_async(_q, ^{
      if (self->_guest)
         nw_connection_send(self->_guest, d, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, NW_CONNECTION_SEND_IDEMPOTENT_CONTENT);
   });
}

- (void)stop {
   fe_set_audio_tap(NULL, NULL);
   dispatch_sync(_q, ^{
      if (self->_guest) {
         uint8_t bye[NC_HEADER] = { 'C', '6', NC_BYE };
         SendBytes(self->_guest, bye, sizeof(bye), self->_q);
         nw_connection_cancel(self->_guest);
         self->_guest = nil;
      }
      if (self->_listener) nw_listener_cancel(self->_listener);
      self->_listener = nil;
      if (self->_timer) dispatch_source_cancel(self->_timer);
      self->_timer = nil;
      atomic_store(&self->_sending, false);
   });
}

@end

#pragma mark - Browser

@implementation NetBrowser {
   dispatch_queue_t _q;
   nw_browser_t _browser;
   NSMutableDictionary<NSString *, nw_endpoint_t> *_found;   // on _q
   NSString *_problem;
}

- (instancetype)init {
   if ((self = [super init])) {
      _q = dispatch_queue_create("c64wif.browse", DISPATCH_QUEUE_SERIAL);
      _found = [NSMutableDictionary dictionary];
   }
   return self;
}

- (void)start {
   if (_browser) return;
   nw_parameters_t p = nw_parameters_create();
   nw_parameters_set_include_peer_to_peer(p, true);
   _browser = nw_browser_create(nw_browse_descriptor_create_bonjour_service(NC_SERVICE, NULL), p);
   nw_browser_set_queue(_browser, _q);
   __weak NetBrowser *ws = self;
   nw_browser_set_browse_results_changed_handler(_browser, ^(nw_browse_result_t old, nw_browse_result_t now, bool done) {
      [ws changedFrom:old to:now done:done];
   });
   nw_browser_set_state_changed_handler(_browser, ^(nw_browser_state_t state, nw_error_t error) {
      NetBrowser *s = ws;
      if (!s) return;
      if (state == nw_browser_state_failed || (state == nw_browser_state_waiting && error)) {
         s->_problem = ProblemText(error);
         [s publish];
      } else if (state == nw_browser_state_ready && s->_problem) {
         s->_problem = nil;
         [s publish];
      }
   });
   nw_browser_start(_browser);
}

static NSString *NameOf(nw_browse_result_t r) {
   if (!r) return nil;
   nw_endpoint_t e = nw_browse_result_copy_endpoint(r);
   const char *n = e ? nw_endpoint_get_bonjour_service_name(e) : NULL;
   return n ? [NSString stringWithUTF8String:n] : nil;
}

// _q
- (void)changedFrom:(nw_browse_result_t)old to:(nw_browse_result_t)now done:(bool)done {
   nw_browse_result_change_t ch = nw_browse_result_get_changes(old, now);
   if (ch & nw_browse_result_change_result_removed) {
      NSString *n = NameOf(old);
      if (n) [_found removeObjectForKey:n];
   }
   if (ch & nw_browse_result_change_result_added) {
      NSString *n = NameOf(now);
      if (n) _found[n] = nw_browse_result_copy_endpoint(now);
   }
   if (done) [self publish];
}

// _q
- (void)publish {
   NSArray *names = [_found.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
   NSString *problem = _problem;
   dispatch_async(dispatch_get_main_queue(), ^{ if (self.onChange) self.onChange(names, problem); });
}

- (nw_endpoint_t)endpointForName:(NSString *)name {
   __block nw_endpoint_t e = nil;
   dispatch_sync(_q, ^{ e = self->_found[name]; });
   return e;
}

- (void)stop {
   if (_browser) nw_browser_cancel(_browser);
   _browser = nil;
}

@end

#pragma mark - Guest

@implementation NetGuest {
   dispatch_queue_t _q;
   nw_connection_t _conn;
   dispatch_source_t _timer;
   nc_reasm *_reasm;
   uint8_t *_raw;
   uint32_t *_px;
   CFAbsoluteTime _lastHeard;
   BOOL _gotAny, _lost;
   uint16_t _seq;
   atomic_uint _joy;
   uint16_t _keys[NC_MAX_KEYS];      // guarded by @synchronized(self)
   unsigned _nKeys;
}

- (instancetype)initWithEndpoint:(nw_endpoint_t)endpoint name:(NSString *)name {
   if ((self = [super init])) {
      _name = [name copy];
      _q = dispatch_queue_create("c64wif.guest", DISPATCH_QUEUE_SERIAL);
      _reasm = malloc(sizeof(nc_reasm));
      nc_reasm_init(_reasm);
      _raw = malloc(nc_pack_bound(FE_MAX_W, FE_MAX_H));
      _px = malloc(FE_MAX_W * FE_MAX_H * 4);
      atomic_store(&_joy, 0);
      _lastHeard = CFAbsoluteTimeGetCurrent();

      _conn = nw_connection_create(endpoint, UdpParams());
      nw_connection_set_queue(_conn, _q);
      __weak NetGuest *ws = self;
      nw_connection_set_state_changed_handler(_conn, ^(nw_connection_state_t state, nw_error_t error) {
         NetGuest *s = ws;
         if (!s) return;
         if (state == nw_connection_state_ready) [s sendInput];
         else if (state == nw_connection_state_failed) [s lose:[@"Couldn't reach player 1. " stringByAppendingString:ProblemText(error)]];
      });
      nw_connection_start(_conn);
      [self receive];

      // The whole input state 30 times a second: also tells player 1 we're here.
      _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
      dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_MSEC * 5);
      dispatch_source_set_event_handler(_timer, ^{
         NetGuest *s = ws;
         if (!s) return;
         [s sendInput];
         if (!s->_lost && CFAbsoluteTimeGetCurrent() - s->_lastHeard > kTimeout)
            [s lose:(s->_gotAny ? @"Lost player 1." : @"Player 1 isn't answering.")];
      });
      dispatch_resume(_timer);
      [self status:@"Joining..." lost:NO];
   }
   return self;
}

- (void)status:(NSString *)text lost:(BOOL)lost {
   dispatch_async(dispatch_get_main_queue(), ^{ if (self.onStatus) self.onStatus(text, lost); });
}

// _q
- (void)lose:(NSString *)why {
   if (_lost) return;
   _lost = YES;
   [self status:why lost:YES];
}

// _q
- (void)sendInput {
   if (!_conn || _lost) return;
   uint16_t keys[NC_MAX_KEYS];
   unsigned n;
   @synchronized (self) {
      n = _nKeys;
      memcpy(keys, _keys, n * sizeof(uint16_t));
   }
   uint8_t pkt[NC_HEADER + 4 + 2 * NC_MAX_KEYS];
   size_t len = nc_input_packet(_seq++, (uint8_t)atomic_load(&_joy), keys, n, pkt, sizeof(pkt));
   SendBytes(_conn, pkt, len, _q);
}

- (void)setJoy:(uint32_t)bits {
   atomic_store(&_joy, bits & 0xff);
   dispatch_async(_q, ^{ [self sendInput]; });
}

- (void)key:(unsigned)retrok down:(BOOL)down {
   @synchronized (self) {
      unsigned i;
      for (i = 0; i < _nKeys && _keys[i] != retrok; i++) { }
      if (down && i == _nKeys && _nKeys < NC_MAX_KEYS) _keys[_nKeys++] = (uint16_t)retrok;
      if (!down && i < _nKeys) _keys[i] = _keys[--_nKeys];
   }
   dispatch_async(_q, ^{ [self sendInput]; });
}

- (void)receive {
   __weak NetGuest *ws = self;
   nw_connection_receive_message(_conn, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t error) {
      NetGuest *s = ws;
      if (!s) return;
      if (content) WithBytes(content, ^(const uint8_t *p, size_t len) { [s handle:p len:len]; });
      if (!error && s->_conn) [s receive];
   });
}

// _q
- (void)handle:(const uint8_t *)p len:(size_t)len {
   int type = nc_type(p, len);
   if (!type) return;
   _lastHeard = CFAbsoluteTimeGetCurrent();
   if (!_gotAny) {
      _gotAny = YES;
      [self status:[NSString stringWithFormat:@"Joined %@ as player 2", _name] lost:NO];
   }
   if (type == NC_BYE) { [self lose:@"Player 1 stopped the game."]; return; }
   if (type == NC_AUDIO) {
      uint16_t seq; uint32_t rate; const uint8_t *smp; unsigned n;
      if (!nc_audio_parse(p, len, &seq, &rate, &smp, &n)) return;
      int16_t st[2 * NC_MAX_AUDIO];
      for (unsigned i = 0; i < n; i++) st[2 * i] = st[2 * i + 1] = (int16_t)(smp[2 * i] | smp[2 * i + 1] << 8);
      fe_push_audio(st, n, rate);
      return;
   }
   if (type != NC_VIDEO) return;
   const uint8_t *msg;
   size_t mlen = nc_reasm_add(_reasm, p, len, &msg);
   if (mlen < 5) return;
   size_t packed = msg[1] | msg[2] << 8 | msg[3] << 16 | (size_t)msg[4] << 24;
   size_t bound = nc_pack_bound(FE_MAX_W, FE_MAX_H);
   if (packed > bound) return;
   const uint8_t *src = msg + 5;
   if (msg[0] == 1) {
      if (compression_decode_buffer(_raw, packed, msg + 5, mlen - 5, NULL, COMPRESSION_LZ4) != packed) return;
      src = _raw;
   } else if (mlen - 5 < packed) {
      return;
   }
   unsigned w, h;
   float aspect;
   if (nc_unpack_frame(src, packed, _px, FE_MAX_W * FE_MAX_H, &w, &h, &aspect))
      fe_push_frame(_px, w, h, aspect);
}

- (void)stop {
   dispatch_sync(_q, ^{
      if (self->_conn) {
         uint8_t bye[NC_HEADER] = { 'C', '6', NC_BYE };
         SendBytes(self->_conn, bye, sizeof(bye), self->_q);
         nw_connection_cancel(self->_conn);
         self->_conn = nil;
      }
      if (self->_timer) dispatch_source_cancel(self->_timer);
      self->_timer = nil;
      self->_lost = YES;
   });
}

@end
