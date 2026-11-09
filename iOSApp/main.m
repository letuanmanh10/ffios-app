#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach_time.h>

// =============================================================================
// IOKit Private Types and Function Pointers
// =============================================================================
typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;

typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreate_t)(CFAllocatorRef allocator);
typedef void (*IOHIDEventSystemClientDispatchEvent_t)(IOHIDEventSystemClientRef client, IOHIDEventRef event);

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEvent_t)(
    CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    double x,
    double y,
    double z,
    double tipPressure,
    double twist,
    Boolean range,
    Boolean touch,
    uint32_t options
);

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEvent_t)(
    CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint32_t type,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    uint32_t buttonMask,
    double x,
    double y,
    double z,
    double tipPressure,
    double barrelPressure,
    Boolean range,
    Boolean touch,
    uint32_t options
);

static IOHIDEventSystemClientRef g_hidClient = NULL;
static IOHIDEventSystemClientDispatchEvent_t g_hidDispatch = NULL;
static IOHIDEventCreateDigitizerFingerEvent_t g_hidFingerEvent = NULL;
static IOHIDEventCreateDigitizerEvent_t g_hidDigitizerEvent = NULL;

static void initTouchInjection(void) {
    void *ioKitHandle = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioKitHandle) {
        ioKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    }
    
    if (ioKitHandle) {
        IOHIDEventSystemClientCreate_t createFunc = (IOHIDEventSystemClientCreate_t)dlsym(ioKitHandle, "IOHIDEventSystemClientCreate");
        g_hidDispatch = (IOHIDEventSystemClientDispatchEvent_t)dlsym(ioKitHandle, "IOHIDEventSystemClientDispatchEvent");
        g_hidFingerEvent = (IOHIDEventCreateDigitizerFingerEvent_t)dlsym(ioKitHandle, "IOHIDEventCreateDigitizerFingerEvent");
        g_hidDigitizerEvent = (IOHIDEventCreateDigitizerEvent_t)dlsym(ioKitHandle, "IOHIDEventCreateDigitizerEvent");
        
        if (createFunc) {
            g_hidClient = createFunc(kCFAllocatorDefault);
            NSLog(@"[Touch] IOHIDEventSystemClient initialized successfully: %p", g_hidClient);
        } else {
            NSLog(@"[Touch] IOHIDEventSystemClientCreate symbol not found");
        }
    } else {
        NSLog(@"[Touch] Failed to dlopen IOKit: %s", dlerror());
    }
}

static void dispatchTouchEvent(int phase, float x, float y) {
    // phase: 0 = Down, 1 = Move, 2 = Up
    if (!g_hidClient || !g_hidDispatch || (!g_hidFingerEvent && !g_hidDigitizerEvent)) {
        NSLog(@"[Touch] Injection failed: IOKit not ready");
        return;
    }
    
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat width = screenBounds.size.width;
    CGFloat height = screenBounds.size.height;
    
    // Normalize coordinates to 0.0 .. 1.0
    double normX = (x > 1.0f) ? ((double)x / (double)width) : (double)x;
    double normY = (y > 1.0f) ? ((double)y / (double)height) : (double)y;
    
    if (normX < 0.0) normX = 0.0;
    if (normX > 1.0) normX = 1.0;
    if (normY < 0.0) normY = 0.0;
    if (normY > 1.0) normY = 1.0;
    
    uint64_t ts = mach_absolute_time();
    uint32_t mask = 0;
    Boolean isTouch = false;
    Boolean isRange = false;
    double pressure = 0.0;
    
    if (phase == 0) { // Touch Down
        mask = (1 << 0) | (1 << 1) | (1 << 2); // range, touch, position
        isTouch = true;
        isRange = true;
        pressure = 1.0;
    } else if (phase == 1) { // Touch Move
        mask = (1 << 0) | (1 << 1) | (1 << 2);
        isTouch = true;
        isRange = true;
        pressure = 1.0;
    } else { // Touch Up
        mask = (1 << 0) | (1 << 1);
        isTouch = false;
        isRange = false;
        pressure = 0.0;
    }
    
    IOHIDEventRef event = NULL;
    if (g_hidFingerEvent) {
        event = g_hidFingerEvent(kCFAllocatorDefault, ts, 0, 2, mask, normX, normY, 0.0, pressure, 0.0, isRange, isTouch, 0);
    } else if (g_hidDigitizerEvent) {
        event = g_hidDigitizerEvent(kCFAllocatorDefault, ts, 3, 0, 2, mask, 0, normX, normY, 0.0, pressure, 0.0, isRange, isTouch, 0);
    }
    
    if (event) {
        g_hidDispatch(g_hidClient, event);
        CFRelease(event);
    }
}

