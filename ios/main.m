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
#import "Net.h"
#include "frontend.h"

static NSString *DocumentsDir(void) {
   return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static NSArray<NSString *> *GameExtensions(void) {
   return @[ @"d64", @"d71", @"d81", @"g64", @"t64", @"tap", @"prg", @"p00", @"crt", @"zip", @"7z", @"gz", @"m3u" ];
}

// MENU > Show the border: VICE draws the C64's border too (smaller picture).
static NSString *const kShowBorderKey = @"c64ShowBorder";
static const char *BorderCrop(BOOL show) { return show ? "disabled" : "maximum"; }

static UIColor *C64Blue(void) { return [UIColor colorWithRed:0x35/255.0 green:0x28/255.0 blue:0x79/255.0 alpha:1]; }
static UIColor *C64Light(void) { return [UIColor colorWithRed:0x6c/255.0 green:0x5e/255.0 blue:0xb5/255.0 alpha:1]; }

static void *EmuThread(void *arg);
static NSString *AppVersion(void);

#pragma mark - The C64 screen

@interface GameViewController : UIViewController
- (instancetype)initWithGamePath:(NSString *)path;          // player 1: runs the C64
- (instancetype)initWithGuest:(NetGuest *)guest;            // player 2: shows player 1's C64
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
   float _laidOutAspect;
   NetHost *_host;
   NetGuest *_guest;
   UILabel *_toast;
   NSUInteger _toastId;
}

- (instancetype)initWithGamePath:(NSString *)path {
   if ((self = [super initWithNibName:nil bundle:nil])) {
      _path = [path copy];
      _pixels = calloc(FE_MAX_W * FE_MAX_H, 4);
      self.modalPresentationStyle = UIModalPresentationFullScreen;
   }
   return self;
}

- (instancetype)initWithGuest:(NetGuest *)guest {
   if ((self = [super initWithNibName:nil bundle:nil])) {
      _guest = guest;
      _pixels = calloc(FE_MAX_W * FE_MAX_H, 4);
      self.modalPresentationStyle = UIModalPresentationFullScreen;
   }
   return self;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }

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
   _message.text = _guest ? @"JOINING..." : @"LOADING...";
   [self.view addSubview:_message];

   _overlay = [[TouchOverlay alloc] initWithFrame:self.view.bounds];
   _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
   if (_guest) {
      NetGuest *g = _guest;
      _overlay.onJoy = ^(uint32_t bits) { [g setJoy:bits]; };
      _overlay.onKey = ^(unsigned code, BOOL down) { [g key:code down:down]; };
   } else {
      _overlay.onJoy = ^(uint32_t bits) { fe_set_joy(0, bits); };
      _overlay.onKey = ^(unsigned code, BOOL down) { fe_key(code, down); };
   }
   __weak typeof(self) weakSelf = self;
   _overlay.onMenu = ^{ [weakSelf showMenu]; };
   [self.view addSubview:_overlay];

   _toast = [UILabel new];
   _toast.textColor = UIColor.whiteColor;
   _toast.backgroundColor = [UIColor colorWithRed:0.05 green:0.04 blue:0.14 alpha:0.85];
   _toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
   _toast.textAlignment = NSTextAlignmentCenter;
   _toast.numberOfLines = 2;
   _toast.layer.cornerRadius = 10;
   _toast.layer.masksToBounds = YES;
   _toast.alpha = 0;
   _toast.userInteractionEnabled = NO;
   [self.view addSubview:_toast];

   if (_guest) {
      _guest.onStatus = ^(NSString *text, BOOL lost) {
         typeof(self) s = weakSelf;
         if (!s) return;
         [s showToast:text];
         if (lost) {
            s->_message.text = [text stringByAppendingString:@"\n\nMENU > Leave"];
            s->_message.hidden = NO;
         }
      };
   }

   NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
   [nc addObserver:self selector:@selector(goBackground) name:UIApplicationWillResignActiveNotification object:nil];
   [nc addObserver:self selector:@selector(goForeground) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewDidLayoutSubviews {
   [super viewDidLayoutSubviews];
   CGSize b = self.view.bounds.size;
   UIEdgeInsets s = self.view.safeAreaInsets;
   BOOL landscape = b.width > b.height;
   // As big as it fits, keeping the C64's shape. Landscape: the full height,
   // centred between the cutouts. Portrait: the full width, at the top, with
   // the keys and the thumbs' room below.
   float aspect = _started ? fe_aspect() : 1.6f;
   _laidOutAspect = aspect;
   CGRect area = landscape ? CGRectMake(s.left, 0, b.width - s.left - s.right, b.height)
                           : CGRectMake(0, s.top, b.width, b.height - s.top - s.bottom);
   CGFloat w = area.size.width, h = w / aspect;
   if (h > area.size.height) { h = area.size.height; w = h * aspect; }
   CGFloat y = landscape ? CGRectGetMidY(area) - h / 2 : area.origin.y;
   _screen.frame = CGRectIntegral(CGRectMake(CGRectGetMidX(area) - w / 2, y, w, h));
   _message.frame = CGRectInset(_screen.frame, 24, 24);
   _overlay.compact = landscape;
   _overlay.pictureFrame = _screen.frame;
   CGFloat tw = MIN(b.width - 40, 420);
   _toast.frame = CGRectMake((b.width - tw) / 2, CGRectGetMaxY(_screen.frame) - 64, tw, 48);
}

- (void)showToast:(NSString *)text {
   NSUInteger me = ++_toastId;
   _toast.text = text;
   [self.view bringSubviewToFront:_toast];
   [UIView animateWithDuration:0.2 animations:^{ self->_toast.alpha = 1; }];
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if (me == self->_toastId) [UIView animateWithDuration:0.4 animations:^{ self->_toast.alpha = 0; }];
   });
}

