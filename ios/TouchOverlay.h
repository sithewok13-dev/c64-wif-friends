// C64 wif Friends: the on-screen controls (house style: stick where the
// left thumb lands, FIRE under the right thumb, keys along the top).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TouchOverlay : UIView
// Joystick bits (FE_JOY_*) whenever they change.
@property (nonatomic, copy, nullable) void (^onJoy)(uint32_t bits);
// A C64 key (libretro RETROK_* code) going down or up.
@property (nonatomic, copy, nullable) void (^onKey)(unsigned retrok, BOOL down);
// The MENU key was tapped.
@property (nonatomic, copy, nullable) void (^onMenu)(void);
// Where the C64 picture is. In portrait the keys go in a row under it; in
// landscape (compact) they fold into KEYS and MENU in the side space.
@property (nonatomic) CGRect pictureFrame;
@property (nonatomic) BOOL compact;
@end

NS_ASSUME_NONNULL_END