static void injectTouchTap(float x, float y) {
    // Touch Down
    dispatchTouchEvent(0, x, y);
    // Short dwell time (15ms)
    usleep(15000);
    // Touch Up
    dispatchTouchEvent(2, x, y);
}

// =============================================================================
// Streamer Engine & TCP Server
// =============================================================================
@interface StreamerServer : NSObject
@property (nonatomic, assign) int serverSocket;
@property (nonatomic, assign) int clientSocket;
@property (nonatomic, assign) volatile BOOL isSendingFrame;
@property (nonatomic, assign) uint64_t totalFramesSent;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, copy) void (^onStatusUpdate)(NSString *statusText);

+ (instancetype)sharedServer;
- (void)startOnPort:(int)port;
- (void)stop;
- (void)captureFrame:(CADisplayLink *)link;
@end

@implementation StreamerServer

+ (instancetype)sharedServer {
    static StreamerServer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[StreamerServer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _clientSocket = -1;
        _isSendingFrame = NO;
        _totalFramesSent = 0;
    }
    return self;
}

- (void)startOnPort:(int)port {
    initTouchInjection();
    
    // Start CADisplayLink on Main Thread
    dispatch_async(dispatch_get_main_queue(), ^{
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(captureFrame:)];
        if (@available(iOS 15.0, *)) {
            self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0, 60.0, 60.0);
        } else {
            self.displayLink.preferredFramesPerSecond = 60;
        }
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        NSLog(@"[Streamer] CADisplayLink scheduled on Main RunLoop");
    });
    
    // Start TCP Server on Background Dispatch Queue
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd < 0) {
            NSLog(@"[Socket] Failed to create socket: %s", strerror(errno));
            return;
        }
        
        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = INADDR_ANY;
        address.sin_port = htons(port);
        
        if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
            NSLog(@"[Socket] Bind failed on port %d: %s", port, strerror(errno));
            close(server_fd);
            return;
        }
        
        if (listen(server_fd, 5) < 0) {
            NSLog(@"[Socket] Listen failed: %s", strerror(errno));
            close(server_fd);
            return;
        }
        
        self.serverSocket = server_fd;
        NSLog(@"[Socket] Listening for connections on 0.0.0.0:%d", port);
        if (self.onStatusUpdate) {
            self.onStatusUpdate([NSString stringWithFormat:@"Listening on port %d (USB/LAN)", port]);
        }
        
        while (self.serverSocket >= 0) {
            struct sockaddr_in clientAddr;
            socklen_t addrLen = sizeof(clientAddr);
            int newClient = accept(self.serverSocket, (struct sockaddr *)&clientAddr, &addrLen);
            if (newClient < 0) {
                if (self.serverSocket < 0) break;
                continue;
            }
            
            NSLog(@"[Socket] Client connected: %s:%d", inet_ntoa(clientAddr.sin_addr), ntohs(clientAddr.sin_port));
            if (self.clientSocket >= 0) {
                close(self.clientSocket);
            }
            self.clientSocket = newClient;
            
            if (self.onStatusUpdate) {
                self.onStatusUpdate([NSString stringWithFormat:@"Connected to %s:%d", inet_ntoa(clientAddr.sin_addr), ntohs(clientAddr.sin_port)]);
            }
            
            // Read Loop for incoming Touch Commands ("X,Y" or "PHASE,X,Y")
            char buffer[2048];
            char lineBuf[256];
            int linePos = 0;
            
            while (self.clientSocket >= 0) {
                ssize_t bytesRead = recv(self.clientSocket, buffer, sizeof(buffer) - 1, 0);
                if (bytesRead <= 0) {
                    NSLog(@"[Socket] Client disconnected");
                    close(self.clientSocket);
                    self.clientSocket = -1;
                    if (self.onStatusUpdate) {
                        self.onStatusUpdate([NSString stringWithFormat:@"Listening on port %d", port]);
                    }
                    break;
                }
                
                for (int i = 0; i < bytesRead; i++) {
                    char c = buffer[i];
                    if (c == '\n' || c == '\r' || c == '\0') {
                        if (linePos > 0) {
                            lineBuf[linePos] = '\0';
                            
                            // Parse commands
                            char cmd = 0;
                            float x = 0.0f, y = 0.0f;
                            if (sscanf(lineBuf, "%c,%f,%f", &cmd, &x, &y) == 3 && (cmd == 'D' || cmd == 'M' || cmd == 'U')) {
                                int phase = (cmd == 'D') ? 0 : ((cmd == 'M') ? 1 : 2);
                                dispatchTouchEvent(phase, x, y);
                            } else if (sscanf(lineBuf, "%f,%f", &x, &y) == 2) {
                                injectTouchTap(x, y);
                            }
                            linePos = 0;
                        }
                    } else {
                        if (linePos < sizeof(lineBuf) - 1) {
                            lineBuf[linePos++] = c;
                        }
                    }
                }
            }
        }
    });
}

