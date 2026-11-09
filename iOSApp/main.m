#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach_time.h>

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;

typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreate_t)(CFAllocatorRef allocator);
typedef void (*IOHIDEventSystemClientDispatchEvent_t)(IOHIDEventSystemClientRef client, IOHIDEventRef event);

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEvent_t)(
    CFAllocatorRef allocator, uint64_t timeStamp, uint32_t index, uint32_t identity, uint32_t eventMask,
    double x, double y, double z, double tipPressure, double twist, Boolean range, Boolean touch, uint32_t options
);

static IOHIDEventSystemClientRef g_hidClient = NULL;
static IOHIDEventSystemClientDispatchEvent_t g_hidDispatch = NULL;
static IOHIDEventCreateDigitizerFingerEvent_t g_hidFingerEvent = NULL;

static void initTouchInjection(void) {
    void *ioKitHandle = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioKitHandle) ioKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    
    if (ioKitHandle) {
        IOHIDEventSystemClientCreate_t createFunc = (IOHIDEventSystemClientCreate_t)dlsym(ioKitHandle, "IOHIDEventSystemClientCreate");
        g_hidDispatch = (IOHIDEventSystemClientDispatchEvent_t)dlsym(ioKitHandle, "IOHIDEventSystemClientDispatchEvent");
        g_hidFingerEvent = (IOHIDEventCreateDigitizerFingerEvent_t)dlsym(ioKitHandle, "IOHIDEventCreateDigitizerFingerEvent");
        
        if (createFunc) g_hidClient = createFunc(kCFAllocatorDefault);
    }
}

static void dispatchTouchEvent(int phase, float x, float y) {
    if (!g_hidClient || !g_hidDispatch || !g_hidFingerEvent) return;
    
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    double normX = (x > 1.0f) ? ((double)x / screenBounds.size.width) : (double)x;
    double normY = (y > 1.0f) ? ((double)y / screenBounds.size.height) : (double)y;
    
    if (normX < 0.0) normX = 0.0; if (normX > 1.0) normX = 1.0;
    if (normY < 0.0) normY = 0.0; if (normY > 1.0) normY = 1.0;
    
    uint64_t ts = mach_absolute_time();
    uint32_t mask = (1 << 0) | (1 << 1) | (1 << 2);
    Boolean isTouch = (phase != 2);
    Boolean isRange = (phase != 2);
    double pressure = (phase != 2) ? 1.0 : 0.0;
    
    IOHIDEventRef event = g_hidFingerEvent(kCFAllocatorDefault, ts, 0, 2, mask, normX, normY, 0.0, pressure, 0.0, isRange, isTouch, 0);
    if (event) {
        g_hidDispatch(g_hidClient, event);
        CFRelease(event);
    }
}

