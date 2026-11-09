// C64 wif Friends: the app. A game list, then the C64 full screen with the
// touch controls on top. One game per launch: VICE can't be shut down and
// started again inside one process, so MENU > Change game asks to reopen.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach_time.h>
#include <pthread.h>
#import "TouchOverlay.h"
#include "frontend.h"

static NSString *DocumentsDir(void) {
   return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static NSArray<NSString *> *GameExtensions(void) {
   return @[ @"d64", @"d71", @"d81", @"g64", @"t64", @"tap", @"prg", @"p00", @"crt", @"zip", @"7z", @"gz", @"m3u" ];
}

static UIColor *C64Blue(void) { return [UIColor colorWithRed:0x35/255.0 green:0x28/255.0 blue:0x79/255.0 alpha:1]; }
static UIColor *C64Light(void) { return [UIColor colorWithRed:0x6c/255.0 green:0x5e/255.0 blue:0xb5/255.0 alpha:1]; }

static void *EmuThread(void *arg);
static NSString *AppVersion(void);

#pragma mark - The C64 screen

@interface GameViewController : UIViewController
- (instancetype)initWithGamePath:(NSString *)path;
@end

@implementation GameViewController {
   NSString *_path;
   UIView *_screen;
   TouchOverlay *_overlay;
   CADisplayLink *_link;
   uint32_t *_pixels;
   uint64_t _seq;
   unsigned _fw, _fh;
   pthread_t _thread;
   volatile BOOL _paused;
   volatile BOOL _started;
   volatile BOOL _resetRequested;
   AudioComponentInstance _audio;
   UILabel *_message;
}

- (instancetype)initWithGamePath:(NSString *)path {
   if ((self = [super initWithNibName:nil bundle:nil])) {
      _path = [path copy];
      _pixels = calloc(FE_MAX_W * FE_MAX_H, 4);
      self.modalPresentationStyle = UIModalPresentationFullScreen;
   }
   return self;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad {
   [super viewDidLoad];
   self.view.backgroundColor = UIColor.blackColor;
   _screen = [UIView new];
   _screen.layer.magnificationFilter = kCAFilterNearest;
   _screen.layer.contentsGravity = kCAGravityResize;
   [self.view addSubview:_screen];

   _message = [UILabel new];
   _message.textColor = UIColor.whiteColor;
   _message.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightSemibold];
   _message.numberOfLines = 0;
   _message.textAlignment = NSTextAlignmentCenter;
   _message.text = @"LOADING...";
   [self.view addSubview:_message];

   _overlay = [[TouchOverlay alloc] initWithFrame:self.view.bounds];
   _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
   _overlay.onJoy = ^(uint32_t bits) { fe_set_joy(0, bits); };
   _overlay.onKey = ^(unsigned code, BOOL down) { fe_key(code, down); };
   __weak typeof(self) weakSelf = self;
   _overlay.onMenu = ^{ [weakSelf showMenu]; };
   [self.view addSubview:_overlay];

   NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
   [nc addObserver:self selector:@selector(goBackground) name:UIApplicationWillResignActiveNotification object:nil];
   [nc addObserver:self selector:@selector(goForeground) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewDidLayoutSubviews {
   [super viewDidLayoutSubviews];
   CGSize b = self.view.bounds.size;
   UIEdgeInsets s = self.view.safeAreaInsets;
   // Fit the picture between the cutouts, keeping the C64's shape.
   CGRect area = CGRectMake(s.left, 0, b.width - s.left - s.right, b.height);
   float aspect = _started ? fe_aspect() : 4.0f / 3.0f;
   CGFloat w = area.size.width, h = w / aspect;
   if (h > area.size.height) { h = area.size.height; w = h * aspect; }
   _screen.frame = CGRectMake(CGRectGetMidX(area) - w / 2, CGRectGetMidY(area) - h / 2, w, h);
   _message.frame = CGRectInset(_screen.frame, 24, 24);
}

- (void)viewDidAppear:(BOOL)animated {
   [super viewDidAppear:animated];
   if (_link) return;
   [UIApplication sharedApplication].idleTimerDisabled = YES;
   pthread_create(&_thread, NULL, EmuThread, (__bridge void *)self);
   _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
   [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tick {
   unsigned w, h;
   if (!fe_copy_frame(_pixels, &w, &h, &_seq)) return;
   if (!_message.hidden) { _message.hidden = YES; [self.view setNeedsLayout]; }
   CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
   CGContextRef ctx = CGBitmapContextCreate(_pixels, w, h, 8, w * 4, cs,
                                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
   CGImageRef img = CGBitmapContextCreateImage(ctx);
   _screen.layer.contents = (__bridge id)img;
   CGImageRelease(img);
   CGContextRelease(ctx);
   CGColorSpaceRelease(cs);
}

#pragma mark Emulator thread

static void *EmuThread(void *arg) {
   GameViewController *vc = (__bridge GameViewController *)arg;
   [vc runEmulator];
   return NULL;
}

- (void)runEmulator {
   pthread_setname_np("c64");
   if (!fe_start(_path.fileSystemRepresentation)) {
      NSString *err = [NSString stringWithUTF8String:fe_last_error()];
      dispatch_async(dispatch_get_main_queue(), ^{
         self->_message.text = [NSString stringWithFormat:@"%@\n\nTap MENU to pick another game.", err];
      });
      return;
   }
   _started = YES;
   dispatch_async(dispatch_get_main_queue(), ^{
      [self.view setNeedsLayout];
      [self startAudio];
   });

   mach_timebase_info_data_t tb;
   mach_timebase_info(&tb);
   const double ticksPerSec = 1e9 * tb.denom / tb.numer;
   const double sampleRate = fe_sample_rate();
   uint64_t next = mach_absolute_time();
   while (1) {
      if (_resetRequested) { fe_reset(); _resetRequested = NO; }
      if (_paused) { usleep(20000); next = mach_absolute_time(); continue; }
      if (fe_fast_forward()) {
         // VICE is loading: run flat out, a few frames per screen refresh.
         for (int i = 0; i < 8 && fe_fast_forward(); i++) fe_run_frame();
         usleep(2000);
         next = mach_absolute_time();
         continue;
      }
      fe_run_frame();
      // Keep about 60 ms of sound queued: run a touch slower or faster.
      double queued = fe_audio_buffered() / sampleRate;
      double adjust = queued > 0.09 ? 1.02 : (queued < 0.03 ? 0.98 : 1.0);
      next += (uint64_t)(ticksPerSec / fe_fps() * adjust);
      uint64_t now = mach_absolute_time();
      if (next > now) {
         mach_wait_until(next);
      } else if (now - next > ticksPerSec / 4) {
         next = now;   // fell far behind (a hiccup): don't try to catch up
      }
   }
}

#pragma mark Sound

static OSStatus AudioRender(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                            UInt32 bus, UInt32 frames, AudioBufferList *io) {
   fe_audio_read((int16_t *)io->mBuffers[0].mData, frames);
   return noErr;
}

- (void)startAudio {
   [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
   [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:0.01 error:nil];
   [[AVAudioSession sharedInstance] setActive:YES error:nil];
   AudioComponentDescription d = { kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0 };
   AudioComponent comp = AudioComponentFindNext(NULL, &d);
   if (!comp || AudioComponentInstanceNew(comp, &_audio) != noErr) return;
   AudioStreamBasicDescription f = {0};
   f.mSampleRate = fe_sample_rate();
   f.mFormatID = kAudioFormatLinearPCM;
   f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
   f.mChannelsPerFrame = 2;
   f.mBitsPerChannel = 16;
   f.mBytesPerFrame = 4;
   f.mFramesPerPacket = 1;
   f.mBytesPerPacket = 4;
   AudioUnitSetProperty(_audio, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f));
   AURenderCallbackStruct cb = { AudioRender, NULL };
   AudioUnitSetProperty(_audio, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
   AudioUnitInitialize(_audio);
   AudioOutputUnitStart(_audio);
}

- (void)goBackground {
   _paused = YES;
   if (_audio) AudioOutputUnitStop(_audio);
}

- (void)goForeground {
   _paused = NO;
   if (_audio) AudioOutputUnitStart(_audio);
}

#pragma mark Menu

- (void)showMenu {
   UIAlertController *a = [UIAlertController alertControllerWithTitle:@"C64 wif Friends"
      message:[NSString stringWithFormat:@"%@\n%@", _path.lastPathComponent, AppVersion()]
      preferredStyle:UIAlertControllerStyleAlert];
   [a addAction:[UIAlertAction actionWithTitle:@"Reset the C64" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
      self->_resetRequested = YES;
   }]];
   [a addAction:[UIAlertAction actionWithTitle:@"Change game" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
      UIAlertController *b = [UIAlertController alertControllerWithTitle:@"Change game"
         message:@"Close C64 wif Friends (swipe it away), then open it again and pick the game."
         preferredStyle:UIAlertControllerStyleAlert];
      [b addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
      [self presentViewController:b animated:YES completion:nil];
   }]];
   [a addAction:[UIAlertAction actionWithTitle:@"Back to the game" style:UIAlertActionStyleCancel handler:nil]];
   [self presentViewController:a animated:YES completion:nil];
}

static NSString *AppVersion(void) {
   NSDictionary *i = NSBundle.mainBundle.infoDictionary;
   NSString *v = i[@"CFBundleShortVersionString"], *b = i[@"CFBundleVersion"];
   return [b isEqualToString:v] ? [NSString stringWithFormat:@"v%@", v] : [NSString stringWithFormat:@"v%@ (%@)", v, b];
}

@end

#pragma mark - Game list

@interface GamesViewController : UITableViewController <UIDocumentPickerDelegate>
@end

@implementation GamesViewController {
   NSArray<NSString *> *_games;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)viewDidLoad {
   [super viewDidLoad];
   self.title = @"C64 wif Friends";
   self.tableView.backgroundColor = C64Blue();
   self.tableView.separatorColor = C64Light();
   self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Add game"
      style:UIBarButtonItemStylePlain target:self action:@selector(addGame)];
   [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
   [super viewWillAppear:animated];
   [self reload];
}

- (void)reload {
   NSMutableArray *g = [NSMutableArray array];
   for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:DocumentsDir() error:nil])
      if ([GameExtensions() containsObject:f.pathExtension.lowercaseString]) [g addObject:f];
   _games = [g sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
   [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX(1, (NSInteger)_games.count); }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
   return [NSString stringWithFormat:@"Tap Add game to pick a disk (.d64), tape (.t64, .tap), program (.prg) or cartridge (.crt) from Files. "
           "Games are kept in Files > On My iPhone > C64 wif Friends.\n\n%@", AppVersion()];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
   UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"g"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"g"];
   c.backgroundColor = C64Blue();
   c.textLabel.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightSemibold];
   if (_games.count == 0) {
      c.textLabel.text = @"No games yet";
      c.textLabel.textColor = C64Light();
      c.selectionStyle = UITableViewCellSelectionStyleNone;
   } else {
      c.textLabel.text = _games[ip.row];
      c.textLabel.textColor = UIColor.whiteColor;
      c.selectionStyle = UITableViewCellSelectionStyleDefault;
   }
   return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
   [tv deselectRowAtIndexPath:ip animated:YES];
   if (_games.count == 0) { [self addGame]; return; }
   NSString *path = [DocumentsDir() stringByAppendingPathComponent:_games[ip.row]];
   [self presentViewController:[[GameViewController alloc] initWithGamePath:path] animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return _games.count > 0; }

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
   if (st != UITableViewCellEditingStyleDelete) return;
   [NSFileManager.defaultManager removeItemAtPath:[DocumentsDir() stringByAppendingPathComponent:_games[ip.row]] error:nil];
   [self reload];
}

- (void)addGame {
   NSMutableArray<UTType *> *types = [NSMutableArray array];
   for (NSString *e in GameExtensions()) {
      UTType *t = [UTType typeWithFilenameExtension:e];
      if (t) [types addObject:t];
   }
   [types addObject:UTTypeData];
   UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
   p.delegate = self;
   [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
   for (NSURL *u in urls) {
      NSString *dst = [DocumentsDir() stringByAppendingPathComponent:u.lastPathComponent];
      [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
      [NSFileManager.defaultManager copyItemAtPath:u.path toPath:dst error:nil];
   }
   [self reload];
}

@end

#pragma mark - App

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
   NSFileManager *fm = NSFileManager.defaultManager;
   NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
   NSString *system = [support stringByAppendingPathComponent:@"system"];
   NSString *saves = [support stringByAppendingPathComponent:@"saves"];
   [fm createDirectoryAtPath:system withIntermediateDirectories:YES attributes:nil error:nil];
   [fm createDirectoryAtPath:saves withIntermediateDirectories:YES attributes:nil error:nil];
   fe_setup(system.fileSystemRepresentation, saves.fileSystemRepresentation,
            [DocumentsDir() stringByAppendingPathComponent:@"c64wif-log.txt"].fileSystemRepresentation);

   self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
   UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[GamesViewController new]];
   UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
   [ap configureWithOpaqueBackground];
   ap.backgroundColor = C64Light();
   ap.titleTextAttributes = @{ NSForegroundColorAttributeName: UIColor.whiteColor,
                               NSFontAttributeName: [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightBold] };
   nav.navigationBar.standardAppearance = ap;
   nav.navigationBar.scrollEdgeAppearance = ap;
   nav.navigationBar.tintColor = UIColor.whiteColor;
   self.window.rootViewController = nav;
   [self.window makeKeyAndVisible];
   return YES;
}

// "Open in C64 wif Friends" from Files or another app: keep a copy.
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)opts {
   BOOL scoped = [url startAccessingSecurityScopedResource];
   NSString *dst = [DocumentsDir() stringByAppendingPathComponent:url.lastPathComponent];
   if (![url.path isEqualToString:dst]) {
      [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
      [NSFileManager.defaultManager copyItemAtPath:url.path toPath:dst error:nil];
   }
   if (scoped) [url stopAccessingSecurityScopedResource];
   UINavigationController *nav = (UINavigationController *)self.window.rootViewController;
   [nav.topViewController viewWillAppear:NO];
   return YES;
}

@end

int main(int argc, char *argv[]) {
   @autoreleasepool {
      return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
   }
}