- (void)stop {
    if (self.clientSocket >= 0) {
        close(self.clientSocket);
        self.clientSocket = -1;
    }
    if (self.serverSocket >= 0) {
        close(self.serverSocket);
        self.serverSocket = -1;
    }
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
}

// CADisplayLink Selector: captures entire SpringBoard screen in background on jailbroken iOS
- (void)captureFrame:(CADisplayLink *)link {
    if (self.clientSocket < 0 || self.isSendingFrame) {
        return; // Drop frame to maintain lowest latency buffer
    }
    
    // Keep CADisplayLink active when minimized / app transitions to background
    if (link && link.isPaused) {
        link.paused = NO;
    }
    
    // Hold background execution assertion to prevent iOS background suspension
    static UIBackgroundTaskIdentifier s_bgTask = UIBackgroundTaskInvalid;
    if (s_bgTask == UIBackgroundTaskInvalid) {
        s_bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [[UIApplication sharedApplication] endBackgroundTask:s_bgTask];
            s_bgTask = UIBackgroundTaskInvalid;
        }];
    }
    
    // Dynamic binding for jailbreak system-wide screen capture APIs
    typedef UIImage *(*UICreateScreenUIImage_t)(void);
    typedef void *IOMobileFramebufferRef;
    typedef kern_return_t (*IOMFBGetMainDisplay_t)(IOMobileFramebufferRef *connection);
    typedef kern_return_t (*IOMFBGetLayerDefaultSurface_t)(IOMobileFramebufferRef connection, int surface, void **surfaceOut);
    
    static UICreateScreenUIImage_t s_UICreateScreenUIImage = NULL;
    static IOMFBGetMainDisplay_t s_IOMFBGetMainDisplay = NULL;
    static IOMFBGetLayerDefaultSurface_t s_IOMFBGetLayerDefaultSurface = NULL;
    static IOMobileFramebufferRef s_fbConnection = NULL;
    static dispatch_once_t s_initCaptureToken;
    
    dispatch_once(&s_initCaptureToken, ^{
        // 1. Resolve _UICreateScreenUIImage (Private UIKit / GraphicsServices compositor capture)
        s_UICreateScreenUIImage = (UICreateScreenUIImage_t)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        if (!s_UICreateScreenUIImage) {
            void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
            if (uikit) {
                s_UICreateScreenUIImage = (UICreateScreenUIImage_t)dlsym(uikit, "_UICreateScreenUIImage");
            }
        }
        
        // 2. Resolve IOMobileFramebuffer / IOSurface hardware capture
        void *iomfb = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
        if (iomfb) {
            s_IOMFBGetMainDisplay = (IOMFBGetMainDisplay_t)dlsym(iomfb, "IOMobileFramebufferGetMainDisplay");
            s_IOMFBGetLayerDefaultSurface = (IOMFBGetLayerDefaultSurface_t)dlsym(iomfb, "IOMobileFramebufferGetLayerDefaultSurface");
            if (s_IOMFBGetMainDisplay) {
                s_IOMFBGetMainDisplay(&s_fbConnection);
            }
        }
    });
    
    UIImage *screenshot = nil;
    
    // Method 1: System-wide Screen Capture via _UICreateScreenUIImage (captures SpringBoard + Free Fire in background)
    if (s_UICreateScreenUIImage) {
        screenshot = s_UICreateScreenUIImage();
    }
    
    // Method 2: Hardware Framebuffer Surface Capture via IOMobileFramebuffer / IOSurface
    if (!screenshot && s_IOMFBGetLayerDefaultSurface && s_fbConnection) {
        void *ioSurface = NULL;
        if (s_IOMFBGetLayerDefaultSurface(s_fbConnection, 0, &ioSurface) == KERN_SUCCESS && ioSurface) {
            CIImage *ci = [CIImage imageWithIOSurface:(IOSurfaceRef)ioSurface];
            if (ci) {
                static CIContext *s_ciContext = nil;
                if (!s_ciContext) {
                    s_ciContext = [CIContext contextWithOptions:nil];
                }
                CGImageRef cg = [s_ciContext createCGImage:ci fromRect:ci.extent];
                if (cg) {
                    screenshot = [UIImage imageWithCGImage:cg];
                    CGImageRelease(cg);
                }
            }
        }
    }
    
    // Method 3: Fallback for local view hierarchy if private symbols are restricted
    if (!screenshot) {
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window && [UIApplication sharedApplication].windows.count > 0) {
            window = [UIApplication sharedApplication].windows.firstObject;
        }
        if (window && window.bounds.size.width > 0 && window.bounds.size.height > 0) {
            UIGraphicsBeginImageContextWithOptions(window.bounds.size, NO, 0.5);
            [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
            screenshot = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
    }
    
    if (!screenshot) return;
    
    self.isSendingFrame = YES;
    int clientFd = self.clientSocket;
    
    // Encode JPEG and transmit on high-priority background queue
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @autoreleasepool {
            NSData *jpegData = UIImageJPEGRepresentation(screenshot, 0.3);
            if (jpegData && jpegData.length > 0 && clientFd >= 0 && clientFd == self.clientSocket) {
                uint32_t len = (uint32_t)jpegData.length;
                uint32_t leLength = OSSwapHostToLittleInt32(len); // Little-endian 4 bytes length prefix (<I)
                
                // Transmit 4-byte length prefix
                ssize_t sentHeader = send(clientFd, &leLength, sizeof(leLength), 0);
                if (sentHeader == sizeof(leLength)) {
                    // Transmit JPEG payload
                    const char *dataPtr = (const char *)jpegData.bytes;
                    size_t bytesRemaining = len;
                    BOOL sendFailed = NO;
                    
                    while (bytesRemaining > 0 && self.clientSocket == clientFd) {
                        ssize_t n = send(clientFd, dataPtr, bytesRemaining, 0);
                        if (n <= 0) {
                            sendFailed = YES;
                            break;
                        }
                        dataPtr += n;
                        bytesRemaining -= n;
                    }
                    
                    if (sendFailed) {
                        NSLog(@"[Socket] Error writing frame to client");
                        close(clientFd);
                        if (self.clientSocket == clientFd) self.clientSocket = -1;
                    } else {
                        self.totalFramesSent++;
                    }
                } else {
                    NSLog(@"[Socket] Failed to send length header");
                    close(clientFd);
                    if (self.clientSocket == clientFd) self.clientSocket = -1;
                }
            }
            self.isSendingFrame = NO;
        }
    });
}