- (void)viewDidAppear:(BOOL)animated {
   [super viewDidAppear:animated];
   if (_link) return;
   [UIApplication sharedApplication].idleTimerDisabled = YES;
   if (!_guest) {
      // Player 2 can join any game: offer it on the WiFi straight away.
      _host = [[NetHost alloc] initWithGameName:_path.lastPathComponent];
      __weak typeof(self) weakSelf = self;
      _host.onStatus = ^(NSString *text) { [weakSelf showToast:text]; };
      [self showToast:_host.statusText];
      pthread_create(&_thread, NULL, EmuThread, (__bridge void *)self);
   }
   _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
   [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tick {
   unsigned w, h;
   if (_guest && !_audio && fe_audio_buffered() > 0) [self startAudio];   // player 1's sound has arrived
   if (!fe_copy_frame(_pixels, &w, &h, &_seq)) return;
   if (_guest) _started = YES;
   if (!_message.hidden) { _message.hidden = YES; [self.view setNeedsLayout]; }
   if (fabsf(fe_aspect() - _laidOutAspect) > 0.01f) [self.view setNeedsLayout];   // border on/off
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
   fe_set_option("vice_crop", BorderCrop([NSUserDefaults.standardUserDefaults boolForKey:kShowBorderKey]));
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
         [_host afterFrame];
         usleep(2000);
         next = mach_absolute_time();
         continue;
      }
      fe_run_frame();
      [_host afterFrame];   // player 2's picture and sound
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
   if (_guest) {
      UIAlertController *g = [UIAlertController alertControllerWithTitle:@"C64 wif Friends"
         message:[NSString stringWithFormat:@"Player 2 in %@\n%@", _guest.name, AppVersion()]
         preferredStyle:UIAlertControllerStyleAlert];
      [g addAction:[UIAlertAction actionWithTitle:@"Leave" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
         [self leave];
      }]];
      [g addAction:[UIAlertAction actionWithTitle:@"Back to the game" style:UIAlertActionStyleCancel handler:nil]];
      [self presentViewController:g animated:YES completion:nil];
      return;
   }
   UIAlertController *a = [UIAlertController alertControllerWithTitle:@"C64 wif Friends"
      message:[NSString stringWithFormat:@"%@\n%@\n%@", _path.lastPathComponent, _host.statusText, AppVersion()]
      preferredStyle:UIAlertControllerStyleAlert];
   [a addAction:[UIAlertAction actionWithTitle:@"Reset the C64" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
      self->_resetRequested = YES;
   }]];
   BOOL border = [NSUserDefaults.standardUserDefaults boolForKey:kShowBorderKey];
   [a addAction:[UIAlertAction actionWithTitle:(border ? @"Hide the border (bigger picture)" : @"Show the border")
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
      [NSUserDefaults.standardUserDefaults setBool:!border forKey:kShowBorderKey];
      fe_set_option("vice_crop", BorderCrop(!border));
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

- (void)leave {
   [_guest stop];
   [_link invalidate];
   _link = nil;
   if (_audio) {
      AudioOutputUnitStop(_audio);
      AudioComponentInstanceDispose(_audio);
      _audio = NULL;
   }
   [UIApplication sharedApplication].idleTimerDisabled = NO;
   [self dismissViewControllerAnimated:YES completion:nil];
}

static NSString *AppVersion(void) {
   NSDictionary *i = NSBundle.mainBundle.infoDictionary;
   NSString *v = i[@"CFBundleShortVersionString"], *b = i[@"CFBundleVersion"];
   return [b isEqualToString:v] ? [NSString stringWithFormat:@"v%@", v] : [NSString stringWithFormat:@"v%@ (%@)", v, b];
}

@end

#pragma mark - Join a friend

@interface JoinViewController : UITableViewController
@end

@implementation JoinViewController {
   NetBrowser *_browser;
   NSArray<NSString *> *_names;
   NSString *_problem;
}

- (void)viewDidLoad {
   [super viewDidLoad];
   self.title = @"Join a friend";
   self.tableView.backgroundColor = C64Blue();
   self.tableView.separatorColor = C64Light();
   _names = @[];
   _browser = [NetBrowser new];
   __weak typeof(self) weakSelf = self;
   _browser.onChange = ^(NSArray<NSString *> *names, NSString *problem) {
      typeof(self) s = weakSelf;
      if (!s) return;
      s->_names = names;
      s->_problem = problem;
      [s.tableView reloadData];
   };
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [_browser start]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [_browser stop]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX(1, (NSInteger)_names.count); }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
   NSString *help = @"On player 1's phone, open a game in C64 wif Friends. It shows up here; tap it to play as player 2. "
                    "Both phones need WiFi turned on, close to each other (the same WiFi network is best, but no internet is needed).";
   return _problem.length ? [NSString stringWithFormat:@"%@\n\n%@", _problem, help] : help;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
   UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"j"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"j"];
   c.backgroundColor = C64Blue();
   c.textLabel.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightSemibold];
   if (_names.count == 0) {
      c.textLabel.text = @"Looking for player 1...";
      c.textLabel.textColor = C64Light();
      c.selectionStyle = UITableViewCellSelectionStyleNone;
   } else {
      c.textLabel.text = _names[ip.row];
      c.textLabel.textColor = UIColor.whiteColor;
      c.selectionStyle = UITableViewCellSelectionStyleDefault;
   }
   return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
   [tv deselectRowAtIndexPath:ip animated:YES];
   if (_names.count == 0) return;
   NSString *name = _names[ip.row];
   nw_endpoint_t ep = [_browser endpointForName:name];
   if (!ep) return;
   NetGuest *g = [[NetGuest alloc] initWithEndpoint:ep name:name];
   [self presentViewController:[[GameViewController alloc] initWithGuest:g] animated:YES completion:nil];
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
   self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Join a friend"
      style:UIBarButtonItemStylePlain target:self action:@selector(join)];
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
           "Games are kept in Files > On My iPhone > C64 wif Friends.\n\n"
           "Two players: open a game here, then on the other phone tap Join a friend.\n\n%@", AppVersion()];
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

- (void)join {
   [self.navigationController pushViewController:[JoinViewController new] animated:YES];
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
