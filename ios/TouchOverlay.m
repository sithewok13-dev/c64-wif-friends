// C64 wif Friends: on-screen controls. Numbers follow the house style
// (jk-files docs/HOUSE_STYLE.md, section 3.1): stick radius 60 pt in the
// left 42% of the screen, FIRE radius 42 pt at the bottom right, buttons at
// 65% until touched, 6 pt of forgiveness around every button.
#import "TouchOverlay.h"
#include "frontend.h"
#include "libretro.h"

static const CGFloat kStickRadius = 60.0;
static const CGFloat kStickZone = 0.42;     // left share of the screen
static const CGFloat kDeadZone = 0.28;      // of the radius
static const CGFloat kFireRadius = 42.0;
static const CGFloat kFireMargin = 30.0;
static const CGFloat kSlop = 6.0;
static const CGFloat kIdleAlpha = 0.65;
static const CGFloat kKeyH = 36.0, kKeyGap = 6.0;

typedef NS_ENUM(NSInteger, BtnKind) { BtnHeld, BtnTap, BtnABC, BtnMenu };

@interface OverlayButton : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic) unsigned retrok;
@property (nonatomic) BtnKind kind;
@property (nonatomic) CGRect frame;
@property (nonatomic) NSInteger touches;   // fingers on it
@property (nonatomic) BOOL lit;            // shown as on (ABC open)
@property (nonatomic) BOOL inTray;
@end
@implementation OverlayButton
@end

@implementation TouchOverlay {
   NSMutableArray<OverlayButton *> *_top, *_corner, *_trayFn, *_tray;
   UITouch *_stickTouch;
   CGPoint _stickCenter, _stickPos;
   uint32_t _stickBits;
   NSMutableSet<UITouch *> *_fireTouches;
   NSMapTable<UITouch *, OverlayButton *> *_buttonTouches;
   uint32_t _bits;
   BOOL _trayOpen;
   CGRect _trayRect;
}

static OverlayButton *Btn(NSString *label, unsigned code, BtnKind kind) {
   OverlayButton *b = [OverlayButton new];
   b.label = label; b.retrok = code; b.kind = kind;
   return b;
}

- (instancetype)initWithFrame:(CGRect)frame {
   if ((self = [super initWithFrame:frame])) {
      self.multipleTouchEnabled = YES;
      self.opaque = NO;
      self.backgroundColor = UIColor.clearColor;
      self.contentMode = UIViewContentModeRedraw;
      _fireTouches = [NSMutableSet set];
      _buttonTouches = [NSMapTable strongToStrongObjectsMapTable];
      _top = [@[ Btn(@"F1", RETROK_F1, BtnHeld), Btn(@"F3", RETROK_F3, BtnHeld),
                 Btn(@"F5", RETROK_F5, BtnHeld), Btn(@"F7", RETROK_F7, BtnHeld),
                 Btn(@"SPACE", RETROK_SPACE, BtnHeld), Btn(@"RETURN", RETROK_RETURN, BtnHeld),
                 Btn(@"STOP", RETROK_ESCAPE, BtnHeld), Btn(@"ABC", 0, BtnABC),
                 Btn(@"MENU", 0, BtnMenu) ] mutableCopy];
      _corner = [@[ Btn(@"KEYS", 0, BtnABC), Btn(@"MENU", 0, BtnMenu) ] mutableCopy];
      _trayFn = [@[ Btn(@"F1", RETROK_F1, BtnHeld), Btn(@"F3", RETROK_F3, BtnHeld),
                    Btn(@"F5", RETROK_F5, BtnHeld), Btn(@"F7", RETROK_F7, BtnHeld),
                    Btn(@"SPACE", RETROK_SPACE, BtnHeld), Btn(@"RETURN", RETROK_RETURN, BtnHeld),
                    Btn(@"STOP", RETROK_ESCAPE, BtnHeld) ] mutableCopy];
      for (OverlayButton *b in _trayFn) b.inTray = YES;
      _tray = [NSMutableArray array];
      NSArray *rows = @[ @"1234567890", @"QWERTYUIOP", @"ASDFGHJKL", @"#ZXCVBNM,." ];
      for (NSString *row in rows) {
         for (NSUInteger i = 0; i < row.length; i++) {
            unichar c = [row characterAtIndex:i];
            OverlayButton *b;
            if (c == '#') b = Btn(@"C=", RETROK_LCTRL, BtnTap);
            else if (c >= 'A' && c <= 'Z') b = Btn([NSString stringWithCharacters:&c length:1], RETROK_a + (c - 'A'), BtnTap);
            else if (c >= '0' && c <= '9') b = Btn([NSString stringWithCharacters:&c length:1], RETROK_0 + (c - '0'), BtnTap);
            else if (c == ',') b = Btn(@",", RETROK_COMMA, BtnTap);
            else b = Btn(@".", RETROK_PERIOD, BtnTap);
            b.inTray = YES;
            [_tray addObject:b];
         }
      }
   }
   return self;
}