static void injectTouchTap(float x, float y) {
    dispatchTouchEvent(0, x, y);
    usleep(15000);
    dispatchTouchEvent(2, x, y);
}

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
    dispatch_once(&onceToken, ^{ instance = [[StreamerServer alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) { _serverSocket = -1; _clientSocket = -1; _isSendingFrame = NO; _totalFramesSent = 0; }
    return self;
}

- (void)startOnPort:(int)port {
    initTouchInjection();
    dispatch_async(dispatch_get_main_queue(), ^{
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(captureFrame:)];
        if (@available(iOS 15.0, *)) self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0, 60.0, 60.0);
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int server_fd = socket(AF_INET, SOCK_STREAM, 0);
        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = INADDR_ANY;
        address.sin_port = htons(port);
        
        if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) { close(server_fd); return; }
        if (listen(server_fd, 5) < 0) { close(server_fd); return; }
        
        self.serverSocket = server_fd;
        if (self.onStatusUpdate) self.onStatusUpdate([NSString stringWithFormat:@"Listening on port %d", port]);
        
        while (self.serverSocket >= 0) {
            struct sockaddr_in clientAddr;
            socklen_t addrLen = sizeof(clientAddr);
            int newClient = accept(self.serverSocket, (struct sockaddr *)&clientAddr, &addrLen);
            if (newClient < 0) continue;
            
            if (self.clientSocket >= 0) close(self.clientSocket);
            self.clientSocket = newClient;
            if (self.onStatusUpdate) self.onStatusUpdate(@"Client Connected!");
            
            char buffer[2048]; char lineBuf[256]; int linePos = 0;
            
            while (self.clientSocket >= 0) {
                ssize_t bytesRead = recv(self.clientSocket, buffer, sizeof(buffer) - 1, 0);
                if (bytesRead <= 0) { close(self.clientSocket); self.clientSocket = -1; if (self.onStatusUpdate) self.onStatusUpdate(@"Listening..."); break; }
                
                for (int i = 0; i < bytesRead; i++) {
                    char c = buffer[i];
                    if (c == '\n' || c == '\r' || c == '\0') {
                        if (linePos > 0) {
                            lineBuf[linePos] = '\0';
                            char cmd = 0; float x = 0.0f, y = 0.0f;
                            if (sscanf(lineBuf, "%c,%f,%f", &cmd, &x, &y) == 3 && (cmd == 'D' || cmd == 'M' || cmd == 'U')) {
                                dispatchTouchEvent((cmd == 'D') ? 0 : ((cmd == 'M') ? 1 : 2), x, y);
                            } else if (sscanf(lineBuf, "%f,%f", &x, &y) == 2) {
                                injectTouchTap(x, y);
                            }
                            linePos = 0;
                        }
                    } else {
                        if (linePos < sizeof(lineBuf) - 1) lineBuf[linePos++] = c;
                    }
                }
            }
        }
    });
}

- (void)stop {
    if (self.clientSocket >= 0) { close(self.clientSocket); self.clientSocket = -1; }
    if (self.serverSocket >= 0) { close(self.serverSocket); self.serverSocket = -1; }
    if (self.displayLink) { [self.displayLink invalidate]; self.displayLink = nil; }
}

- (void)captureFrame:(CADisplayLink *)link {
    if (self.clientSocket < 0 || self.isSendingFrame) return;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window && [UIApplication sharedApplication].windows.count > 0) window = [UIApplication sharedApplication].windows.firstObject;
    if (!window) return;
    
    CGSize boundsSize = window.bounds.size;
    if (boundsSize.width <= 0 || boundsSize.height <= 0) return;
    
    UIGraphicsBeginImageContextWithOptions(boundsSize, NO, 0.5);
    [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    UIImage *screenshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!screenshot) return;
    
    self.isSendingFrame = YES;
    int clientFd = self.clientSocket;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @autoreleasepool {
            NSData *jpegData = UIImageJPEGRepresentation(screenshot, 0.3);
            if (jpegData && jpegData.length > 0 && clientFd >= 0 && clientFd == self.clientSocket) {
                uint32_t len = (uint32_t)jpegData.length;
                uint32_t leLength = OSSwapHostToLittleInt32(len);
                if (send(clientFd, &leLength, sizeof(leLength), 0) == sizeof(leLength)) {
                    const char *dataPtr = (const char *)jpegData.bytes;
                    size_t bytesRemaining = len;
                    while (bytesRemaining > 0 && self.clientSocket == clientFd) {
                        ssize_t n = send(clientFd, dataPtr, bytesRemaining, 0);
                        if (n <= 0) break;
                        dataPtr += n; bytesRemaining -= n;
                    }
                    self.totalFramesSent++;
                }
            }
            self.isSendingFrame = NO;
        }
    });
}
@end

@interface MainViewController : UIViewController
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSTimer *statsTimer;
@end

@implementation MainViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:1.0];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, self.view.bounds.size.width - 40, 40)];
    title.text = @"⚡ FF iOS Streamer"; title.font = [UIFont boldSystemFontOfSize:24];
    title.textColor = [UIColor greenColor]; title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];
    
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 110, self.view.bounds.size.width - 40, 30)];
    self.statusLabel.text = @"Initializing Server..."; self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.statusLabel];
    
    __weak typeof(self) weakSelf = self;
    [StreamerServer sharedServer].onStatusUpdate = ^(NSString *statusText) {
        dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.statusLabel.text = statusText; });
    };
    [[StreamerServer sharedServer] startOnPort:8080];
}
@end

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