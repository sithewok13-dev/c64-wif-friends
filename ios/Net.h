// C64 wif Friends: two phones over WiFi (Apple's Network framework, Bonjour,
// UDP; peer-to-peer WiFi too, so no router or internet is needed).
//
// The host runs the C64 and is player 1 (port 1). The guest runs no C64:
// it shows the pictures and plays the sound the host sends, and sends its
// stick, fire and keys back as player 2 (port 2). Packets: src/netcodec.h.
#import <Foundation/Foundation.h>
#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

@interface NetHost : NSObject
// Starts offering the game on the network straight away.
- (instancetype)initWithGameName:(NSString *)game;
@property (nonatomic, readonly) NSString *code;          // 4 letters, shown to the players
@property (nonatomic, readonly) NSString *statusText;    // for MENU
// Called on the main queue whenever the status changes.
@property (nonatomic, copy, nullable) void (^onStatus)(NSString *text);
// Emulator thread, after each frame: sends the newest picture and sound.
- (void)afterFrame;
- (void)stop;
@end

@interface NetBrowser : NSObject
// Called on the main queue with the games on offer nearby, and any problem.
@property (nonatomic, copy, nullable) void (^onChange)(NSArray<NSString *> *names, NSString *_Nullable problem);
- (void)start;
- (void)stop;
- (nullable nw_endpoint_t)endpointForName:(NSString *)name;
@end

@interface NetGuest : NSObject
- (instancetype)initWithEndpoint:(nw_endpoint_t)endpoint name:(NSString *)name;
@property (nonatomic, readonly) NSString *name;
// Main queue. lost = YES once player 1 has gone.
@property (nonatomic, copy, nullable) void (^onStatus)(NSString *text, BOOL lost);
- (void)setJoy:(uint32_t)bits;
- (void)key:(unsigned)retrok down:(BOOL)down;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