#pragma mark Layout

- (CGPoint)fireCenter {
   UIEdgeInsets s = self.safeAreaInsets;
   CGSize z = self.bounds.size;
   return CGPointMake(z.width - s.right - kFireMargin - kFireRadius,
                      z.height - MAX(s.bottom, 8) - kFireMargin - kFireRadius);
}

- (NSArray<OverlayButton *> *)visibleKeys { return _compact ? _corner : _top; }

- (NSArray<OverlayButton *> *)trayKeys {
   return _compact ? [_trayFn arrayByAddingObjectsFromArray:_tray] : _tray;
}

- (void)setPictureFrame:(CGRect)f { _pictureFrame = f; [self setNeedsLayout]; }

- (void)setCompact:(BOOL)c {
   if (c == _compact) return;
   // Let go of anything held on the buttons that are about to disappear.
   for (UITouch *t in [[_buttonTouches keyEnumerator] allObjects]) [self releaseButtonForTouch:t inside:NO];
   _compact = c;
   _trayOpen = NO;
   for (OverlayButton *b in _top) b.lit = NO;
   for (OverlayButton *b in _corner) b.lit = NO;
   [self setNeedsLayout];
}

- (void)layoutSubviews {
   [super layoutSubviews];
   UIEdgeInsets s = self.safeAreaInsets;
   CGSize z = self.bounds.size;
   UIFont *font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold];
   CGFloat (^widthOf)(OverlayButton *) = ^CGFloat(OverlayButton *b) {
      return MAX(42, [b.label sizeWithAttributes:@{NSFontAttributeName: font}].width + 16);
   };
   if (_compact) {
      // Landscape: KEYS over MENU, top right, in the space beside the picture.
      CGFloat w = 64, x = z.width - MAX(s.right, 8) - 8 - w, y = MAX(s.top, 8);
      for (OverlayButton *b in _corner) {
         b.frame = CGRectMake(x, y, w, kKeyH);
         y += kKeyH + kKeyGap;
      }
   } else {
      // Portrait: one centred row (wrapping) just under the picture.
      CGFloat left = MAX(s.left, 8), right = z.width - MAX(s.right, 8);
      CGFloat y = CGRectIsEmpty(_pictureFrame) ? MAX(s.top, 8) : CGRectGetMaxY(_pictureFrame) + 10;
      NSMutableArray<NSArray<OverlayButton *> *> *rows = [NSMutableArray array];
      NSMutableArray *row = [NSMutableArray array];
      CGFloat rowW = 0;
      for (OverlayButton *b in _top) {
         CGFloat w = widthOf(b);
         if (row.count && rowW + kKeyGap + w > right - left) { [rows addObject:row]; row = [NSMutableArray array]; rowW = 0; }
         rowW += (row.count ? kKeyGap : 0) + w;
         [row addObject:b];
      }
      if (row.count) [rows addObject:row];
      for (NSArray<OverlayButton *> *r in rows) {
         CGFloat total = 0;
         for (OverlayButton *b in r) total += widthOf(b);
         total += kKeyGap * (r.count - 1);
         CGFloat x = (z.width - total) / 2;
         for (OverlayButton *b in r) {
            CGFloat w = widthOf(b);
            b.frame = CGRectMake(x, y, w, kKeyH);
            x += w + kKeyGap;
         }
         y += kKeyH + kKeyGap;
      }
   }
   // The tray at the bottom middle: in landscape a row of F-keys etc. on top.
   CGFloat kw = 34, kh = 36, gap = 5, pad = 8;
   CGFloat trayW = 10 * kw + 9 * gap + 2 * pad;
   NSInteger fnRows = _compact ? 1 : 0;
   CGFloat trayH = (4 + fnRows) * kh + (3 + fnRows) * gap + 2 * pad;
   CGFloat tx = (z.width - trayW) / 2;
   CGFloat ty = z.height - MAX(s.bottom, 8) - 6 - trayH;
   _trayRect = CGRectMake(tx, ty, trayW, trayH);
   CGFloat ry = ty + pad;
   if (_compact) {
      CGFloat fw = (trayW - 2 * pad - 6 * gap) / 7;
      for (NSUInteger i = 0; i < _trayFn.count; i++)
         _trayFn[i].frame = CGRectMake(tx + pad + i * (fw + gap), ry, fw, kh);
      ry += kh + gap;
   }
   NSArray<NSNumber *> *counts = @[ @10, @10, @9, @10 ];
   NSUInteger idx = 0;
   for (NSUInteger r = 0; r < counts.count; r++) {
      NSInteger n = counts[r].integerValue;
      CGFloat rowW = n * kw + (n - 1) * gap;
      CGFloat rx = tx + (trayW - rowW) / 2;
      for (NSInteger i = 0; i < n; i++, idx++)
         _tray[idx].frame = CGRectMake(rx + i * (kw + gap), ry + r * (kh + gap), kw, kh);
   }
   [self setNeedsDisplay];
}