@end

// =============================================================================
// Main UI View Controller
// =============================================================================
@interface MainViewController : UIViewController
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *statsLabel;
@property (nonatomic, strong) UILabel *guideLabel;
@property (nonatomic, strong) NSTimer *statsTimer;
@end

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:1.0];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    CGFloat screenW = self.view.bounds.size.width;
    
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, screenW - 40, 40)];
    self.titleLabel.text = @"⚡ FF iOS Streamer";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    self.titleLabel.textColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.55 alpha:1.0];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.titleLabel];
    
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 110, screenW - 40, 30)];
    self.statusLabel.text = @"Initializing Server...";
    self.statusLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.statusLabel];
    
    self.statsLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 150, screenW - 40, 24)];
    self.statsLabel.text = @"Frames Sent: 0 | Latency: Realtime";
    self.statsLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    self.statsLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.statsLabel.textAlignment = NSTextAlignmentCenter;
    self.statsLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.statsLabel];
    
    self.guideLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 200, screenW - 48, 260)];
    self.guideLabel.numberOfLines = 0;
    self.guideLabel.font = [UIFont fontWithName:@"Menlo" size:13];
    self.guideLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    self.guideLabel.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.6];
    self.guideLabel.layer.cornerRadius = 10;
    self.guideLabel.layer.masksToBounds = YES;
    self.guideLabel.text = @"\n"
                           " [CONFIGURATION]\n"
                           " - Port: 8080 (TCP)\n"
                           " - Target Device: iPhone 7 (iOS 15.8.3)\n"
                           " - Screen Resolution: 750x1334\n"
                           " - Compression: JPEG (q=0.3, scale=0.5)\n"
                           " - Input: IOHIDEvent Touch Injection\n\n"
                           " [USB CONNECTION COMMAND]\n"
                           " Run on Windows PC:\n"
                           " > iproxy 8080 8080\n"
                           " > python pc_client.py\n";
    self.guideLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.guideLabel];
    
    __weak typeof(self) weakSelf = self;
    [StreamerServer sharedServer].onStatusUpdate = ^(NSString *statusText) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.statusLabel.text = statusText;
        });
    };
    
    [[StreamerServer sharedServer] startOnPort:8080];
    
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateStats) userInfo:nil repeats:YES];
}

- (void)updateStats {
    uint64_t frames = [StreamerServer sharedServer].totalFramesSent;
    self.statsLabel.text = [NSString stringWithFormat:@"Frames Sent: %llu | Engine: Active", frames];
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end

// =============================================================================
// App Delegate & Entry Point
// =============================================================================
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[MainViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