- (void)safeAreaInsetsDidChange {
   [super safeAreaInsetsDidChange];
   [self setNeedsLayout];
}

#pragma mark Drawing

- (void)drawButton:(OverlayButton *)b font:(UIFont *)font {
   BOOL on = b.touches > 0 || b.lit;
   UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:b.frame cornerRadius:8];
   [[UIColor colorWithRed:0.05 green:0.04 blue:0.14 alpha:(on ? 0.95 : 0.7 * kIdleAlpha)] setFill];
   if (b.touches > 0) [[UIColor colorWithRed:0.42 green:0.37 blue:0.71 alpha:1] setFill];
   [p fill];
   UIColor *edge = b.lit ? [UIColor colorWithRed:0.94 green:0.76 blue:0.35 alpha:1]
                         : [UIColor colorWithWhite:0.92 alpha:(on ? 0.9 : 0.35)];
   [edge setStroke];
   p.lineWidth = 1;
   [p stroke];
   NSDictionary *a = @{ NSFontAttributeName: font,
                        NSForegroundColorAttributeName: (b.lit ? edge : [UIColor colorWithWhite:0.95 alpha:(on ? 1 : kIdleAlpha + 0.1)]) };
   CGSize ts = [b.label sizeWithAttributes:a];
   [b.label drawAtPoint:CGPointMake(CGRectGetMidX(b.frame) - ts.width / 2, CGRectGetMidY(b.frame) - ts.height / 2) withAttributes:a];
}

- (void)drawRect:(CGRect)rect {
   UIFont *font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold];
   // Stick: the ring sits where the thumb landed; idle, it waits bottom left.
   CGPoint c = _stickTouch ? _stickCenter
      : CGPointMake(MAX(self.safeAreaInsets.left, 0) + 110, self.bounds.size.height - MAX(self.safeAreaInsets.bottom, 8) - 100);
   UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - kStickRadius, c.y - kStickRadius, 2 * kStickRadius, 2 * kStickRadius)];
   [[UIColor colorWithRed:0.42 green:0.37 blue:0.71 alpha:(_stickTouch ? 0.30 : 0.18)] setFill];
   [ring fill];
   [[UIColor colorWithWhite:0.92 alpha:(_stickTouch ? 0.6 : 0.3)] setStroke];
   ring.lineWidth = 2;
   [ring stroke];
   if (_stickTouch) {
      UIBezierPath *knob = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(_stickPos.x - 27, _stickPos.y - 27, 54, 54)];
      [[UIColor colorWithWhite:0.92 alpha:0.8] setFill];
      [knob fill];
   }
   // FIRE
   CGPoint f = [self fireCenter];
   BOOL fireOn = (_bits & FE_JOY_FIRE) != 0;
   UIBezierPath *fire = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(f.x - kFireRadius, f.y - kFireRadius, 2 * kFireRadius, 2 * kFireRadius)];
   [[UIColor colorWithRed:0.88 green:0.28 blue:0.35 alpha:(fireOn ? 1.0 : kIdleAlpha)] setFill];
   [fire fill];
   NSDictionary *fa = @{ NSFontAttributeName: [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightHeavy],
                         NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:(fireOn ? 1 : 0.85)] };
   CGSize fs = [@"FIRE" sizeWithAttributes:fa];
   [@"FIRE" drawAtPoint:CGPointMake(f.x - fs.width / 2, f.y - fs.height / 2) withAttributes:fa];
   // Keys
   for (OverlayButton *b in [self visibleKeys]) [self drawButton:b font:font];
   if (_trayOpen) {
      UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:_trayRect cornerRadius:12];
      [[UIColor colorWithRed:0.05 green:0.04 blue:0.14 alpha:0.9] setFill];
      [bg fill];
      UIFont *small = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightBold];
      for (OverlayButton *b in _trayFn) if (_compact) [self drawButton:b font:small];
      for (OverlayButton *b in _tray) [self drawButton:b font:font];
   }
}

#pragma mark Touches

- (OverlayButton *)buttonAt:(CGPoint)p {
   // Nearest button within the forgiveness margin wins.
   OverlayButton *best = nil;
   CGFloat bestD = CGFLOAT_MAX;
   NSArray *all = _trayOpen ? [[self trayKeys] arrayByAddingObjectsFromArray:[self visibleKeys]] : [self visibleKeys];
   for (OverlayButton *b in all) {
      CGRect r = CGRectInset(b.frame, -kSlop, -kSlop);
      if (!CGRectContainsPoint(r, p)) continue;
      CGFloat d = hypot(p.x - CGRectGetMidX(b.frame), p.y - CGRectGetMidY(b.frame));
      if (d < bestD) { bestD = d; best = b; }
   }
   return best;
}

- (BOOL)nearFire:(CGPoint)p {
   CGPoint f = [self fireCenter];
   return hypot(p.x - f.x, p.y - f.y) <= kFireRadius + kSlop;
}

- (void)updateStick {
   CGFloat dx = _stickPos.x - _stickCenter.x, dy = _stickPos.y - _stickCenter.y;
   CGFloat d = hypot(dx, dy);
   if (d > kStickRadius) {
      // The ring follows a thumb that drifts too far, so it never runs out of room.
      CGFloat pull = d - kStickRadius;
      _stickCenter.x += dx / d * pull; _stickCenter.y += dy / d * pull;
      dx = _stickPos.x - _stickCenter.x; dy = _stickPos.y - _stickCenter.y;
      d = kStickRadius;
   }
   uint32_t bits = 0;
   if (d >= kDeadZone * kStickRadius) {
      // 8 sectors of 45 degrees; up the screen is up.
      double a = atan2(-dy, dx);
      long s = lround(a / (M_PI / 4));   // -4..4
      switch (s) {
         case 0: bits = FE_JOY_RIGHT; break;
         case 1: bits = FE_JOY_RIGHT | FE_JOY_UP; break;
         case 2: bits = FE_JOY_UP; break;
         case 3: bits = FE_JOY_UP | FE_JOY_LEFT; break;
         case 4: case -4: bits = FE_JOY_LEFT; break;
         case -3: bits = FE_JOY_LEFT | FE_JOY_DOWN; break;
         case -2: bits = FE_JOY_DOWN; break;
         default: bits = FE_JOY_DOWN | FE_JOY_RIGHT; break;
      }
   }
   _stickBits = bits;
}

- (void)publish {
   uint32_t bits = _stickBits | (_fireTouches.count ? FE_JOY_FIRE : 0);
   if (bits != _bits) {
      _bits = bits;
      if (self.onJoy) self.onJoy(bits);
   }
   [self setNeedsDisplay];
}

- (void)pressButton:(OverlayButton *)b touch:(UITouch *)t {
   [_buttonTouches setObject:b forKey:t];
   b.touches++;
   switch (b.kind) {
      case BtnHeld:
         if (b.touches == 1 && self.onKey) self.onKey(b.retrok, YES);
         break;
      case BtnTap:
         // One tap, one key. The emulator holds it long enough to be seen.
         if (self.onKey) { self.onKey(b.retrok, YES); self.onKey(b.retrok, NO); }
         break;
      case BtnABC:
         _trayOpen = !_trayOpen;
         b.lit = _trayOpen;
         break;
      case BtnMenu:
         break;
   }
}

- (void)releaseButtonForTouch:(UITouch *)t inside:(BOOL)inside {
   OverlayButton *b = [_buttonTouches objectForKey:t];
   if (!b) return;
   [_buttonTouches removeObjectForKey:t];
   b.touches = MAX(0, b.touches - 1);
   if (b.kind == BtnHeld && b.touches == 0 && self.onKey) self.onKey(b.retrok, NO);
   if (b.kind == BtnMenu && inside && self.onMenu) self.onMenu();
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
   CGFloat w = self.bounds.size.width;
   for (UITouch *t in touches) {
      CGPoint p = [t locationInView:self];
      OverlayButton *b = [self buttonAt:p];
      if (b) { [self pressButton:b touch:t]; continue; }
      if (_trayOpen && CGRectContainsPoint(_trayRect, p)) continue;   // between tray keys
      if ([self nearFire:p] || p.x >= w * kStickZone || _stickTouch) {
         [_fireTouches addObject:t];
         continue;
      }
      _stickTouch = t;
      _stickCenter = _stickPos = p;
      [self updateStick];
   }
   [self publish];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
   for (UITouch *t in touches) {
      if (t == _stickTouch) {
         _stickPos = [t locationInView:self];
         [self updateStick];
      }
   }
   [self publish];
}

- (void)endTouches:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled {
   for (UITouch *t in touches) {
      if (t == _stickTouch) { _stickTouch = nil; _stickBits = 0; }
      [_fireTouches removeObject:t];
      OverlayButton *b = [_buttonTouches objectForKey:t];
      BOOL inside = !cancelled && b && CGRectContainsPoint(CGRectInset(b.frame, -kSlop, -kSlop), [t locationInView:self]);
      [self releaseButtonForTouch:t inside:inside];
   }
   [self publish];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches cancelled:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches cancelled:YES]; }

@end
