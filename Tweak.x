// ==============================================================================
// 软件名称: 守护天使AN (Angel Guardian AN v5.1.0 - 稳定防崩全双工实时音视频流版)
// 核心架构升级:
// 1. 🎙️纯正Live模式: 解除录音阻断死锁，独立麦克风声波反馈 + 动态VAD全双工推流，官方真人原声对讲
// 2. 📹独立视频AI模式: 硬件帧直绘 + 1FPS实景视讯，高频回路全流程@autoreleasepool显存保护，彻底根治Jetsam强杀SafeMode
// 3. 💬纯文本模式: SSE流式打字 + 多轮上下文记忆 + 自动化控制
// 4. 动态模型引擎: 拒绝写死！API动态能力嗅探 + 语义版本降序排序，自动筛选最新Top 5真实可用模型
// 5. 进程安全架构: 废除暴力killall -9 assistantd，纯运行时安全接管，彻底杜绝SpringBoard黑屏注销
// ==============================================================================

#import <objc/runtime.h>
#import <dlfcn.h>
#import <spawn.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <Contacts/Contacts.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>

extern char **environ;

typedef NS_ENUM(NSInteger, AGConfigTab) {
    AGConfigTabNativeLive = 0, // 🎙️ 纯正 Live 实时双向语音流
    AGConfigTabVideoAI    = 1, // 📹 独立视频 AI 实时摄像头+语音流
    AGConfigTabPureText   = 2  // 💬 纯文本打字流式交流
};

static NSString * const kAGPrefsChangedNotification = @"com.custom.geminisirioverlay.prefsChanged";
static NSMutableDictionary *gCachedPrefs = nil;

static void safelyDismissNativeSiriIfVisible(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SBAssistantController *ac = [%c(SBAssistantController) sharedInstance];
        if (ac) {
            if ([ac respondsToSelector:@selector(dismissAssistantViewIfNecessaryWithAnimation:)]) {
                [ac dismissAssistantViewIfNecessaryWithAnimation:0];
            } else if ([ac respondsToSelector:@selector(dismissAssistantViewIfNecessary)]) {
                [ac dismissAssistantViewIfNecessary];
            }
        }
    });
}

typedef Boolean (*MRMediaRemoteSendCommandFunc)(uint32_t command, void *userInfo);
static void pauseBackgroundMediaPlayback(void) {
    static MRMediaRemoteSendCommandFunc sendCmd = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (handle) {
            sendCmd = (MRMediaRemoteSendCommandFunc)dlsym(handle, "MRMediaRemoteSendCommand");
        }
    });
    if (sendCmd) {
        sendCmd(1, NULL); // kMRPause = 1
    }
}

// ==================== 跨进程共享配置 ====================
static NSString *geminiPrefsFilePath(void) {
    NSArray *paths = @[
        @"/var/jb/var/mobile/Library/Preferences/com.custom.geminisirioverlay.plist",
        @"/var/mobile/Library/Preferences/com.custom.geminisirioverlay.plist"
    ];
    for (NSString *p in paths) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            return p;
        }
    }
    return @"/var/mobile/Library/Preferences/com.custom.geminisirioverlay.plist";
}

static void reloadGeminiPrefsCache(void) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:geminiPrefsFilePath()];
    if (!dict) dict = [NSMutableDictionary dictionary];
    gCachedPrefs = dict;
}

static NSMutableDictionary *loadGeminiPrefs(void) {
    if (!gCachedPrefs) {
        reloadGeminiPrefsCache();
    }
    return [gCachedPrefs mutableCopy];
}

static void saveGeminiPrefs(NSDictionary *dict) {
    if (!dict) return;
    gCachedPrefs = [dict mutableCopy];
    [dict writeToFile:geminiPrefsFilePath() atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kAGPrefsChangedNotification,
                                         NULL, NULL, YES);
}

// ==================== 系统私有接口声明 ====================
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

@interface SpringBoard : UIApplication
- (BOOL)isLocked;
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstanceIfExists;
@property (readonly, nonatomic) BOOL isUILocked;
@end

@interface SBAssistantController : NSObject
+ (instancetype)sharedInstance;
+ (BOOL)isVisible;
- (void)dismissAssistantViewIfNecessary;
- (void)dismissAssistantViewIfNecessaryWithAnimation:(NSInteger)anim;
@end

@interface SiriPresentationSpringBoardMainScreenViewController : UIViewController
- (void)dismissSiriViewController:(id)arg1;
- (void)dismissSiriViewController:(id)arg1 withReason:(NSUInteger)reason;
@end

@interface UIWindow (Private)
- (void)_setSecure:(BOOL)secure;
@end

static BOOL isDeviceCurrentlyLocked(void) {
    Class lsmClass = objc_getClass("SBLockScreenManager");
    if (lsmClass && [lsmClass respondsToSelector:@selector(sharedInstanceIfExists)]) {
        SBLockScreenManager *lsm = [lsmClass sharedInstanceIfExists];
        if (lsm && [lsm respondsToSelector:@selector(isUILocked)]) {
            return [lsm isUILocked];
        }
    }
    SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
    if ([sb respondsToSelector:@selector(isLocked)]) {
        return [sb isLocked];
    }
    return NO;
}

static CGFloat adaptiveScreenCornerRadius(CGRect bounds) {
    CGFloat maxDim = MAX(bounds.size.width, bounds.size.height);
    CGFloat minDim = MIN(bounds.size.width, bounds.size.height);
    if (maxDim >= 950.0 || minDim >= 440.0) return 55.0; // iPhone 16/17/18 Pro Max
    if (maxDim >= 926.0 || minDim >= 428.0) return 51.0; // iPhone 12~15 Pro Max
    if (maxDim >= 870.0 || minDim >= 402.0) return 53.0; // iPhone 16~18 Pro
    if (maxDim >= 812.0) return 47.0;
    return 16.0;
}

// ==================== 三大独立模块的开关与配置读写 ====================
static NSString *agPrefixForTab(AGConfigTab tab) {
    switch (tab) {
        case AGConfigTabNativeLive: return @"AG_Live";
        case AGConfigTabVideoAI:    return @"AG_Video";
        case AGConfigTabPureText:   return @"AG_Text";
    }
    return @"AG_Live";
}

static BOOL agIsTabEnabled(AGConfigTab tab) {
    NSDictionary *p = loadGeminiPrefs();
    NSString *key = [NSString stringWithFormat:@"%@_Enabled", agPrefixForTab(tab)];
    NSNumber *val = p[key];
    return val ? [val boolValue] : YES;
}

static NSString *agEndpointForTab(AGConfigTab tab) {
    NSDictionary *p = loadGeminiPrefs();
    NSString *key = [NSString stringWithFormat:@"%@_Endpoint", agPrefixForTab(tab)];
    NSString *ep = p[key];
    if (!ep || ep.length < 4) {
        NSString *legacy = p[@"Gemini_Endpoint"];
        if (legacy.length > 5) ep = legacy;
        else ep = @"https://generativelanguage.googleapis.com";
    }
    while ([ep hasSuffix:@"/"]) {
        ep = [ep substringToIndex:ep.length - 1];
    }
    return ep;
}

static NSString *agAPIKeyForTab(AGConfigTab tab) {
    NSDictionary *p = loadGeminiPrefs();
    NSString *key = [NSString stringWithFormat:@"%@_APIKey", agPrefixForTab(tab)];
    NSString *val = p[key];
    if (!val || val.length == 0) {
        val = p[@"AG_Live_APIKey"] ?: (p[@"AG_Text_APIKey"] ?: (p[@"Gemini_APIKey"] ?: @""));
    }
    return val ?: @"";
}

static NSString *agProxyForTab(AGConfigTab tab) {
    NSDictionary *p = loadGeminiPrefs();
    NSString *key = [NSString stringWithFormat:@"%@_ProxyPort", agPrefixForTab(tab)];
    NSString *val = p[key];
    if (!val || val.length == 0) {
        val = p[@"AG_Live_ProxyPort"] ?: (p[@"AG_Text_ProxyPort"] ?: (p[@"Gemini_ProxyPort"] ?: @""));
    }
    return val ?: @"";
}

static NSString *agModelForTab(AGConfigTab tab) {
    NSDictionary *p = loadGeminiPrefs();
    NSString *key = [NSString stringWithFormat:@"%@_Model", agPrefixForTab(tab)];
    NSString *val = p[key];
    if (!val || val.length == 0) {
        if (tab == AGConfigTabPureText) return @"deepseek-chat";
        return @"models/gemini-2.0-flash-exp";
    }
    return val;
}

static NSArray<NSDictionary *> *agCachedModelsForTab(AGConfigTab tab) {
    NSDictionary *p = loadGeminiPrefs();
    NSString *key = [NSString stringWithFormat:@"%@_CachedModels", agPrefixForTab(tab)];
    NSArray *arr = p[key];
    if ([arr isKindOfClass:[NSArray class]] && arr.count > 0) return arr;
    if (tab == AGConfigTabNativeLive) {
        return @[
            @{@"id": @"models/gemini-2.0-flash-exp",          @"title": @"🎙️ gemini-2.0-flash-exp (Google 官方Bidi实时语音流)"},
            @{@"id": @"models/gemini-2.0-flash-realtime-exp", @"title": @"⚡ gemini-2.0-flash-realtime (极速低延迟语音对讲)"},
            @{@"id": @"gpt-4o-realtime-preview",             @"title": @"🌟 gpt-4o-realtime-preview (OpenAI 官方Realtime)"},
            @{@"id": @"gpt-4o-mini-realtime-preview",        @"title": @"🚀 gpt-4o-mini-realtime (轻量极速双向流)"},
            @{@"id": @"qwen-omni-turbo-realtime",            @"title": @"🔥 qwen-omni-turbo-realtime (阿里千问全双工语音)"}
        ];
    } else if (tab == AGConfigTabVideoAI) {
        return @[
            @{@"id": @"models/gemini-2.0-flash-exp",          @"title": @"📹 gemini-2.0-flash-exp (Google 官方实时视讯对讲)"},
            @{@"id": @"models/gemini-2.0-flash-realtime-exp", @"title": @"⚡ gemini-2.0-flash-realtime (低延迟实景画面分析)"},
            @{@"id": @"models/gemini-1.5-flash",              @"title": @"🚀 gemini-1.5-flash (极速多模态视觉)"},
            @{@"id": @"models/gemini-1.5-pro",                @"title": @"🧠 gemini-1.5-pro (深度多模态视觉推理)"},
            @{@"id": @"gpt-4o",                               @"title": @"🌟 gpt-4o (OpenAI 旗舰全景视觉分析)"}
        ];
    }
    return @[
        @{@"id": @"deepseek-chat",                        @"title": @"👑 deepseek-chat (DeepSeek-V3 中文顶配极速通用)"},
        @{@"id": @"deepseek-reasoner",                    @"title": @"🧠 deepseek-reasoner (DeepSeek-R1 深度思考推理)"},
        @{@"id": @"gpt-4o-mini",                          @"title": @"⚡ gpt-4o-mini (OpenAI 极速生活助手)"},
        @{@"id": @"models/gemini-2.0-flash",              @"title": @"🚀 gemini-2.0-flash (Google 官方极速出字)"},
        @{@"id": @"qwen-plus",                            @"title": @"🔥 qwen-plus (通义千问精准意图识别)"}
    ];
}

static BOOL agIsGoogleNativeProtocol(NSString *endpoint, NSString *model) {
    NSString *lowerEP = [endpoint lowercaseString];
    if ([lowerEP containsString:@"googleapis.com"] || [lowerEP containsString:@"v1beta"] || [lowerEP containsString:@"v1alpha"]) {
        if (![lowerEP containsString:@"/v1/chat/completions"] && ![lowerEP containsString:@"openai"]) {
            return YES;
        }
    }
    return NO;
}

static NSURLSession *agCreateSessionWithProxy(NSString *proxyStr, id<NSURLSessionDelegate> delegate, NSOperationQueue *queue) {
    NSString *cleanProxy = [proxyStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30.0;
    if (cleanProxy.length > 0) {
        NSString *host = @"127.0.0.1";
        NSNumber *portNum = nil;
        if ([cleanProxy containsString:@":"]) {
            NSArray *parts = [cleanProxy componentsSeparatedByString:@":"];
            host = parts.firstObject;
            portNum = @([parts.lastObject integerValue]);
        } else {
            portNum = @([cleanProxy integerValue]);
        }
        if ([portNum integerValue] > 0) {
            config.connectionProxyDictionary = @{
                @"HTTPEnable": @YES, @"HTTPProxy": host, @"HTTPPort": portNum,
                @"HTTPSEnable": @YES, @"HTTPSProxy": host, @"HTTPSPort": portNum
            };
        }
    }
    if (delegate) {
        return [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:(queue ?: [NSOperationQueue mainQueue])];
    }
    return [NSURLSession sessionWithConfiguration:config];
}

// ==================== 全平台云端模型拉取引擎 ====================
static void agFetchCloudModelsForTab(AGConfigTab tab, NSString *endpoint, NSString *apiKey, NSString *proxy, void(^completion)(BOOL success, NSArray<NSDictionary *> *models, NSString *errorMsg)) {
    NSString *cleanEP = [endpoint stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([cleanEP hasSuffix:@"/"]) cleanEP = [cleanEP substringToIndex:cleanEP.length - 1];
    NSString *cleanKey = [apiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (cleanEP.length < 5 || cleanKey.length < 5) {
        if (completion) completion(NO, nil, @"请先填写完整的接口地址与 API Key");
        return;
    }

    NSURLSession *session = agCreateSessionWithProxy(proxy, nil, nil);
    BOOL isGoogle = ([cleanEP.lowercaseString containsString:@"googleapis.com"] && ![cleanEP.lowercaseString containsString:@"/openai"]);

    NSString *urlStr = nil;
    NSMutableURLRequest *req = nil;
    if (isGoogle) {
        urlStr = [NSString stringWithFormat:@"%@/v1beta/models?pageSize=100&key=%@", cleanEP, cleanKey];
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    } else {
        if ([cleanEP hasSuffix:@"/v1"]) {
            urlStr = [NSString stringWithFormat:@"%@/models", cleanEP];
        } else if ([cleanEP hasSuffix:@"/v1/chat/completions"]) {
            urlStr = [[cleanEP stringByReplacingOccurrencesOfString:@"/v1/chat/completions" withString:@"/v1/models"] copy];
        } else {
            urlStr = [NSString stringWithFormat:@"%@/v1/models", cleanEP];
        }
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", cleanKey] forHTTPHeaderField:@"Authorization"];
    }
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 15.0;

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, err.localizedDescription ?: @"网络连接失败，请检查代理端口");
            });
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *rawModels = json[@"models"] ?: json[@"data"];
        if (![rawModels isKindOfClass:[NSArray class]] || rawModels.count == 0) {
            NSString *errMsg = json[@"error"][@"message"] ?: @"接口未返回模型列表，请检查 Key 或地址";
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, errMsg);
            });
            return;
        }

        NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];

        for (NSDictionary *m in rawModels) {
            if (![m isKindOfClass:[NSDictionary class]]) continue;
            NSString *mID = m[@"name"] ?: m[@"id"];
            if (!mID || mID.length == 0 || [seen containsObject:mID]) continue;

            NSString *lower = [mID lowercaseString];
            if ([lower containsString:@"embedding"] || [lower containsString:@"rerank"] ||
                [lower containsString:@"moderation"] || [lower containsString:@"dall-e"] ||
                [lower containsString:@"imagen"] || [lower containsString:@"veo"] ||
                [lower containsString:@"bison"] || [lower containsString:@"gecko"] ||
                [lower containsString:@"aqa"] || [lower containsString:@"whisper"] ||
                [lower containsString:@"tts"]) {
                continue;
            }

            BOOL matched = NO;
            NSArray *bidiMethods = m[@"supportedGenerationMethods"];
            BOOL supportsBidi = ([bidiMethods isKindOfClass:[NSArray class]] && [bidiMethods containsObject:@"bidiGenerateContent"]);
            BOOL supportsGenerate = ([bidiMethods isKindOfClass:[NSArray class]] && [bidiMethods containsObject:@"generateContent"]);

            if (tab == AGConfigTabNativeLive) {
                // 必须真实支持 WebSocket 双向实时全双工语音流
                if (supportsBidi || [lower containsString:@"realtime"] || [lower containsString:@"omni-turbo"] || [lower containsString:@"flash-exp"] || [lower containsString:@"realtime-exp"]) {
                    matched = YES;
                }
            } else if (tab == AGConfigTabVideoAI) {
                // 必须真实支持多模态视觉处理或实景视讯流
                if (supportsBidi || [lower containsString:@"vision"] || [lower containsString:@"-vl"] || [lower containsString:@"4o"] || [lower containsString:@"flash-exp"] || [lower containsString:@"gemini-1.5"] || [lower containsString:@"gemini-2.0"] || [lower containsString:@"glm-4v"]) {
                    matched = YES;
                }
            } else {
                // 纯文本模式：支持标准流式生成对话
                if (isGoogle) {
                    if (supportsGenerate || [lower containsString:@"gemini"] || [lower containsString:@"flash"] || [lower containsString:@"pro"]) {
                        matched = YES;
                    }
                } else {
                    matched = YES;
                }
            }

            if (matched) {
                [seen addObject:mID];
                NSString *shortName = [mID stringByReplacingOccurrencesOfString:@"models/" withString:@""];
                NSString *icon = (tab == AGConfigTabNativeLive) ? @"🎙️" : (tab == AGConfigTabVideoAI ? @"📹" : @"💬");
                NSNumber *created = m[@"created"];
                [filtered addObject:@{
                    @"id": mID,
                    @"title": [NSString stringWithFormat:@"%@ %@", icon, shortName],
                    @"created": created ?: @(0),
                    @"rawID": shortName
                }];
            }
        }

        // 语义版本倒序排序引擎：自动识别版本号与发布时间，确保未来出到 4.0、8.0 永远置顶最新
        [filtered sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
            NSNumber *c1 = obj1[@"created"];
            NSNumber *c2 = obj2[@"created"];
            if ([c1 longLongValue] > 0 && [c2 longLongValue] > 0 && ![c1 isEqualToNumber:c2]) {
                return [c2 compare:c1]; // 时间越近排在越前
            }

            NSString *s1 = obj1[@"rawID"];
            NSString *s2 = obj2[@"rawID"];

            BOOL p1 = ([s1 containsString:@"latest"] || [s1 containsString:@"exp"] || [s1 containsString:@"preview"]);
            BOOL p2 = ([s2 containsString:@"latest"] || [s2 containsString:@"exp"] || [s2 containsString:@"preview"]);
            if (p1 != p2) return p1 ? NSOrderedAscending : NSOrderedDescending;

            NSRegularExpression *numRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+(?:\\.\\d+)*)" options:0 error:nil];
            NSTextCheckingResult *r1 = [numRegex firstMatchInString:s1 options:0 range:NSMakeRange(0, s1.length)];
            NSTextCheckingResult *r2 = [numRegex firstMatchInString:s2 options:0 range:NSMakeRange(0, s2.length)];
            if (r1 && r2) {
                NSString *v1 = [s1 substringWithRange:[r1 rangeAtIndex:1]];
                NSString *v2 = [s2 substringWithRange:[r2 rangeAtIndex:1]];
                NSComparisonResult cmp = [v1 compare:v2 options:NSNumericSearch];
                if (cmp != NSOrderedSame) {
                    return (cmp == NSOrderedDescending) ? NSOrderedAscending : NSOrderedDescending;
                }
            }
            return [s1 compare:s2];
        }];

        // 精准截取最新 Top 5
        NSArray *finalList = (filtered.count > 5) ? [filtered subarrayWithRange:NSMakeRange(0, 5)] : filtered;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (finalList.count == 0) {
                if (completion) completion(NO, nil, (tab == AGConfigTabNativeLive) ? @"⚠️ 该 API 暂未检测到支持 Live 实时双向流的专用模型" : @"未检测到可用对话模型");
            } else {
                if (completion) completion(YES, finalList, nil);
            }
        });
    }] resume];
}

// ==================== 1. 防穿透窗口 ====================
@interface GeminiPassthroughWindow : UIWindow
@property (nonatomic, strong) UIView *capsuleWrapper;
@property (nonatomic, assign) BOOL lockFullScreenTouch;
@end

@implementation GeminiPassthroughWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.05 || !self.capsuleWrapper) return NO;
    if (self.lockFullScreenTouch) return YES;
    CGPoint p = [self convertPoint:point toView:self.capsuleWrapper];
    return [self.capsuleWrapper pointInside:p withEvent:event];
}
- (BOOL)_canBecomeKeyWindow { return YES; }
@end

// ==================== 2. 核心控制器 (天使守护 v5.0 真·WebSocket 实时流引擎) ====================
@interface GeminiAssistantManager : NSObject <AVSpeechSynthesizerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, UITextFieldDelegate, UITableViewDelegate, UITableViewDataSource, NSURLSessionDataDelegate, NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) GeminiPassthroughWindow *overlayWindow;
@property (nonatomic, weak) UIWindow *previousKeyWindow;

@property (nonatomic, strong) UIView *edgeGlowContainer;
@property (nonatomic, strong) CAGradientLayer *screenNeonLayer;
@property (nonatomic, strong) UIVisualEffectView *cardBlurView;
@property (nonatomic, strong) CAGradientLayer *ambientLayer;
@property (nonatomic, strong) CAGradientLayer *borderGrad;
@property (nonatomic, strong) CAShapeLayer *borderMask;

@property (nonatomic, strong) UIView *aiOrbView;
@property (nonatomic, strong) UILabel *titleMaskLabel;
@property (nonatomic, strong) CAGradientLayer *titleGradientLayer;
@property (nonatomic, strong) UILabel *modeBadgeLabel;
@property (nonatomic, strong) NSMutableArray<UIView *> *waveBars;

@property (nonatomic, strong) UIView *innerGlassBox;
@property (nonatomic, strong) UILabel *subStatusLabel;
@property (nonatomic, strong) UITextView *responseTextView;
@property (nonatomic, strong) UILabel *actionBannerLabel;

// 底部三大模式切换按钮
@property (nonatomic, strong) UIButton *liveModeButton;   // 🎙️ 纯正 Live 模式
@property (nonatomic, strong) UIButton *videoModeButton;  // 📹 独立视频 AI 模式
@property (nonatomic, strong) UIButton *textModeButton;   // 💬 纯文本模式
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *sendBtn;

@property (nonatomic, assign) AGConfigTab activeModeTab;

// 📹 实景摄像头画中画 + 1FPS 连续视频帧推流器
@property (nonatomic, strong) UIView *cameraPreviewContainer;
@property (nonatomic, strong) UIImageView *cameraLiveImageView;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *cameraPreviewLayer;
@property (nonatomic, strong) UILabel *cameraFlipHintLabel;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) CIContext *gpuImageContext;
@property (nonatomic, strong) NSData *latestFrameJPEGData;
@property (nonatomic, assign) NSTimeInterval lastFrameProcessTime;
@property (nonatomic, strong) NSTimer *videoStreamTimer;
@property (nonatomic, assign) BOOL isVideoChatActive;
@property (nonatomic, assign) BOOL useFrontCamera;

// ⚙️ 纯净模型切换列表
@property (nonatomic, strong) UIView *modelPickerContainer;
@property (nonatomic, strong) UITableView *modelTableView;
@property (nonatomic, strong) UILabel *pickerHeaderLabel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *availableModelsList;

// 🎙️ 真·官方 WebSocket BidiStream 全双工 PCM 音频引擎
@property (nonatomic, strong) UIImpactFeedbackGenerator *impactHaptic;
@property (nonatomic, strong) UINotificationFeedbackGenerator *notifyHaptic;
@property (nonatomic, strong) NSURLSession *webSocketSession;
@property (nonatomic, strong) NSURLSessionWebSocketTask *liveWebSocketTask;
@property (nonatomic, assign) BOOL isWebSocketConnected;
@property (nonatomic, assign) BOOL isGoogleBidiProtocol;

@property (nonatomic, strong) AVAudioEngine *liveAudioEngine;
@property (nonatomic, strong) AVAudioPlayerNode *pcmPlayerNode;
@property (nonatomic, strong) AVAudioFormat *playerOutputFormat;
@property (nonatomic, strong) AVAudioConverter *micInputConverter;
@property (nonatomic, strong) NSMutableData *outgoingPCMBuffer;
@property (nonatomic, assign) NSInteger activePlayingBuffersCount;
@property (nonatomic, assign) NSTimeInterval lastUserAudioActivityTime;
@property (nonatomic, strong) NSTimer *idleWatchdogTimer;

// 💬 纯文本模式 SSE 流式引擎 + 多轮上下文记忆
@property (nonatomic, strong) AVSpeechSynthesizer *synthesizer;
@property (nonatomic, strong) NSURLSession *streamSession;
@property (nonatomic, strong) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) NSMutableString *sseLineBuffer;
@property (nonatomic, strong) NSMutableString *accumulatedReplyText;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *chatHistory;
@property (nonatomic, strong) NSMutableString *chatTranscriptText;
@property (nonatomic, assign) NSInteger questionTurnCount;
@property (nonatomic, assign) CGFloat currentCapsuleHeight;

@property (nonatomic, assign) NSTimeInterval lastTriggerTime;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *builtinAppMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *cachedInstalledApps;

+ (instancetype)sharedManager;
- (BOOL)isTweakEnabled;
- (NSString *)currentVendorBrandName;
- (void)refreshBottomBarLayoutForActiveModes;
- (void)forceKillNativeSiri;
- (void)triggerFromSystemHook;
- (void)dismissOverlay;
@end

static void agDarwinPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadGeminiPrefsCache();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[GeminiAssistantManager sharedManager] refreshBottomBarLayoutForActiveModes];
    });
}

@implementation GeminiAssistantManager

+ (instancetype)sharedManager {
    static GeminiAssistantManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _synthesizer = [[AVSpeechSynthesizer alloc] init];
        _synthesizer.delegate = self;
        _gpuImageContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _impactHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        _notifyHaptic = [[UINotificationFeedbackGenerator alloc] init];
        _waveBars = [NSMutableArray array];
        _cachedInstalledApps = [NSMutableDictionary dictionary];
        _chatHistory = [NSMutableArray array];
        _chatTranscriptText = [NSMutableString string];
        _sseLineBuffer = [NSMutableString string];
        _accumulatedReplyText = [NSMutableString string];
        _outgoingPCMBuffer = [NSMutableData data];
        _currentCapsuleHeight = 330.0;
        _useFrontCamera = NO;
        _activeModeTab = AGConfigTabNativeLive;
        _availableModelsList = [NSMutableArray arrayWithArray:agCachedModelsForTab(_activeModeTab)];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)(self),
                                        agDarwinPrefsChangedCallback,
                                        (__bridge CFStringRef)kAGPrefsChangedNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        _builtinAppMap = @{
            @"微信": @"com.tencent.xin", @"wechat": @"com.tencent.xin",
            @"支付宝": @"com.eg.android.AlipayGphone", @"淘宝": @"com.taobao.taobao4iphone",
            @"京东": @"com.360buy.jdmobile", @"拼多多": @"com.xunmeng.pinduoduo",
            @"美团": @"com.meituan.imeituan", @"网易云": @"com.netease.cloudmusic",
            @"网易云音乐": @"com.netease.cloudmusic", @"qq音乐": @"com.tencent.QQMusic",
            @"qq": @"com.tencent.mqq", @"抖音": @"com.ss.iphone.ugc.Aweme",
            @"快手": @"com.jiangjia.gif", @"小红书": @"com.xingin.discover",
            @"b站": @"tv.danmaku.bilianime", @"哔哩哔哩": @"tv.danmaku.bilianime",
            @"youtube": @"com.google.ios.youtube", @"油管": @"com.google.ios.youtube",
            @"地图": @"com.apple.Maps", @"高德地图": @"com.autonavi.amap",
            @"设置": @"com.apple.Preferences", @"相机": @"com.apple.camera",
            @"相册": @"com.apple.mobileslideshow", @"照片": @"com.apple.mobileslideshow",
            @"safari": @"com.apple.mobilesafari", @"浏览器": @"com.apple.mobilesafari",
            @"电话": @"com.apple.mobilephone", @"短信": @"com.apple.MobileSMS",
            @"备忘录": @"com.apple.mobilenotes", @"日历": @"com.apple.mobilecal",
            @"闹钟": @"com.apple.mobiletimer", @"计算器": @"com.apple.calculator",
            @"sileo": @"org.coolstar.SileoStore"
        };
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self preloadInstalledAppsCache];
        });
    }
    return self;
}

- (void)preloadInstalledAppsCache {
    @try {
        NSArray<LSApplicationProxy *> *apps = [[%c(LSApplicationWorkspace) defaultWorkspace] allInstalledApplications];
        for (LSApplicationProxy *proxy in apps) {
            NSString *locName = [proxy.localizedName lowercaseString];
            NSString *bundleID = proxy.applicationIdentifier;
            if (locName.length > 0 && bundleID.length > 0) {
                self.cachedInstalledApps[locName] = bundleID;
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - 三大模式状态读取与国内外全 AI 品牌识别

- (BOOL)isTweakEnabled {
    NSNumber *val = loadGeminiPrefs()[@"Gemini_Enabled"];
    return val ? [val boolValue] : YES;
}

- (NSString *)currentVendorBrandName {
    NSString *rawModel = [agModelForTab(self.activeModeTab) stringByReplacingOccurrencesOfString:@"models/" withString:@""];
    NSString *lower = [rawModel lowercaseString];
    NSString *epLower = [agEndpointForTab(self.activeModeTab) lowercaseString];

    if ([lower containsString:@"deepseek"] || [epLower containsString:@"deepseek"]) return @"DeepSeek";
    if ([lower containsString:@"qwen"] || [lower containsString:@"qwq"] || [lower containsString:@"qvq"] || [epLower containsString:@"dashscope"]) return @"通义千问";
    if ([lower containsString:@"doubao"] || [epLower containsString:@"volces.com"]) return @"豆包";
    if ([lower containsString:@"kimi"] || [lower containsString:@"moonshot"] || [epLower containsString:@"moonshot"]) return @"Kimi";
    if ([lower containsString:@"glm"] || [epLower containsString:@"bigmodel.cn"]) return @"智谱清言";
    if ([lower containsString:@"ernie"] || [lower containsString:@"wenxin"]) return @"文心一言";
    if ([lower containsString:@"hunyuan"]) return @"腾讯混元";
    if ([lower containsString:@"minimax"] || [lower containsString:@"abab"] || [lower containsString:@"hailuo"]) return @"MiniMax";
    if ([lower containsString:@"step"]) return @"阶跃星辰";
    if ([lower containsString:@"spark"] || [lower containsString:@"xinghuo"]) return @"讯飞星火";
    if ([lower containsString:@"yi-"] || [lower hasPrefix:@"yi"]) return @"零一万物";
    if ([lower containsString:@"baichuan"]) return @"百川智能";

    if ([lower containsString:@"chatgpt"] || [lower containsString:@"gpt"] || [lower hasPrefix:@"o1"] || [lower hasPrefix:@"o3"] || [lower hasPrefix:@"o4"] || [epLower containsString:@"openai.com"]) return @"ChatGPT";
    if ([lower containsString:@"gemini"] || [lower containsString:@"gemma"]) return @"Gemini";
    if ([lower containsString:@"claude"] || [epLower containsString:@"anthropic"]) return @"Claude";
    if ([lower containsString:@"grok"] || [epLower containsString:@"x.ai"]) return @"Grok";
    if ([lower containsString:@"llama"]) return @"Llama";
    if ([lower containsString:@"mistral"] || [lower containsString:@"pixtral"]) return @"Mistral";

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^([a-zA-Z0-9\u4e00-\u9fa5]+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:rawModel options:0 range:NSMakeRange(0, rawModel.length)];
    if (match && match.numberOfRanges > 1) {
        NSString *prefix = [rawModel substringWithRange:[match rangeAtIndex:1]];
        if (prefix.length > 0) return [prefix capitalizedString];
    }
    return @"Gemini";
}

- (void)updateHeaderBadges {
    self.titleMaskLabel.text = [self currentVendorBrandName];
    if (self.activeModeTab == AGConfigTabVideoAI) {
        self.modeBadgeLabel.text = @"📹 实时视频";
        self.modeBadgeLabel.textColor = [UIColor colorWithRed:0.45 green:0.98 blue:0.75 alpha:1.0];
        self.modeBadgeLabel.layer.borderColor = [UIColor colorWithRed:0.35 green:0.90 blue:0.65 alpha:0.65].CGColor;
    } else if (self.activeModeTab == AGConfigTabPureText) {
        self.modeBadgeLabel.text = @"💬 纯文本";
        self.modeBadgeLabel.textColor = [UIColor colorWithRed:0.55 green:0.85 blue:1.00 alpha:1.0];
        self.modeBadgeLabel.layer.borderColor = [UIColor colorWithRed:0.40 green:0.78 blue:1.00 alpha:0.65].CGColor;
    } else {
        self.modeBadgeLabel.text = @"🎙️ 纯正Live";
        self.modeBadgeLabel.textColor = [UIColor colorWithRed:0.98 green:0.65 blue:0.88 alpha:1.0];
        self.modeBadgeLabel.layer.borderColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.80 alpha:0.65].CGColor;
    }

    self.liveModeButton.backgroundColor = (self.activeModeTab == AGConfigTabNativeLive)
        ? [UIColor colorWithRed:0.92 green:0.28 blue:0.60 alpha:0.92]
        : [UIColor colorWithWhite:1.0 alpha:0.12];
    self.videoModeButton.backgroundColor = (self.activeModeTab == AGConfigTabVideoAI)
        ? [UIColor colorWithRed:0.15 green:0.78 blue:0.52 alpha:0.92]
        : [UIColor colorWithWhite:1.0 alpha:0.12];
    self.textModeButton.backgroundColor = (self.activeModeTab == AGConfigTabPureText)
        ? [UIColor colorWithRed:0.25 green:0.58 blue:0.98 alpha:0.92]
        : [UIColor colorWithWhite:1.0 alpha:0.12];
}

#pragma mark - 窗口自适应高度与键盘避让

- (void)adjustCapsuleHeightTo:(CGFloat)targetHeight animated:(BOOL)animated {
    if (!self.overlayWindow || !self.overlayWindow.capsuleWrapper) return;
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat maxAllowedH = screenBounds.size.height * 0.72;
    CGFloat clampedH = MAX(330.0, MIN(maxAllowedH, targetHeight));
    self.currentCapsuleHeight = clampedH;

    CGFloat capsuleWidth = screenBounds.size.width - 28.0;
    CGFloat capsuleY = screenBounds.size.height - clampedH - 26.0;
    CGFloat innerBoxH = clampedH - 122.0;
    CGFloat textW = self.isVideoChatActive ? (capsuleWidth - 32.0 - 132.0) : (capsuleWidth - 32.0 - 20.0);

    void (^layoutBlock)(void) = ^{
        self.overlayWindow.capsuleWrapper.frame = CGRectMake(14, capsuleY, capsuleWidth, clampedH);
        self.cardBlurView.frame = self.overlayWindow.capsuleWrapper.bounds;
        self.innerGlassBox.frame = CGRectMake(16, 56, capsuleWidth - 32, innerBoxH);
        self.responseTextView.frame = CGRectMake(10, 34, textW, innerBoxH - 42.0);
        self.modelPickerContainer.frame = CGRectMake(16, 56, capsuleWidth - 32, innerBoxH);
        self.modelTableView.frame = CGRectMake(0, 38, capsuleWidth - 32, innerBoxH - 38.0);

        [self refreshBottomBarLayoutForActiveModes];

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.ambientLayer.frame = self.cardBlurView.bounds;
        self.borderGrad.frame = self.cardBlurView.bounds;
        UIBezierPath *bOuter = [UIBezierPath bezierPathWithRoundedRect:self.cardBlurView.bounds cornerRadius:32.0];
        UIBezierPath *bInner = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.cardBlurView.bounds, 1.6, 1.6) cornerRadius:30.4];
        [bOuter appendPath:bInner];
        bOuter.usesEvenOddFillRule = YES;
        self.borderMask.path = bOuter.CGPath;
        [CATransaction commit];
    };

    if (animated) {
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:layoutBlock completion:nil];
    } else {
        layoutBlock();
    }
}

- (void)autoExpandCapsuleForCurrentConversation {
    CGFloat textW = self.responseTextView.bounds.size.width;
    CGSize fitSize = [self.responseTextView sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)];
    CGFloat neededHeight = fitSize.height + 185.0;
    if (self.questionTurnCount >= 2) {
        neededHeight = MAX(neededHeight, 330.0 + (self.questionTurnCount - 1) * 90.0);
    }
    [self adjustCapsuleHeightTo:neededHeight animated:YES];

    if (self.responseTextView.text.length > 0) {
        NSRange bottom = NSMakeRange(self.responseTextView.text.length - 1, 1);
        [self.responseTextView scrollRangeToVisible:bottom];
    }
}

- (void)keyboardWillShow:(NSNotification *)notification {
    if (!self.overlayWindow || self.overlayWindow.hidden) return;
    CGRect kbFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat capsuleHeight = self.overlayWindow.capsuleWrapper.bounds.size.height;
    CGFloat targetY = screenBounds.size.height - kbFrame.size.height - capsuleHeight - 10.0;

    [UIView animateWithDuration:(duration > 0 ? duration : 0.25) animations:^{
        CGRect frame = self.overlayWindow.capsuleWrapper.frame;
        frame.origin.y = MAX(44.0, targetY);
        self.overlayWindow.capsuleWrapper.frame = frame;
    }];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    if (!self.overlayWindow || self.overlayWindow.hidden) return;
    CGFloat duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat capsuleHeight = self.overlayWindow.capsuleWrapper.bounds.size.height;

    [UIView animateWithDuration:(duration > 0 ? duration : 0.25) animations:^{
        CGRect frame = self.overlayWindow.capsuleWrapper.frame;
        frame.origin.y = screenBounds.size.height - capsuleHeight - 26.0;
        self.overlayWindow.capsuleWrapper.frame = frame;
    }];
}

- (UIWindowScene *)activeWindowScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

#pragma mark - 液态玻璃界面构建

- (void)setupWindowIfNeeded {
    if (self.overlayWindow) return;

    UIWindowScene *scene = [self activeWindowScene];
    CGRect screenBounds = [UIScreen mainScreen].bounds;

    if (scene) {
        self.overlayWindow = [[GeminiPassthroughWindow alloc] initWithWindowScene:scene];
        self.overlayWindow.frame = screenBounds;
    } else {
        self.overlayWindow = [[GeminiPassthroughWindow alloc] initWithFrame:screenBounds];
    }

    self.overlayWindow.windowLevel = UIWindowLevelAlert + 500;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    self.overlayWindow.hidden = YES;
    if ([self.overlayWindow respondsToSelector:@selector(_setSecure:)]) {
        [self.overlayWindow _setSecure:YES];
    }

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    self.overlayWindow.rootViewController = rootVC;

    self.edgeGlowContainer = [[UIView alloc] initWithFrame:screenBounds];
    self.edgeGlowContainer.userInteractionEnabled = NO;
    [rootVC.view addSubview:self.edgeGlowContainer];

    self.screenNeonLayer = [CAGradientLayer layer];
    self.screenNeonLayer.frame = screenBounds;
    self.screenNeonLayer.colors = @[
        (__bridge id)[UIColor colorWithRed:0.35 green:0.75 blue:1.00 alpha:0.90].CGColor,
        (__bridge id)[UIColor colorWithRed:0.68 green:0.35 blue:0.98 alpha:0.90].CGColor,
        (__bridge id)[UIColor colorWithRed:0.96 green:0.32 blue:0.62 alpha:0.90].CGColor,
        (__bridge id)[UIColor colorWithRed:0.25 green:0.85 blue:0.95 alpha:0.90].CGColor
    ];
    self.screenNeonLayer.startPoint = CGPointMake(0, 0);
    self.screenNeonLayer.endPoint = CGPointMake(1, 1);
    [self.edgeGlowContainer.layer addSublayer:self.screenNeonLayer];

    CGFloat screenCorner = adaptiveScreenCornerRadius(screenBounds);
    UIBezierPath *sOuter = [UIBezierPath bezierPathWithRoundedRect:screenBounds cornerRadius:screenCorner];
    UIBezierPath *sInner = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(screenBounds, 6.0, 6.0) cornerRadius:MAX(14.0, screenCorner - 6.0)];
    [sOuter appendPath:sInner];
    sOuter.usesEvenOddFillRule = YES;

    CAShapeLayer *sMask = [CAShapeLayer layer];
    sMask.path = sOuter.CGPath;
    sMask.fillRule = kCAFillRuleEvenOdd;
    self.screenNeonLayer.mask = sMask;

    self.edgeGlowContainer.layer.shadowColor = [UIColor colorWithRed:0.65 green:0.35 blue:1.0 alpha:1.0].CGColor;
    self.edgeGlowContainer.layer.shadowRadius = 28.0;
    self.edgeGlowContainer.layer.shadowOpacity = 0.90;
    self.edgeGlowContainer.layer.shadowOffset = CGSizeZero;

    CGFloat capsuleHeight = 330.0;
    CGFloat capsuleWidth = screenBounds.size.width - 28.0;
    CGFloat capsuleY = screenBounds.size.height - capsuleHeight - 26.0;

    UIView *wrapper = [[UIView alloc] initWithFrame:CGRectMake(14, capsuleY, capsuleWidth, capsuleHeight)];
    wrapper.backgroundColor = [UIColor clearColor];
    wrapper.layer.shadowColor = [UIColor colorWithRed:0.25 green:0.55 blue:1.0 alpha:0.50].CGColor;
    wrapper.layer.shadowRadius = 26.0;
    wrapper.layer.shadowOpacity = 0.75;
    wrapper.layer.shadowOffset = CGSizeMake(0, 8);
    [rootVC.view addSubview:wrapper];
    self.overlayWindow.capsuleWrapper = wrapper;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    self.cardBlurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.cardBlurView.frame = wrapper.bounds;
    self.cardBlurView.layer.cornerRadius = 32.0;
    self.cardBlurView.layer.masksToBounds = YES;
    [wrapper addSubview:self.cardBlurView];

    UIView *content = self.cardBlurView.contentView;
    content.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.12 alpha:0.78];

    self.ambientLayer = [CAGradientLayer layer];
    self.ambientLayer.frame = content.bounds;
    self.ambientLayer.colors = @[
        (__bridge id)[UIColor colorWithRed:0.45 green:0.25 blue:0.95 alpha:0.24].CGColor,
        (__bridge id)[UIColor colorWithRed:0.95 green:0.25 blue:0.55 alpha:0.12].CGColor,
        (__bridge id)[UIColor colorWithRed:0.00 green:0.78 blue:0.95 alpha:0.18].CGColor
    ];
    self.ambientLayer.startPoint = CGPointMake(0.0, 0.0);
    self.ambientLayer.endPoint = CGPointMake(1.0, 1.0);
    [content.layer addSublayer:self.ambientLayer];

    self.borderGrad = [CAGradientLayer layer];
    self.borderGrad.frame = content.bounds;
    self.borderGrad.colors = @[
        (__bridge id)[UIColor colorWithRed:0.65 green:0.45 blue:1.00 alpha:0.95].CGColor,
        (__bridge id)[UIColor colorWithRed:0.98 green:0.35 blue:0.60 alpha:0.95].CGColor,
        (__bridge id)[UIColor colorWithRed:0.20 green:0.88 blue:0.98 alpha:0.95].CGColor
    ];
    self.borderGrad.startPoint = CGPointMake(0.0, 0.0);
    self.borderGrad.endPoint = CGPointMake(1.0, 1.0);

    UIBezierPath *bOuter = [UIBezierPath bezierPathWithRoundedRect:content.bounds cornerRadius:32.0];
    UIBezierPath *bInner = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(content.bounds, 1.6, 1.6) cornerRadius:30.4];
    [bOuter appendPath:bInner];
    bOuter.usesEvenOddFillRule = YES;

    self.borderMask = [CAShapeLayer layer];
    self.borderMask.path = bOuter.CGPath;
    self.borderMask.fillRule = kCAFillRuleEvenOdd;
    self.borderGrad.mask = self.borderMask;
    [content.layer addSublayer:self.borderGrad];

    self.aiOrbView = [[UIView alloc] initWithFrame:CGRectMake(18, 17, 30, 30)];
    self.aiOrbView.layer.cornerRadius = 15.0;
    self.aiOrbView.layer.shadowColor = [UIColor colorWithRed:0.45 green:0.65 blue:1.0 alpha:1.0].CGColor;
    self.aiOrbView.layer.shadowRadius = 8.0;
    self.aiOrbView.layer.shadowOpacity = 0.80;
    self.aiOrbView.layer.shadowOffset = CGSizeZero;

    CAGradientLayer *orbGrad = [CAGradientLayer layer];
    orbGrad.frame = self.aiOrbView.bounds;
    orbGrad.cornerRadius = 15.0;
    orbGrad.colors = @[
        (__bridge id)[UIColor colorWithRed:0.95 green:0.98 blue:1.00 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.38 green:0.78 blue:1.00 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.72 green:0.38 blue:1.00 alpha:1.0].CGColor
    ];
    orbGrad.startPoint = CGPointMake(0.15, 0.15);
    orbGrad.endPoint = CGPointMake(0.9, 0.9);
    [self.aiOrbView.layer addSublayer:orbGrad];
    [content addSubview:self.aiOrbView];

    UIView *titleWrap = [[UIView alloc] initWithFrame:CGRectMake(56, 17, 108, 30)];
    [content addSubview:titleWrap];

    self.titleGradientLayer = [CAGradientLayer layer];
    self.titleGradientLayer.frame = titleWrap.bounds;
    self.titleGradientLayer.colors = @[
        (__bridge id)[UIColor colorWithRed:0.65 green:0.85 blue:1.00 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.88 green:0.65 blue:1.00 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:1.00 green:0.52 blue:0.78 alpha:1.0].CGColor
    ];
    self.titleGradientLayer.startPoint = CGPointMake(0, 0.5);
    self.titleGradientLayer.endPoint = CGPointMake(1, 0.5);
    [titleWrap.layer addSublayer:self.titleGradientLayer];

    self.titleMaskLabel = [[UILabel alloc] initWithFrame:titleWrap.bounds];
    self.titleMaskLabel.text = [self currentVendorBrandName];
    self.titleMaskLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];
    self.titleGradientLayer.mask = self.titleMaskLabel.layer;

    self.modeBadgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(164, 22, 68, 20)];
    self.modeBadgeLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.modeBadgeLabel.font = [UIFont boldSystemFontOfSize:10.0];
    self.modeBadgeLabel.textAlignment = NSTextAlignmentCenter;
    self.modeBadgeLabel.layer.cornerRadius = 10.0;
    self.modeBadgeLabel.layer.borderWidth = 0.8;
    self.modeBadgeLabel.layer.masksToBounds = YES;
    [content addSubview:self.modeBadgeLabel];

    NSArray<NSNumber *> *idleHeights = @[@(8.0), @(16.0), @(11.0), @(15.0), @(8.0)];
    CGFloat eqStartX = capsuleWidth - 126.0;
    for (int i = 0; i < 5; i++) {
        CGFloat h = [idleHeights[i] floatValue];
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(eqStartX + i * 6.5, 32.0 - h / 2.0, 3.8, h)];
        bar.layer.cornerRadius = 1.9;
        bar.layer.masksToBounds = YES;

        CAGradientLayer *barGrad = [CAGradientLayer layer];
        barGrad.frame = CGRectMake(0, 0, 4.0, 28.0);
        barGrad.colors = @[
            (__bridge id)[UIColor colorWithRed:0.40 green:0.82 blue:1.00 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithRed:0.95 green:0.45 blue:0.80 alpha:1.0].CGColor
        ];
        [bar.layer addSublayer:barGrad];
        [content addSubview:bar];
        [self.waveBars addObject:bar];
    }

    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.frame = CGRectMake(capsuleWidth - 84, 17, 30, 30);
    settingsBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    settingsBtn.layer.cornerRadius = 15.0;
    settingsBtn.layer.borderWidth = 0.6;
    settingsBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    [settingsBtn setTitle:@"⚙️" forState:UIControlStateNormal];
    settingsBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [settingsBtn addTarget:self action:@selector(togglePureModelPicker) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:settingsBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(capsuleWidth - 46, 17, 30, 30);
    closeBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    closeBtn.layer.cornerRadius = 15.0;
    closeBtn.layer.borderWidth = 0.6;
    closeBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.88 alpha:1.0] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [closeBtn addTarget:self action:@selector(dismissOverlay) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:closeBtn];

    self.innerGlassBox = [[UIView alloc] initWithFrame:CGRectMake(16, 56, capsuleWidth - 32, 208)];
    self.innerGlassBox.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.20 alpha:0.55];
    self.innerGlassBox.layer.cornerRadius = 20.0;
    self.innerGlassBox.layer.masksToBounds = YES;
    self.innerGlassBox.layer.borderWidth = 0.8;
    self.innerGlassBox.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    [content addSubview:self.innerGlassBox];

    self.subStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, self.innerGlassBox.bounds.size.width - 28, 20)];
    self.subStatusLabel.textColor = [UIColor colorWithRed:0.58 green:0.78 blue:1.00 alpha:1.0];
    self.subStatusLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.subStatusLabel.text = @"🎙️ 正在建立官方 WebSocket 实时流连接...";
    [self.innerGlassBox addSubview:self.subStatusLabel];

    self.responseTextView = [[UITextView alloc] initWithFrame:CGRectMake(10, 34, self.innerGlassBox.bounds.size.width - 20, 166)];
    self.responseTextView.backgroundColor = [UIColor clearColor];
    self.responseTextView.textColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    self.responseTextView.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    self.responseTextView.editable = NO;
    self.responseTextView.selectable = YES;
    self.responseTextView.text = @"“正在接通官方实时流通道...”";
    [self.innerGlassBox addSubview:self.responseTextView];

    CGFloat camW = 112.0;
    CGFloat camH = 154.0;
    self.cameraPreviewContainer = [[UIView alloc] initWithFrame:CGRectMake(self.innerGlassBox.bounds.size.width - camW - 10, 42, camW, camH)];
    self.cameraPreviewContainer.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    self.cameraPreviewContainer.layer.cornerRadius = 14.0;
    self.cameraPreviewContainer.layer.masksToBounds = YES;
    self.cameraPreviewContainer.layer.borderWidth = 1.5;
    self.cameraPreviewContainer.layer.borderColor = [UIColor colorWithRed:0.35 green:0.90 blue:0.70 alpha:0.95].CGColor;
    self.cameraPreviewContainer.hidden = YES;
    [self.innerGlassBox addSubview:self.cameraPreviewContainer];

    self.cameraLiveImageView = [[UIImageView alloc] initWithFrame:self.cameraPreviewContainer.bounds];
    self.cameraLiveImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.cameraLiveImageView.clipsToBounds = YES;
    [self.cameraPreviewContainer addSubview:self.cameraLiveImageView];

    self.cameraFlipHintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, camH - 22, camW, 22)];
    self.cameraFlipHintLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.60];
    self.cameraFlipHintLabel.textColor = [UIColor whiteColor];
    self.cameraFlipHintLabel.font = [UIFont boldSystemFontOfSize:10];
    self.cameraFlipHintLabel.textAlignment = NSTextAlignmentCenter;
    self.cameraFlipHintLabel.text = @"🔄 点击切换前/后摄";
    [self.cameraPreviewContainer addSubview:self.cameraFlipHintLabel];

    UITapGestureRecognizer *flipTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(flipCameraTapped)];
    [self.cameraPreviewContainer addGestureRecognizer:flipTap];

    self.actionBannerLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 58, capsuleWidth - 40, 28)];
    self.actionBannerLabel.backgroundColor = [UIColor colorWithRed:0.12 green:0.78 blue:0.45 alpha:0.95];
    self.actionBannerLabel.textColor = [UIColor whiteColor];
    self.actionBannerLabel.font = [UIFont boldSystemFontOfSize:13];
    self.actionBannerLabel.textAlignment = NSTextAlignmentCenter;
    self.actionBannerLabel.layer.cornerRadius = 14.0;
    self.actionBannerLabel.layer.masksToBounds = YES;
    self.actionBannerLabel.alpha = 0.0;
    [content addSubview:self.actionBannerLabel];

    self.liveModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.liveModeButton.layer.cornerRadius = 18.0;
    self.liveModeButton.layer.borderWidth = 0.8;
    self.liveModeButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    [self.liveModeButton setTitle:@"🎙️" forState:UIControlStateNormal];
    self.liveModeButton.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.liveModeButton addTarget:self action:@selector(liveModeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.liveModeButton];

    self.videoModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.videoModeButton.layer.cornerRadius = 18.0;
    self.videoModeButton.layer.borderWidth = 0.8;
    self.videoModeButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    [self.videoModeButton setTitle:@"📹" forState:UIControlStateNormal];
    self.videoModeButton.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.videoModeButton addTarget:self action:@selector(videoModeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.videoModeButton];

    self.textModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.textModeButton.layer.cornerRadius = 18.0;
    self.textModeButton.layer.borderWidth = 0.8;
    self.textModeButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    [self.textModeButton setTitle:@"💬" forState:UIControlStateNormal];
    self.textModeButton.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.textModeButton addTarget:self action:@selector(textModeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.textModeButton];

    self.inputField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.inputField.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    self.inputField.layer.cornerRadius = 18.0;
    self.inputField.layer.borderWidth = 0.7;
    self.inputField.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    self.inputField.textColor = [UIColor whiteColor];
    self.inputField.font = [UIFont systemFontOfSize:13.0];
    self.inputField.returnKeyType = UIReturnKeySend;
    self.inputField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.inputField.delegate = self;
    [content addSubview:self.inputField];

    self.sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendBtn.backgroundColor = [UIColor colorWithRed:0.35 green:0.48 blue:0.98 alpha:0.92];
    self.sendBtn.layer.cornerRadius = 18.0;
    [self.sendBtn setTitle:@"发送" forState:UIControlStateNormal];
    [self.sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    [self.sendBtn addTarget:self action:@selector(sendButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.sendBtn];

    [self setupEmbeddedModelPickerInView:content width:capsuleWidth height:capsuleHeight];
    [self refreshBottomBarLayoutForActiveModes];
}

- (void)refreshBottomBarLayoutForActiveModes {
    if (!self.overlayWindow || !self.overlayWindow.capsuleWrapper) return;
    CGFloat capsuleWidth = self.overlayWindow.capsuleWrapper.bounds.size.width;
    CGFloat capsuleHeight = self.overlayWindow.capsuleWrapper.bounds.size.height;
    CGFloat btnY = capsuleHeight - 48.0;

    BOOL showLive  = agIsTabEnabled(AGConfigTabNativeLive);
    BOOL showVideo = agIsTabEnabled(AGConfigTabVideoAI);
    BOOL showText  = agIsTabEnabled(AGConfigTabPureText);

    if (!showLive && !showVideo && !showText) {
        showLive = YES;
    }

    self.liveModeButton.hidden  = !showLive;
    self.videoModeButton.hidden = !showVideo;
    self.textModeButton.hidden  = !showText;

    CGFloat curX = 16.0;
    if (showLive) {
        self.liveModeButton.frame = CGRectMake(curX, btnY, 36.0, 36.0);
        curX += 42.0;
    }
    if (showVideo) {
        self.videoModeButton.frame = CGRectMake(curX, btnY, 36.0, 36.0);
        curX += 42.0;
    }
    if (showText) {
        self.textModeButton.frame = CGRectMake(curX, btnY, 36.0, 36.0);
        curX += 42.0;
    }

    self.sendBtn.frame = CGRectMake(capsuleWidth - 68.0, btnY, 52.0, 36.0);
    self.inputField.frame = CGRectMake(curX, btnY, capsuleWidth - curX - 74.0, 36.0);

    if (self.activeModeTab == AGConfigTabPureText) {
        self.inputField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"  💬 纯文本模式：请直接打字提问..." attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.68 alpha:1.0]}];
    } else if (self.activeModeTab == AGConfigTabVideoAI) {
        self.inputField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"  📹 实时视频流对讲中，也可打字..." attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.68 alpha:1.0]}];
    } else {
        self.inputField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"  🎙️ 官方Live实时对讲中，也可打字..." attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.68 alpha:1.0]}];
    }
    [self updateHeaderBadges];
}

#pragma mark - 底部三大模式切换逻辑

- (void)liveModeButtonTapped {
    [self.impactHaptic impactOccurred];
    [self.inputField resignFirstResponder];
    if (self.isVideoChatActive) [self stopCameraSession];
    self.activeModeTab = AGConfigTabNativeLive;
    [self updateHeaderBadges];
    [self refreshBottomBarLayoutForActiveModes];
    [self showActionBanner:@"🎙️ 已切换至：官方纯正 Live 实时语音流"];
    [self startTrueRealtimeWebSocketSessionForTab:AGConfigTabNativeLive];
}

- (void)videoModeButtonTapped {
    [self.impactHaptic impactOccurred];
    [self.inputField resignFirstResponder];
    if (!agIsTabEnabled(AGConfigTabVideoAI)) {
        [self showActionBanner:@"⚠️ 请先在《设置》开启独立视频 AI 开关"];
        return;
    }
    if (self.activeModeTab == AGConfigTabVideoAI && self.isVideoChatActive) {
        [self stopCameraSession];
        self.activeModeTab = agIsTabEnabled(AGConfigTabNativeLive) ? AGConfigTabNativeLive : AGConfigTabPureText;
        [self updateHeaderBadges];
        [self refreshBottomBarLayoutForActiveModes];
        [self showActionBanner:@"📷 已关闭实时摄像头"];
        if (self.activeModeTab == AGConfigTabNativeLive) {
            [self startTrueRealtimeWebSocketSessionForTab:AGConfigTabNativeLive];
        }
        return;
    }
    self.activeModeTab = AGConfigTabVideoAI;
    [self startCameraSession];
    [self updateHeaderBadges];
    [self refreshBottomBarLayoutForActiveModes];
    [self showActionBanner:@"📹 已开启独立视频 AI (1FPS 实时画面推流中)"];
    [self startTrueRealtimeWebSocketSessionForTab:AGConfigTabVideoAI];
}

- (void)textModeButtonTapped {
    [self.impactHaptic impactOccurred];
    if (self.isVideoChatActive) [self stopCameraSession];
    [self stopTrueRealtimeWebSocketAndAudioEngine];
    if ([self.synthesizer isSpeaking]) {
        [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    }
    self.activeModeTab = AGConfigTabPureText;
    [self updateHeaderBadges];
    [self refreshBottomBarLayoutForActiveModes];
    self.subStatusLabel.text = [NSString stringWithFormat:@"💬 纯文本模式已就绪 (%@)", [self currentVendorBrandName]];
    if (self.chatTranscriptText.length == 0) {
        self.responseTextView.text = @"“已进入安静纯文本对话模式，请直接在下方输入框打字提问...”";
    }
    [self showActionBanner:@"💬 已切换至：纯文本打字模式"];
    [self.inputField becomeFirstResponder];
}

#pragma mark - 📹 独立视频 AI 实时摄像头引擎 (硬件直绘防黑屏 + 1 FPS 连续推流 WebSocket)

- (void)flipCameraTapped {
    if (!self.isVideoChatActive) return;
    [self.impactHaptic impactOccurred];
    self.useFrontCamera = !self.useFrontCamera;
    [self showActionBanner:(self.useFrontCamera ? @"🤳 已切换为前置镜头" : @"📷 已切换为后置镜头")];
    [self startCameraSession];
}

- (void)startCameraSession {
    self.isVideoChatActive = YES;
    self.cameraPreviewContainer.hidden = NO;

    CGFloat fullW = self.innerGlassBox.bounds.size.width;
    CGFloat innerH = self.innerGlassBox.bounds.size.height;
    [UIView animateWithDuration:0.2 animations:^{
        self.responseTextView.frame = CGRectMake(10, 34, fullW - 132, innerH - 42.0);
    }];

    // 启动 1 FPS (每 0.9 秒一帧) 连续实时画面推流定时器，让 AI 实时看到连续动态摄像头画面！
    [self.videoStreamTimer invalidate];
    self.videoStreamTimer = [NSTimer timerWithTimeInterval:0.90 target:self selector:@selector(streamCurrentCameraFrameOverWebSocket) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.videoStreamTimer forMode:NSRunLoopCommonModes];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @try {
            if (self.captureSession) {
                [self.captureSession stopRunning];
                self.captureSession = nil;
            }

            AVCaptureSession *session = [[AVCaptureSession alloc] init];
            if ([session respondsToSelector:@selector(setAutomaticallyConfiguresApplicationAudioSession:)]) {
                session.automaticallyConfiguresApplicationAudioSession = NO;
            }
            if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
                session.sessionPreset = AVCaptureSessionPreset640x480;
            }

            AVCaptureDevicePosition pos = self.useFrontCamera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
            AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:pos];
            if (!device) {
                device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            }

            NSError *err = nil;
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
            if (input && [session canAddInput:input]) {
                [session addInput:input];
            }

            AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
            output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            output.alwaysDiscardsLateVideoFrames = YES;
            dispatch_queue_t videoQueue = dispatch_queue_create("com.angelguardian.videoqueue", DISPATCH_QUEUE_SERIAL);
            [output setSampleBufferDelegate:self queue:videoQueue];
            if ([session canAddOutput:output]) {
                [session addOutput:output];
            }

            AVCaptureConnection *conn = [output connectionWithMediaType:AVMediaTypeVideo];
            if (conn && conn.isVideoOrientationSupported) {
                conn.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
            if (conn && self.useFrontCamera && conn.isVideoMirroringSupported) {
                conn.videoMirrored = YES;
            }

            self.captureSession = session;
            [session startRunning];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.cameraPreviewLayer) {
                    [self.cameraPreviewLayer removeFromSuperlayer];
                }
                self.cameraPreviewLayer = [AVCaptureVideoPreviewLayer layerWithSession:session];
                self.cameraPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
                self.cameraPreviewLayer.frame = self.cameraPreviewContainer.bounds;
                [self.cameraPreviewContainer.layer insertSublayer:self.cameraPreviewLayer atIndex:0];
                [self.cameraPreviewContainer bringSubviewToFront:self.cameraLiveImageView];
                [self.cameraPreviewContainer bringSubviewToFront:self.cameraFlipHintLabel];
            });
        } @catch (NSException *e) {}
    });
}

- (void)stopCameraSession {
    self.isVideoChatActive = NO;
    [self.videoStreamTimer invalidate];
    self.videoStreamTimer = nil;
    self.latestFrameJPEGData = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.cameraPreviewContainer.hidden = YES;
        self.cameraLiveImageView.image = nil;
        CGFloat fullW = self.innerGlassBox.bounds.size.width;
        CGFloat innerH = self.innerGlassBox.bounds.size.height;
        [UIView animateWithDuration:0.2 animations:^{
            self.responseTextView.frame = CGRectMake(10, 34, fullW - 20, innerH - 42.0);
        }];
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.captureSession && self.captureSession.isRunning) {
            [self.captureSession stopRunning];
        }
        self.captureSession = nil;
    });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - self.lastFrameProcessTime < 0.08) return;
        self.lastFrameProcessTime = now;

        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) return;

        @try {
            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
            if (!ciImage || !self.gpuImageContext) return;

            CGImageRef cgImg = [self.gpuImageContext createCGImage:ciImage fromRect:ciImage.extent];
            if (cgImg) {
                UIImage *uiImg = [UIImage imageWithCGImage:cgImg];
                CGImageRelease(cgImg);

                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.isVideoChatActive && !self.cameraPreviewContainer.hidden) {
                        self.cameraLiveImageView.image = uiImg;
                    }
                });

                NSData *jpeg = UIImageJPEGRepresentation(uiImg, 0.50);
                if (jpeg.length > 0) {
                    self.latestFrameJPEGData = jpeg;
                }
            }
        } @catch (NSException *e) {}
    }
}

// 每 0.9 秒将实时摄像头画面帧推入官方 WebSocket 通道，实现真正的边看动态视频边语音交流！
- (void)streamCurrentCameraFrameOverWebSocket {
    if (!self.isVideoChatActive || !self.isWebSocketConnected || !self.liveWebSocketTask) return;
    NSData *jpeg = self.latestFrameJPEGData;
    if (!jpeg || jpeg.length == 0) return;

    NSString *b64Img = [jpeg base64EncodedStringWithOptions:0];
    if (self.isGoogleBidiProtocol) {
        NSDictionary *frameMsg = @{
            @"realtimeInput": @{
                @"mediaChunks": @[
                    @{ @"mimeType": @"image/jpeg", @"data": b64Img }
                ]
            }
        };
        [self sendJSONDictionaryOverWebSocket:frameMsg];
    }
}

#pragma mark - 🎙️ 真·官方 WebSocket BidiStream 全双工实时 PCM 语音流引擎

- (void)forceKillNativeSiri {
    safelyDismissNativeSiriIfVisible();
}

- (void)startTrueRealtimeWebSocketSessionForTab:(AGConfigTab)tab {
    [self stopTrueRealtimeWebSocketAndAudioEngine];
    [self forceKillNativeSiri];
    pauseBackgroundMediaPlayback();

    NSString *apiKey = [agAPIKeyForTab(tab) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *endpoint = [agEndpointForTab(tab) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *proxy = agProxyForTab(tab);
    NSString *modelPath = agModelForTab(tab);
    NSString *exactModelID = [modelPath stringByReplacingOccurrencesOfString:@"models/" withString:@""];

    if (apiKey.length < 5) {
        self.subStatusLabel.text = @"⚠️ 当前模式未配置 API Key";
        self.responseTextView.text = @"请前往手机《设置》App，点击右上角「✨天使守护」在对应标签页填入 API Key。";
        return;
    }

    self.isGoogleBidiProtocol = agIsGoogleNativeProtocol(endpoint, modelPath);
    self.subStatusLabel.text = [NSString stringWithFormat:@"⚡ 正在连接 %@ 官方实时流 (%@)...", [self currentVendorBrandName], exactModelID];
    self.responseTextView.text = [NSString stringWithFormat:@"✨ 正在建立 %@ 全双工实时语音通道...", [self currentVendorBrandName]];

    NSString *wsURLStr = nil;
    NSMutableURLRequest *wsReq = nil;

    if (self.isGoogleBidiProtocol) {
        NSString *hostBase = [endpoint stringByReplacingOccurrencesOfString:@"https://" withString:@"wss://"];
        hostBase = [hostBase stringByReplacingOccurrencesOfString:@"http://" withString:@"ws://"];
        wsURLStr = [NSString stringWithFormat:@"%@/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=%@", hostBase, apiKey];
        wsReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:wsURLStr]];
    } else {
        NSString *hostBase = [endpoint stringByReplacingOccurrencesOfString:@"https://" withString:@"wss://"];
        hostBase = [hostBase stringByReplacingOccurrencesOfString:@"http://" withString:@"ws://"];
        if ([hostBase hasSuffix:@"/v1"]) {
            wsURLStr = [NSString stringWithFormat:@"%@/realtime?model=%@", hostBase, exactModelID];
        } else {
            wsURLStr = [NSString stringWithFormat:@"%@/v1/realtime?model=%@", hostBase, exactModelID];
        }
        wsReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:wsURLStr]];
        [wsReq setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
        [wsReq setValue:@"realtime=v1" forHTTPHeaderField:@"OpenAI-Beta"];
    }

    self.webSocketSession = agCreateSessionWithProxy(proxy, self, [NSOperationQueue mainQueue]);
    self.liveWebSocketTask = [self.webSocketSession webSocketTaskWithRequest:wsReq];
    [self.liveWebSocketTask resume];
    [self receiveNextWebSocketMessage];

    // 启动全双工 PCM 音频引擎 (24kHz 官方原声播放 + 16kHz 麦克风实时推流)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.overlayWindow && !self.overlayWindow.hidden && self.activeModeTab != AGConfigTabPureText) {
            [self setupAndStartFullDuplexPCMAudioEngine];
        }
    });
}

// WebSocket 连通瞬间：发送官方 Bidi/Realtime 握手帧 + 触发模型用官方真人嗓音主动问候自报身份！
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    self.isWebSocketConnected = YES;
    NSString *brand = [self currentVendorBrandName];
    NSString *rawModel = [agModelForTab(self.activeModeTab) stringByReplacingOccurrencesOfString:@"models/" withString:@""];
    NSString *fullModelPath = [rawModel hasPrefix:@"models/"] ? rawModel : [NSString stringWithFormat:@"models/%@", rawModel];

    NSString *sysInstruction = [NSString stringWithFormat:
        @"请用自然、亲切的中文直接与用户实时语音交流。\n"
        @"【身份准则】不要声称自己是 iPhone 语音助手或 Siri。你的真实官方身份是 %@（当前模型：%@）。\n"
        @"【设备控制】如果用户要求打开软件/App、拨打电话或发短信，请在回复中包含 [ACTION:{\"type\":\"open_app\",\"app\":\"应用名\"}] 标记。",
        brand, rawModel];

    if (self.isGoogleBidiProtocol) {
        // 1. 发送 Google BidiGenerateContent 官方 setup 帧 (请求原生 24kHz AUDIO 真人流输出)
        NSDictionary *setupMsg = @{
            @"setup": @{
                @"model": fullModelPath,
                @"generationConfig": @{
                    @"responseModalities": @[@"AUDIO"],
                    @"speechConfig": @{
                        @"voiceConfig": @{
                            @"prebuiltVoiceConfig": @{ @"voiceName": @"Aoede" }
                        }
                    }
                },
                @"systemInstruction": @{
                    @"parts": @[ @{ @"text": sysInstruction } ]
                }
            }
        };
        [self sendJSONDictionaryOverWebSocket:setupMsg];

        // 2. 0.15秒后发送首轮唤醒问候指令，让模型立即用官方原声说出“你好，我是 Gemini...”
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.isWebSocketConnected) return;
            NSString *greetPrompt = (self.activeModeTab == AGConfigTabVideoAI)
                ? [NSString stringWithFormat:@"请用一句简短自然的话主动向我打招呼，告诉我你是 %@，并提示你可以看到我的实时摄像头画面。", brand]
                : [NSString stringWithFormat:@"请用一句简短自然的话主动向我打招呼，告诉我你是 %@，问我有什么可以帮我。", brand];
            NSDictionary *helloTurn = @{
                @"clientContent": @{
                    @"turns": @[
                        @{ @"role": @"user", @"parts": @[ @{ @"text": greetPrompt } ] }
                    ],
                    @"turnComplete": @YES
                }
            };
            [self sendJSONDictionaryOverWebSocket:helloTurn];
        });
    } else {
        // OpenAI / 兼容 Realtime 握手
        NSDictionary *sessionUpdate = @{
            @"type": @"session.update",
            @"session": @{
                @"modalities": @[@"text", @"audio"],
                @"instructions": sysInstruction,
                @"voice": @"alloy",
                @"input_audio_format": @"pcm16",
                @"output_audio_format": @"pcm16",
                @"turn_detection": @{ @"type": @"server_vad" }
            }
        };
        [self sendJSONDictionaryOverWebSocket:sessionUpdate];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.isWebSocketConnected) return;
            NSDictionary *respCreate = @{
                @"type": @"response.create",
                @"response": @{
                    @"modalities": @[@"text", @"audio"],
                    @"instructions": [NSString stringWithFormat:@"请主动开口用一句话向用户问好，自报家门说你是 %@。", brand]
                }
            };
            [self sendJSONDictionaryOverWebSocket:respCreate];
        });
    }

    self.subStatusLabel.text = (self.activeModeTab == AGConfigTabVideoAI)
        ? [NSString stringWithFormat:@"📹 %@ 实时视频+语音流已接通 (请直接说话)", brand]
        : [NSString stringWithFormat:@"🎙️ %@ 官方 Live 实时流已接通 (请直接说话)", brand];
}

- (void)sendJSONDictionaryOverWebSocket:(NSDictionary *)dict {
    if (!self.liveWebSocketTask) return;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!jsonData) return;
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonStr];
    [self.liveWebSocketTask sendMessage:msg completionHandler:^(NSError * _Nullable error) {}];
}

- (void)receiveNextWebSocketMessage {
    if (!self.liveWebSocketTask) return;
    __weak typeof(self) weakSelf = self;
    [self.liveWebSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.isWebSocketConnected = NO;
                weakSelf.subStatusLabel.text = [NSString stringWithFormat:@"⚠️ 实时流连接断开: %@", error.localizedDescription ?: @"网络异常"];
                weakSelf.responseTextView.text = [NSString stringWithFormat:@"❌ WebSocket 连接已断开。\n\n原因: %@\n\n💡 提示：请确保所选模型支持实时双向语音流(如 gemini-2.0-flash-exp / gpt-4o-realtime)，或前往系统《设置》检查 API Key 与代理配置。", error.localizedDescription ?: @"未知网络错误"];
            });
            return;
        }
        if (message) {
            NSData *msgData = message.data ?: [message.string dataUsingEncoding:NSUTF8StringEncoding];
            if (msgData.length > 0) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:msgData options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf handleIncomingWebSocketJSON:json];
                    });
                }
            }
        }
        [weakSelf receiveNextWebSocketMessage];
    }];
}

// 实时解析 WebSocket 下行的官方 24kHz PCM 音频流与字幕
- (void)handleIncomingWebSocketJSON:(NSDictionary *)json {
    self.lastUserAudioActivityTime = [[NSDate date] timeIntervalSince1970];

    // 1. 解析 Google Gemini BidiGenerateContent 的 serverContent
    NSDictionary *serverContent = json[@"serverContent"];
    if ([serverContent isKindOfClass:[NSDictionary class]]) {
        NSDictionary *modelTurn = serverContent[@"modelTurn"];
        NSArray *parts = [modelTurn isKindOfClass:[NSDictionary class]] ? modelTurn[@"parts"] : nil;
        if ([parts isKindOfClass:[NSArray class]]) {
            for (NSDictionary *part in parts) {
                if (![part isKindOfClass:[NSDictionary class]]) continue;
                NSString *txt = part[@"text"];
                if (txt.length > 0) {
                    [self appendLiveSubtitleDelta:txt];
                }
                NSDictionary *inlineData = part[@"inlineData"] ?: part[@"inline_data"];
                if ([inlineData isKindOfClass:[NSDictionary class]]) {
                    NSString *b64Audio = inlineData[@"data"];
                    if (b64Audio.length > 0) {
                        NSData *pcm24kData = [[NSData alloc] initWithBase64EncodedString:b64Audio options:NSDataBase64DecodingIgnoreUnknownCharacters];
                        if (pcm24kData.length > 0) {
                            [self enqueueAndPlayIncomingPCM24kData:pcm24kData];
                        }
                    }
                }
            }
        }
        return;
    }

    // 2. 解析 OpenAI Realtime 的 response.audio.delta / response.audio_transcript.delta
    NSString *eventType = json[@"type"];
    if ([eventType isEqualToString:@"response.audio.delta"]) {
        NSString *b64Audio = json[@"delta"];
        if (b64Audio.length > 0) {
            NSData *pcm24kData = [[NSData alloc] initWithBase64EncodedString:b64Audio options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (pcm24kData.length > 0) {
                [self enqueueAndPlayIncomingPCM24kData:pcm24kData];
            }
        }
    } else if ([eventType isEqualToString:@"response.audio_transcript.delta"] || [eventType isEqualToString:@"response.text.delta"]) {
        NSString *txt = json[@"delta"];
        if (txt.length > 0) {
            [self appendLiveSubtitleDelta:txt];
        }
    }
}

- (void)appendLiveSubtitleDelta:(NSString *)delta {
    if (self.chatTranscriptText.length == 0) {
        [self.chatTranscriptText appendFormat:@"✨ %@：", [self currentVendorBrandName]];
    }
    [self.chatTranscriptText appendString:delta];
    self.responseTextView.text = self.chatTranscriptText;

    BOOL actionExecuted = NO;
    [self parseAndExecuteActions:self.chatTranscriptText executed:&actionExecuted];
    if (!actionExecuted) {
        [self autoExpandCapsuleForCurrentConversation];
    }
}

// 将云端流回来的 24000Hz 16-bit Signed Int PCM 实时转换为 Float32 Buffer 并通过 AVAudioPlayerNode 零延迟播放！
- (void)enqueueAndPlayIncomingPCM24kData:(NSData *)pcm16Data {
    if (!self.liveAudioEngine || !self.pcmPlayerNode || !self.playerOutputFormat) return;
    NSUInteger sampleCount = pcm16Data.length / sizeof(int16_t);
    if (sampleCount == 0) return;

    AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.playerOutputFormat frameCapacity:(AVAudioFrameCount)sampleCount];
    pcmBuffer.frameLength = (AVAudioFrameCount)sampleCount;

    const int16_t *src = (const int16_t *)pcm16Data.bytes;
    float *dst = pcmBuffer.floatChannelData[0];
    for (NSUInteger i = 0; i < sampleCount; i++) {
        dst[i] = (float)src[i] / 32768.0f;
    }

    self.activePlayingBuffersCount++;
    self.subStatusLabel.text = [NSString stringWithFormat:@"🔊 %@ 正在实时讲话...", [self currentVendorBrandName]];
    [self setWaveBarsLevel:0.65];

    if (!self.pcmPlayerNode.isPlaying) {
        [self.pcmPlayerNode play];
    }

    __weak typeof(self) weakSelf = self;
    [self.pcmPlayerNode scheduleBuffer:pcmBuffer completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.activePlayingBuffersCount > 0) {
                weakSelf.activePlayingBuffersCount--;
            }
            if (weakSelf.activePlayingBuffersCount == 0) {
                weakSelf.lastUserAudioActivityTime = [[NSDate date] timeIntervalSince1970];
                [weakSelf setWaveBarsLevel:0.0];
                if (weakSelf.overlayWindow && !weakSelf.overlayWindow.hidden) {
                    weakSelf.subStatusLabel.text = (weakSelf.activeModeTab == AGConfigTabVideoAI)
                        ? @"📹 正在实时看画面并倾听您说话..."
                        : @"🎙️ 官方 Live 正在实时倾听您说话...";
                }
            }
        });
    }];
}

// 构建单引擎全双工 PCM 音频流：同时完成 24kHz 官方原声播放 + 16kHz 麦克风实时上行推流
- (void)setupAndStartFullDuplexPCMAudioEngine {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @try {
            AVAudioSession *session = [AVAudioSession sharedInstance];
            [session setActive:NO withOptions:0 error:nil];
            [session setCategory:AVAudioSessionCategoryPlayAndRecord
                            mode:AVAudioSessionModeDefault
                         options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                           error:nil];
            [session setActive:YES withOptions:0 error:nil];

            self.liveAudioEngine = [[AVAudioEngine alloc] init];
            self.pcmPlayerNode = [[AVAudioPlayerNode alloc] init];
            [self.liveAudioEngine attachNode:self.pcmPlayerNode];

            // 官方 Live 下行标准采样率：24000Hz 单声道 Float32
            self.playerOutputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:24000.0 channels:1 interleaved:NO];
            [self.liveAudioEngine connect:self.pcmPlayerNode to:self.liveAudioEngine.mainMixerNode format:self.playerOutputFormat];

            // 麦克风上行标准采样率：16000Hz 单声道 Int16 PCM (增加安全硬件格式兜底)
            AVAudioInputNode *inputNode = self.liveAudioEngine.inputNode;
            AVAudioFormat *hwFormat = [inputNode inputFormatForBus:0];
            if (!hwFormat || hwFormat.sampleRate <= 0 || hwFormat.channelCount == 0) {
                hwFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:44100.0 channels:1 interleaved:NO];
            }
            AVAudioFormat *target16kFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:16000.0 channels:1 interleaved:YES];
            self.micInputConverter = [[AVAudioConverter alloc] initFromFormat:hwFormat toFormat:target16kFormat];

            [inputNode removeTapOnBus:0];
            __weak typeof(self) weakSelf = self;
            [inputNode installTapOnBus:0 bufferSize:2048 format:hwFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
                [weakSelf processMicrophoneInputPCMBuffer:buffer targetFormat:target16kFormat];
            }];

            [self.liveAudioEngine prepare];
            [self.liveAudioEngine startAndReturnError:nil];
            [self.pcmPlayerNode play];

            dispatch_async(dispatch_get_main_queue(), ^{
                self.lastUserAudioActivityTime = [[NSDate date] timeIntervalSince1970];
                [self.idleWatchdogTimer invalidate];
                self.idleWatchdogTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(checkLiveIdleTimeout) userInfo:nil repeats:YES];
                [[NSRunLoop mainRunLoop] addTimer:self.idleWatchdogTimer forMode:NSRunLoopCommonModes];
            });
        } @catch (NSException *e) {}
    });
}

- (void)processMicrophoneInputPCMBuffer:(AVAudioPCMBuffer *)buffer targetFormat:(AVAudioFormat *)target16kFormat {
    @autoreleasepool {
        if (!buffer || buffer.frameLength == 0) return;

        // 1. 始终独立计算麦克风实时音量，驱动声波条跳动（给用户确切视觉反馈）
        float db = -100.0f;
        if (buffer.floatChannelData != NULL) {
            const float *samples = buffer.floatChannelData[0];
            float sum = 0.0f;
            AVAudioFrameCount count = buffer.frameLength;
            for (AVAudioFrameCount i = 0; i < count; i++) {
                sum += samples[i] * samples[i];
            }
            float rms = sqrtf(sum / MAX(1, count));
            db = 20.0f * log10f(MAX(rms, 1e-7f));
            if (db > -42.0f) {
                self.lastUserAudioActivityTime = [[NSDate date] timeIntervalSince1970];
                CGFloat level = MAX(0.15, MIN(1.0, (db + 44.0f) / 32.0f));
                [self setWaveBarsLevel:level];
            } else {
                [self setWaveBarsLevel:0.0];
            }
        }

        // 2. 检查网络与转换器状态
        if (!self.isWebSocketConnected || !self.micInputConverter) {
            return;
        }

        // 3. 动态全双工 VAD 逻辑：当 AI 正在播放时，仅过滤轻微环境底噪(低于-38dB)；用户正常开口(db >= -38dB)立即允许推流打断
        if (self.activePlayingBuffersCount > 0 && db < -38.0f) {
            return;
        }

        AVAudioFrameCount outCapacity = (AVAudioFrameCount)((double)buffer.frameLength * (16000.0 / MAX(1.0, buffer.format.sampleRate))) + 64;
        AVAudioPCMBuffer *convertedBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target16kFormat frameCapacity:outCapacity];

        __block BOOL provided = NO;
        NSError *convErr = nil;
        [self.micInputConverter convertToBuffer:convertedBuffer error:&convErr withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus * _Nonnull outStatus) {
            if (provided) {
                *outStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }
            provided = YES;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return buffer;
        }];

        if (!convErr && convertedBuffer.frameLength > 0 && convertedBuffer.int16ChannelData != NULL) {
            NSUInteger byteLen = convertedBuffer.frameLength * sizeof(int16_t);
            NSData *pcmChunk = [NSData dataWithBytes:convertedBuffer.int16ChannelData[0] length:byteLen];

            @synchronized (self.outgoingPCMBuffer) {
                [self.outgoingPCMBuffer appendData:pcmChunk];
                // 每攒够约 0.1 秒 (3200 字节) 的 16kHz PCM 音频块，立即通过 WebSocket 实时流发往云端！
                if (self.outgoingPCMBuffer.length >= 3200) {
                    NSData *packetToSend = [self.outgoingPCMBuffer copy];
                    [self.outgoingPCMBuffer setLength:0];
                    NSString *b64PCM = [packetToSend base64EncodedStringWithOptions:0];

                    if (self.isGoogleBidiProtocol) {
                        NSDictionary *audioMsg = @{
                            @"realtimeInput": @{
                                @"mediaChunks": @[
                                    @{ @"mimeType": @"audio/pcm;rate=16000", @"data": b64PCM }
                                ]
                            }
                        };
                        [self sendJSONDictionaryOverWebSocket:audioMsg];
                    } else {
                        NSDictionary *openAIAudio = @{
                            @"type": @"input_audio_buffer.append",
                            @"audio": b64PCM
                        };
                        [self sendJSONDictionaryOverWebSocket:openAIAudio];
                    }
                }
            }
        }
    }
}

// 连续对话 12 秒无说话自动收起浮窗
- (void)checkLiveIdleTimeout {
    if (!self.overlayWindow || self.overlayWindow.hidden || self.activeModeTab == AGConfigTabPureText) return;
    if (self.activePlayingBuffersCount > 0 || [self.synthesizer isSpeaking]) {
        self.lastUserAudioActivityTime = [[NSDate date] timeIntervalSince1970];
        return;
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastUserAudioActivityTime >= 12.0) {
        [self dismissOverlay];
    }
}

- (void)stopTrueRealtimeWebSocketAndAudioEngine {
    [self.idleWatchdogTimer invalidate];
    self.idleWatchdogTimer = nil;
    self.isWebSocketConnected = NO;
    self.activePlayingBuffersCount = 0;
    [self setWaveBarsLevel:0.0];

    if (self.liveWebSocketTask) {
        [self.liveWebSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        self.liveWebSocketTask = nil;
    }
    if (self.webSocketSession) {
        [self.webSocketSession invalidateAndCancel];
        self.webSocketSession = nil;
    }
    if (self.liveAudioEngine) {
        AVAudioEngine *engineToStop = self.liveAudioEngine;
        AVAudioPlayerNode *nodeToStop = self.pcmPlayerNode;
        self.liveAudioEngine = nil;
        self.pcmPlayerNode = nil;
        self.micInputConverter = nil;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @try {
                [engineToStop.inputNode removeTapOnBus:0];
                [nodeToStop stop];
                [engineToStop stop];
            } @catch (NSException *e) {}
        });
    }
    @synchronized (self.outgoingPCMBuffer) {
        [self.outgoingPCMBuffer setLength:0];
    }
}

- (void)showActionBanner:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.actionBannerLabel.superview bringSubviewToFront:self.actionBannerLabel];
        self.actionBannerLabel.text = msg;
        [UIView animateWithDuration:0.15 animations:^{
            self.actionBannerLabel.alpha = 1.0;
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{
                self.actionBannerLabel.alpha = 0.0;
            }];
        });
    });
}

- (void)setWaveBarsLevel:(CGFloat)level {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (level <= 0.01) {
            NSArray<NSNumber *> *idleHeights = @[@(8.0), @(16.0), @(11.0), @(15.0), @(8.0)];
            [UIView animateWithDuration:0.15 animations:^{
                for (int i = 0; i < self.waveBars.count; i++) {
                    UIView *bar = self.waveBars[i];
                    CGFloat staticH = [idleHeights[i % idleHeights.count] floatValue];
                    CGRect f = bar.frame;
                    f.size.height = staticH;
                    f.origin.y = 32.0 - staticH / 2.0;
                    bar.frame = f;
                }
                self.edgeGlowContainer.layer.shadowRadius = 26.0;
            }];
            return;
        }

        self.edgeGlowContainer.layer.shadowRadius = 26.0 + level * 16.0;
        NSArray<NSNumber *> *weights = @[@(0.55), @(1.0), @(0.75), @(0.95), @(0.55)];
        for (int i = 0; i < self.waveBars.count; i++) {
            UIView *bar = self.waveBars[i];
            CGFloat w = [weights[i % weights.count] floatValue];
            CGFloat jitter = 0.65 + (arc4random_uniform(55) / 100.0);
            CGFloat targetH = MAX(8.0, MIN(26.0, 8.0 + level * 18.0 * w * jitter));
            CGRect f = bar.frame;
            f.size.height = targetH;
            f.origin.y = 32.0 - targetH / 2.0;
            [UIView animateWithDuration:0.08 animations:^{
                bar.frame = f;
            }];
        }
    });
}

- (void)sendButtonTapped {
    [self.impactHaptic impactOccurred];
    if (self.inputField.text.length > 0) {
        [self textFieldShouldReturn:self.inputField];
    }
}

#pragma mark - 3. 手机操作引擎 (打开应用自动关闭浮窗)

- (NSString *)parseAndExecuteActions:(NSString *)responseText executed:(BOOL *)outExecuted {
    if (outExecuted) *outExecuted = NO;
    if (!responseText || responseText.length == 0) return @"";

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[ACTION:(\\{.*?\\})\\]"
                                                                           options:NSRegularExpressionDotMatchesLineSeparators
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:responseText options:0 range:NSMakeRange(0, responseText.length)];
    if (match && match.numberOfRanges > 1) {
        NSString *jsonStr = [responseText substringWithRange:[match rangeAtIndex:1]];
        NSData *jsonData = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *actionDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
        if ([actionDict isKindOfClass:[NSDictionary class]]) {
            if (outExecuted) *outExecuted = YES;
            [self executeActionDictionary:actionDict];
        }
        NSString *cleaned = [regex stringByReplacingMatchesInString:responseText options:0 range:NSMakeRange(0, responseText.length) withTemplate:@""];
        return [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return responseText;
}

- (BOOL)tryExecuteDirectLocalCommand:(NSString *)cmdText {
    if (!cmdText || cmdText.length == 0) return NO;
    NSString *cmd = [cmdText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSRegularExpression *openRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:打开|启动|开启)([^，。！？,.!?\\s”\"']+)" options:0 error:nil];
    NSTextCheckingResult *openMatch = [openRegex firstMatchInString:cmd options:0 range:NSMakeRange(0, cmd.length)];
    if (openMatch) {
        NSString *appName = [cmd substringWithRange:[openMatch rangeAtIndex:1]];
        [self executeActionDictionary:@{@"type": @"open_app", @"app": appName}];
        return YES;
    }

    NSRegularExpression *callRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:给|拨打)([^，。！？,.!?\\s]+?)(?:打电话|呼叫|的电话)" options:0 error:nil];
    NSTextCheckingResult *callMatch = [callRegex firstMatchInString:cmd options:0 range:NSMakeRange(0, cmd.length)];
    if (callMatch) {
        NSString *target = [cmd substringWithRange:[callMatch rangeAtIndex:1]];
        [self executeActionDictionary:@{@"type": @"make_call", @"target": target}];
        return YES;
    }

    NSRegularExpression *smsRegex = [NSRegularExpression regularExpressionWithPattern:@"给(.+?)发(?:短信|信息)(?:说|内容是)?(.+)$" options:0 error:nil];
    NSTextCheckingResult *smsMatch = [smsRegex firstMatchInString:cmd options:0 range:NSMakeRange(0, cmd.length)];
    if (smsMatch) {
        NSString *target = [cmd substringWithRange:[smsMatch rangeAtIndex:1]];
        NSString *content = [cmd substringWithRange:[smsMatch rangeAtIndex:2]];
        [self executeActionDictionary:@{@"type": @"send_sms", @"target": target, @"content": content}];
        return YES;
    }
    return NO;
}

- (void)executeActionDictionary:(NSDictionary *)dict {
    [self.notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    NSString *type = dict[@"type"];
    if ([type isEqualToString:@"open_app"]) {
        NSString *appName = dict[@"app"];
        if (appName) [self openApplicationByName:appName];
    } else if ([type isEqualToString:@"make_call"]) {
        NSString *target = dict[@"target"];
        if (target) [self makePhoneCallToTarget:target];
    } else if ([type isEqualToString:@"send_sms"]) {
        NSString *target = dict[@"target"];
        NSString *content = dict[@"content"] ?: @"";
        if (target) [self sendSMSToTarget:target content:content];
    }
}

- (void)openApplicationByName:(NSString *)appName {
    NSString *cleanName = [[appName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSString *targetBundleID = self.builtinAppMap[cleanName];

    if (!targetBundleID && self.cachedInstalledApps.count > 0) {
        targetBundleID = self.cachedInstalledApps[cleanName];
        if (!targetBundleID) {
            for (NSString *locName in self.cachedInstalledApps) {
                if ([locName containsString:cleanName] || [cleanName containsString:locName]) {
                    targetBundleID = self.cachedInstalledApps[locName];
                    break;
                }
            }
        }
    }

    if (!targetBundleID) {
        NSArray<LSApplicationProxy *> *apps = [[%c(LSApplicationWorkspace) defaultWorkspace] allInstalledApplications];
        for (LSApplicationProxy *proxy in apps) {
            NSString *locName = [proxy.localizedName lowercaseString];
            if (locName && ([locName isEqualToString:cleanName] || [locName containsString:cleanName] || [cleanName containsString:locName])) {
                targetBundleID = proxy.applicationIdentifier;
                self.cachedInstalledApps[locName] = targetBundleID;
                break;
            }
        }
    }

    if (targetBundleID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissOverlay];
            SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
            BOOL launched = NO;
            if ([sb respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
                launched = [sb launchApplicationWithIdentifier:targetBundleID suspended:NO];
            }
            if (!launched) {
                [[%c(LSApplicationWorkspace) defaultWorkspace] openApplicationWithBundleID:targetBundleID];
            }
        });
    } else {
        [self showActionBanner:[NSString stringWithFormat:@"⚠️ 未找到应用: %@", appName]];
    }
}

- (NSString *)resolvePhoneNumberForTarget:(NSString *)target {
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSString *digitsOnly = [[target componentsSeparatedByCharactersInSet:nonDigits] componentsJoinedByString:@""];
    if (digitsOnly.length >= 3 && digitsOnly.length == target.length) return digitsOnly;

    CNContactStore *store = [[CNContactStore alloc] init];
    NSArray *keys = @[CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey];
    CNContactFetchRequest *request = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys];
    __block NSString *matchedPhone = nil;

    [store enumerateContactsWithFetchRequest:request error:nil usingBlock:^(CNContact * _Nonnull contact, BOOL * _Nonnull stop) {
        NSString *fullName = [NSString stringWithFormat:@"%@%@", contact.familyName ?: @"", contact.givenName ?: @""];
        NSString *reverseName = [NSString stringWithFormat:@"%@%@", contact.givenName ?: @"", contact.familyName ?: @""];
        if ([fullName containsString:target] || [reverseName containsString:target] || [target containsString:fullName]) {
            CNLabeledValue<CNPhoneNumber *> *firstPhone = contact.phoneNumbers.firstObject;
            if (firstPhone) {
                matchedPhone = firstPhone.value.stringValue;
                *stop = YES;
            }
        }
    }];

    if (matchedPhone) return [[matchedPhone componentsSeparatedByCharactersInSet:nonDigits] componentsJoinedByString:@""];
    return digitsOnly.length > 0 ? digitsOnly : nil;
}

- (void)makePhoneCallToTarget:(NSString *)target {
    NSString *phone = [self resolvePhoneNumberForTarget:target];
    if (phone.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissOverlay];
            NSURL *telURL = [NSURL URLWithString:[NSString stringWithFormat:@"tel://%@", phone]];
            [[UIApplication sharedApplication] openURL:telURL options:@{} completionHandler:nil];
        });
    } else {
        [self showActionBanner:[NSString stringWithFormat:@"⚠️ 未找到联系人 %@ 的号码", target]];
    }
}

- (void)sendSMSToTarget:(NSString *)target content:(NSString *)content {
    NSString *phone = [self resolvePhoneNumberForTarget:target];
    if (phone.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissOverlay];
            NSString *encodedBody = [content stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            NSString *smsURLStr = [NSString stringWithFormat:@"sms:%@&body=%@", phone, encodedBody ?: @""];
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:smsURLStr] options:@{} completionHandler:nil];
        });
    } else {
        [self showActionBanner:[NSString stringWithFormat:@"⚠️ 未找到联系人 %@ 的号码", target]];
    }
}

#pragma mark - 4. 悬浮窗右上角 ⚙️ 纯净模型切换面板

- (void)setupEmbeddedModelPickerInView:(UIView *)parent width:(CGFloat)w height:(CGFloat)h {
    self.modelPickerContainer = [[UIView alloc] initWithFrame:CGRectMake(16, 56, w - 32, 208)];
    self.modelPickerContainer.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.14 alpha:0.99];
    self.modelPickerContainer.layer.cornerRadius = 20.0;
    self.modelPickerContainer.layer.borderWidth = 1.2;
    self.modelPickerContainer.layer.borderColor = [UIColor colorWithRed:0.45 green:0.70 blue:1.0 alpha:0.45].CGColor;
    self.modelPickerContainer.clipsToBounds = YES;
    self.modelPickerContainer.hidden = YES;
    [parent addSubview:self.modelPickerContainer];

    CGFloat mw = self.modelPickerContainer.bounds.size.width;

    self.pickerHeaderLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 7, mw - 160, 26)];
    self.pickerHeaderLabel.text = @"🤖 切换当前模式可用模型";
    self.pickerHeaderLabel.textColor = [UIColor colorWithRed:0.75 green:0.90 blue:1.0 alpha:1.0];
    self.pickerHeaderLabel.font = [UIFont boldSystemFontOfSize:12.5];
    [self.modelPickerContainer addSubview:self.pickerHeaderLabel];

    UIButton *syncCloudBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    syncCloudBtn.frame = CGRectMake(mw - 140, 7, 80, 26);
    syncCloudBtn.backgroundColor = [UIColor colorWithRed:0.20 green:0.45 blue:0.85 alpha:0.85];
    syncCloudBtn.layer.cornerRadius = 7.0;
    [syncCloudBtn setTitle:@"☁️获取模型" forState:UIControlStateNormal];
    [syncCloudBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    syncCloudBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [syncCloudBtn addTarget:self action:@selector(fetchCloudModelsTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.modelPickerContainer addSubview:syncCloudBtn];

    UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    backBtn.frame = CGRectMake(mw - 54, 7, 44, 26);
    backBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    backBtn.layer.cornerRadius = 7.0;
    [backBtn setTitle:@"收起" forState:UIControlStateNormal];
    [backBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    backBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.5];
    [backBtn addTarget:self action:@selector(togglePureModelPicker) forControlEvents:UIControlEventTouchUpInside];
    [self.modelPickerContainer addSubview:backBtn];

    self.modelTableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 38, mw, 170) style:UITableViewStylePlain];
    self.modelTableView.backgroundColor = [UIColor clearColor];
    self.modelTableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    self.modelTableView.delegate = self;
    self.modelTableView.dataSource = self;
    self.modelTableView.rowHeight = 38.0;
    self.modelTableView.delaysContentTouches = NO;
    [self.modelPickerContainer addSubview:self.modelTableView];
}

- (void)refreshOverlayPickerHeader {
    AGConfigTab tab = self.activeModeTab;
    if (tab == AGConfigTabVideoAI) {
        self.pickerHeaderLabel.text = @"📹 独立视频AI 可用模型列表";
    } else if (tab == AGConfigTabPureText) {
        self.pickerHeaderLabel.text = @"💬 纯文本模式 可用模型列表";
    } else {
        self.pickerHeaderLabel.text = @"🎙️ 纯正Live 可用模型列表";
    }
    [self.availableModelsList removeAllObjects];
    [self.availableModelsList addObjectsFromArray:agCachedModelsForTab(tab)];
    [self.modelTableView reloadData];
}

- (void)togglePureModelPicker {
    [self.impactHaptic impactOccurred];
    [self.inputField resignFirstResponder];
    self.modelPickerContainer.hidden = !self.modelPickerContainer.hidden;
    self.overlayWindow.lockFullScreenTouch = !self.modelPickerContainer.hidden;

    if (!self.modelPickerContainer.hidden) {
        [self refreshOverlayPickerHeader];
        [self.modelPickerContainer.superview bringSubviewToFront:self.modelPickerContainer];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.availableModelsList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"GeminiModelCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        UIView *selBg = [[UIView alloc] init];
        selBg.backgroundColor = [UIColor colorWithRed:0.35 green:0.45 blue:0.95 alpha:0.35];
        cell.selectedBackgroundView = selBg;
    }
    NSDictionary *item = self.availableModelsList[indexPath.row];
    NSString *mID = item[@"id"];
    NSString *mTitle = item[@"title"] ?: mID;
    NSString *curSaved = agModelForTab(self.activeModeTab);
    BOOL isCurrent = [mID isEqualToString:curSaved];
    cell.textLabel.text = isCurrent ? [NSString stringWithFormat:@"✅ %@", mTitle] : [NSString stringWithFormat:@"    %@", mTitle];
    cell.textLabel.textColor = isCurrent ? [UIColor colorWithRed:0.45 green:0.95 blue:0.65 alpha:1.0] : [UIColor whiteColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.impactHaptic impactOccurred];
    NSDictionary *item = self.availableModelsList[indexPath.row];
    NSString *selectedID = item[@"id"];
    if (selectedID) {
        AGConfigTab tab = self.activeModeTab;
        NSMutableDictionary *p = loadGeminiPrefs();
        NSString *modelKey = [NSString stringWithFormat:@"%@_Model", agPrefixForTab(tab)];
        p[modelKey] = selectedID;
        saveGeminiPrefs(p);

        NSString *shortName = [selectedID stringByReplacingOccurrencesOfString:@"models/" withString:@""];
        [self updateHeaderBadges];
        [self showActionBanner:[NSString stringWithFormat:@"✨ 已切换为 %@ (%@)", [self currentVendorBrandName], shortName]];
        [self.modelTableView reloadData];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.modelPickerContainer.hidden = YES;
            self.overlayWindow.lockFullScreenTouch = NO;
            if (self.activeModeTab != AGConfigTabPureText) {
                [self startTrueRealtimeWebSocketSessionForTab:self.activeModeTab];
            }
        });
    }
}

- (void)fetchCloudModelsTapped:(UIButton *)sender {
    [self.impactHaptic impactOccurred];
    AGConfigTab tab = self.activeModeTab;
    NSString *ep = agEndpointForTab(tab);
    NSString *key = agAPIKeyForTab(tab);
    NSString *proxy = agProxyForTab(tab);

    [self showActionBanner:@"☁️ 正在获取当前模式可用模型..."];
    agFetchCloudModelsForTab(tab, ep, key, proxy, ^(BOOL success, NSArray<NSDictionary *> *models, NSString *errorMsg) {
        if (!success) {
            [self showActionBanner:[NSString stringWithFormat:@"❌ %@", errorMsg ?: @"获取失败"]];
            return;
        }
        [self.availableModelsList removeAllObjects];
        [self.availableModelsList addObjectsFromArray:models];
        NSMutableDictionary *p = loadGeminiPrefs();
        NSString *cacheKey = [NSString stringWithFormat:@"%@_CachedModels", agPrefixForTab(tab)];
        p[cacheKey] = models;
        if (models.count > 0) {
            NSString *modelKey = [NSString stringWithFormat:@"%@_Model", agPrefixForTab(tab)];
            if (!p[modelKey] || [p[modelKey] length] == 0) {
                p[modelKey] = models.firstObject[@"id"];
            }
        }
        saveGeminiPrefs(p);
        [self.modelTableView reloadData];
        [self showActionBanner:[NSString stringWithFormat:@"✅ 已同步 %lu 个可用模型", (unsigned long)models.count]];
    });
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSString *text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length > 0) {
        [textField resignFirstResponder];
        textField.text = @"";
        if ([self tryExecuteDirectLocalCommand:text]) return YES;

        // 如果当前处于 WebSocket Live 连接中，直接把打字内容也发进实时通道！
        if (self.isWebSocketConnected && self.liveWebSocketTask && self.activeModeTab != AGConfigTabPureText) {
            if (self.chatTranscriptText.length > 0) [self.chatTranscriptText appendString:@"\n\n"];
            [self.chatTranscriptText appendFormat:@"🗣️ 您：%@\n", text];
            self.responseTextView.text = self.chatTranscriptText;

            if (self.isGoogleBidiProtocol) {
                NSDictionary *turnMsg = @{
                    @"clientContent": @{
                        @"turns": @[ @{ @"role": @"user", @"parts": @[ @{ @"text": text } ] } ],
                        @"turnComplete": @YES
                    }
                };
                [self sendJSONDictionaryOverWebSocket:turnMsg];
            } else {
                [self sendJSONDictionaryOverWebSocket:@{
                    @"type": @"conversation.item.create",
                    @"item": @{ @"type": @"message", @"role": @"user", @"content": @[ @{ @"type": @"input_text", @"text": text } ] }
                }];
                [self sendJSONDictionaryOverWebSocket:@{ @"type": @"response.create" }];
            }
            return YES;
        }

        [self dispatchPureTextStreamingRequestWithText:text forTab:self.activeModeTab];
    }
    return YES;
}

#pragma mark - 5. 呼出与收起动画

- (void)startVisualAnimations {
    [self.screenNeonLayer removeAllAnimations];
    [self.aiOrbView.layer removeAllAnimations];

    CABasicAnimation *breath = [CABasicAnimation animationWithKeyPath:@"opacity"];
    breath.fromValue = @(0.52);
    breath.toValue = @(0.96);
    breath.duration = 2.0;
    breath.autoreverses = YES;
    breath.repeatCount = HUGE_VALF;
    breath.removedOnCompletion = NO;
    [self.screenNeonLayer addAnimation:breath forKey:@"auroraGentleBreath"];
}

- (void)triggerFromSystemHook {
    [self forceKillNativeSiri];
    pauseBackgroundMediaPlayback();
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastTriggerTime < 0.45) return;
    self.lastTriggerTime = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.impactHaptic prepare];
        [self.impactHaptic impactOccurred];
        [self forceKillNativeSiri];
        [self toggleOverlayInternal];
    });
}

- (void)toggleOverlayInternal {
    [self setupWindowIfNeeded];
    if (!self.overlayWindow.hidden && self.overlayWindow.alpha > 0.1) {
        [self dismissOverlay];
    } else {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow && w != self.overlayWindow) {
                self.previousKeyWindow = w;
                break;
            }
        }

        if (agIsTabEnabled(AGConfigTabNativeLive)) {
            self.activeModeTab = AGConfigTabNativeLive;
        } else if (agIsTabEnabled(AGConfigTabVideoAI)) {
            self.activeModeTab = AGConfigTabVideoAI;
        } else {
            self.activeModeTab = AGConfigTabPureText;
        }

        [self.chatHistory removeAllObjects];
        [self.chatTranscriptText setString:@""];
        self.questionTurnCount = 0;
        [self adjustCapsuleHeightTo:330.0 animated:NO];
        [self refreshBottomBarLayoutForActiveModes];

        self.modelPickerContainer.hidden = YES;
        self.overlayWindow.lockFullScreenTouch = NO;
        self.overlayWindow.alpha = 0.0;
        self.overlayWindow.hidden = NO;
        [self.overlayWindow makeKeyWindow];
        [self startVisualAnimations];
        [self updateHeaderBadges];

        self.overlayWindow.capsuleWrapper.transform = CGAffineTransformMakeTranslation(0, 26);
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.84 initialSpringVelocity:0.7 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.overlayWindow.alpha = 1.0;
            self.overlayWindow.capsuleWrapper.transform = CGAffineTransformIdentity;
        } completion:nil];

        if (agAPIKeyForTab(self.activeModeTab).length < 5) {
            self.subStatusLabel.text = @"⚠️ 当前模式未配置 API Key";
            self.responseTextView.text = @"请前往手机《设置》App，点击右上角「✨天使守护」在对应标签页填入 API Key 与接口地址。";
        } else if (self.activeModeTab == AGConfigTabVideoAI) {
            [self startCameraSession];
            [self startTrueRealtimeWebSocketSessionForTab:AGConfigTabVideoAI];
        } else if (self.activeModeTab == AGConfigTabNativeLive) {
            [self startTrueRealtimeWebSocketSessionForTab:AGConfigTabNativeLive];
        } else {
            self.subStatusLabel.text = [NSString stringWithFormat:@"💬 纯文本模式已就绪 (%@)", [self currentVendorBrandName]];
            self.responseTextView.text = @"“请在下方输入框打字提问...”";
        }
    }
}

- (void)dismissOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopTrueRealtimeWebSocketAndAudioEngine];
        [self stopCameraSession];
        [self.inputField resignFirstResponder];
        [self.overlayWindow endEditing:YES];
        self.overlayWindow.lockFullScreenTouch = NO;

        if (self.currentTask) {
            [self.currentTask cancel];
            self.currentTask = nil;
        }
        if ([self.synthesizer isSpeaking]) {
            [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        });

        [UIView animateWithDuration:0.18 animations:^{
            self.overlayWindow.alpha = 0.0;
            self.overlayWindow.capsuleWrapper.transform = CGAffineTransformMakeTranslation(0, 20);
        } completion:^(BOOL finished) {
            self.overlayWindow.hidden = YES;
            [self.screenNeonLayer removeAllAnimations];
            if (self.previousKeyWindow) {
                [self.previousKeyWindow makeKeyWindow];
            }
        }];
    });
}

#pragma mark - 6. 💬 纯文本模式 SSE 流式引擎

- (void)dispatchPureTextStreamingRequestWithText:(NSString *)userText forTab:(AGConfigTab)tab {
    NSString *apiKey = agAPIKeyForTab(tab);
    NSString *endpoint = agEndpointForTab(tab);
    NSString *proxy = agProxyForTab(tab);
    NSString *modelPath = agModelForTab(tab);
    NSString *exactModelID = [modelPath stringByReplacingOccurrencesOfString:@"models/" withString:@""];

    if (apiKey.length < 5) {
        self.subStatusLabel.text = @"⚠️ 请前往系统《设置》配置当前模式的 API Key";
        return;
    }

    if (self.currentTask) [self.currentTask cancel];
    [self.sseLineBuffer setString:@""];
    [self.accumulatedReplyText setString:@""];

    [self updateHeaderBadges];
    self.subStatusLabel.text = [NSString stringWithFormat:@"💬 %@ (%@) 正在流式回答...", [self currentVendorBrandName], exactModelID];

    self.questionTurnCount += 1;
    if (self.chatTranscriptText.length > 0) {
        [self.chatTranscriptText appendString:@"\n\n"];
    }
    [self.chatTranscriptText appendFormat:@"🗣️ 您：%@\n✨ %@：", userText, [self currentVendorBrandName]];
    self.responseTextView.text = self.chatTranscriptText;
    [self autoExpandCapsuleForCurrentConversation];

    NSString *sysPrompt = [NSString stringWithFormat:
        @"请用简明、自然的中文回答用户，不要使用复杂的 Markdown 符号。\n"
        @"【上下文记忆】请紧密结合前面的对话历史回答用户的追问。\n"
        @"【身份准则】不要声称自己是 iPhone 语音助手或 Siri。当用户询问你是谁或什么模型时，请如实回答你的真实官方身份（%@）与具体模型版本（%@）。\n"
        @"【设备控制规则】仅当用户明确要求打开软件/App、拨打电话或发送短信时，输出以下格式标记：\n"
        @"1. 打开应用：[ACTION:{\"type\":\"open_app\",\"app\":\"应用名\"}]\n"
        @"2. 拨打电话：[ACTION:{\"type\":\"make_call\",\"target\":\"姓名或号码\"}]\n"
        @"3. 发送短信：[ACTION:{\"type\":\"send_sms\",\"target\":\"姓名或号码\",\"content\":\"内容\"}]",
        [self currentVendorBrandName], exactModelID];

    BOOL isGoogle = agIsGoogleNativeProtocol(endpoint, modelPath);
    NSMutableURLRequest *request = nil;

    if (isGoogle) {
        NSString *fullModelPath = [modelPath hasPrefix:@"models/"] ? modelPath : [NSString stringWithFormat:@"models/%@", modelPath];
        NSString *urlStr = [NSString stringWithFormat:@"%@/v1beta/%@:streamGenerateContent?alt=sse&key=%@", endpoint, fullModelPath, apiKey];
        request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

        NSMutableArray *contents = [NSMutableArray array];
        for (NSDictionary *hist in self.chatHistory) {
            [contents addObject:@{
                @"role": [hist[@"role"] isEqualToString:@"assistant"] ? @"model" : @"user",
                @"parts": @[@{@"text": hist[@"content"] ?: @""}]
            }];
        }
        [contents addObject:@{@"role": @"user", @"parts": @[@{@"text": userText}]}];

        NSDictionary *body = @{
            @"systemInstruction": @{@"parts": @[@{@"text": sysPrompt}]},
            @"contents": contents
        };
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    } else {
        NSString *urlStr = endpoint;
        if (![urlStr hasSuffix:@"/chat/completions"]) {
            if ([urlStr hasSuffix:@"/v1"]) {
                urlStr = [NSString stringWithFormat:@"%@/chat/completions", urlStr];
            } else {
                urlStr = [NSString stringWithFormat:@"%@/v1/chat/completions", urlStr];
            }
        }
        request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

        NSMutableArray *messages = [NSMutableArray array];
        [messages addObject:@{@"role": @"system", @"content": sysPrompt}];
        for (NSDictionary *hist in self.chatHistory) {
            [messages addObject:hist];
        }
        [messages addObject:@{@"role": @"user", @"content": userText}];

        NSDictionary *body = @{
            @"model": exactModelID,
            @"messages": messages,
            @"stream": @YES
        };
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }

    [self.chatHistory addObject:@{@"role": @"user", @"content": userText}];
    if (self.chatHistory.count > 12) [self.chatHistory removeObjectAtIndex:0];

    if (self.streamSession) {
        [self.streamSession invalidateAndCancel];
    }
    self.streamSession = agCreateSessionWithProxy(proxy, self, [NSOperationQueue mainQueue]);
    self.currentTask = [self.streamSession dataTaskWithRequest:request];
    [self.currentTask resume];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    NSString *chunkStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!chunkStr) return;

    [self.sseLineBuffer appendString:chunkStr];
    NSArray<NSString *> *lines = [self.sseLineBuffer componentsSeparatedByString:@"\n"];

    for (NSInteger i = 0; i < (NSInteger)lines.count - 1; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([line hasPrefix:@"data:"]) {
            NSString *jsonStr = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([jsonStr isEqualToString:@"[DONE]"]) continue;
            [self processStreamJSONChunk:jsonStr];
        }
    }
    [self.sseLineBuffer setString:lines.lastObject ?: @""];
}

- (void)processStreamJSONChunk:(NSString *)jsonStr {
    NSData *jsonData = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData) return;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) return;

    NSString *deltaText = nil;
    NSArray *choices = dict[@"choices"];
    if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
        NSDictionary *firstChoice = choices.firstObject;
        if ([firstChoice isKindOfClass:[NSDictionary class]]) {
            id contentVal = firstChoice[@"delta"][@"content"] ?: firstChoice[@"message"][@"content"];
            if ([contentVal isKindOfClass:[NSString class]]) {
                deltaText = contentVal;
            }
        }
    }
    if (!deltaText) {
        NSArray *candidates = dict[@"candidates"];
        if ([candidates isKindOfClass:[NSArray class]] && candidates.count > 0) {
            NSArray *parts = candidates.firstObject[@"content"][@"parts"];
            if ([parts isKindOfClass:[NSArray class]] && parts.count > 0) {
                id tVal = parts.firstObject[@"text"];
                if ([tVal isKindOfClass:[NSString class]]) {
                    deltaText = tVal;
                }
            }
        }
    }

    if (deltaText.length > 0) {
        [self.accumulatedReplyText appendString:deltaText];
        [self.chatTranscriptText appendString:deltaText];
        self.responseTextView.text = self.chatTranscriptText;
        [self autoExpandCapsuleForCurrentConversation];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task == self.liveWebSocketTask) return;
    if (error && error.code == NSURLErrorCancelled) return;

    BOOL actionExecuted = NO;
    NSString *cleanReply = [self parseAndExecuteActions:self.accumulatedReplyText executed:&actionExecuted];
    if (!actionExecuted && cleanReply.length > 0) {
        self.subStatusLabel.text = [NSString stringWithFormat:@"✨ %@ 回答完毕", [self currentVendorBrandName]];
        [self.chatHistory addObject:@{@"role": @"assistant", @"content": cleanReply}];
        if (self.chatHistory.count > 12) [self.chatHistory removeObjectAtIndex:0];
    }
}

@end

// ==================== 3. 手机系统《设置》App 原生三模独立配置中心 ====================
@interface AngelGuardianSettingsViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, assign) AGConfigTab currentEditingTab;
@property (nonatomic, strong) UISwitch *masterEnableSwitch;
@property (nonatomic, strong) UISegmentedControl *configModuleTabSeg;

@property (nonatomic, strong) UIView *tabSwitchRowView;
@property (nonatomic, strong) UILabel *tabSwitchTitleLabel;
@property (nonatomic, strong) UISwitch *tabEnableSwitch;

@property (nonatomic, strong) UITextField *endpointField;
@property (nonatomic, strong) UITextField *apiKeyField;
@property (nonatomic, strong) UITextField *proxyField;
@property (nonatomic, strong) UITextField *modelField;
@property (nonatomic, strong) UIButton *fetchModelsBtn;
@property (nonatomic, strong) UILabel *modelSectionHintLabel;
@property (nonatomic, strong) UITableView *modelsTableView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *currentTabModels;
@end

@implementation AngelGuardianSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"✨ 天使守护 v5.0 配置中心";
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.12 alpha:1.0];
    self.currentTabModels = [NSMutableArray array];

    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"保存并关闭" style:UIBarButtonItemStyleDone target:self action:@selector(saveAndDismissTapped)];
    closeItem.tintColor = [UIColor colorWithRed:0.40 green:0.85 blue:0.65 alpha:1.0];
    self.navigationItem.rightBarButtonItem = closeItem;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scroll];

    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = 16.0;
    CGFloat cardW = w - pad * 2;
    CGFloat y = 14.0;

    UIView *topCard = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cardW, 54)];
    topCard.backgroundColor = [UIColor colorWithRed:0.13 green:0.13 blue:0.20 alpha:1.0];
    topCard.layer.cornerRadius = 16.0;
    topCard.layer.borderWidth = 0.8;
    topCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    [scroll addSubview:topCard];

    NSDictionary *prefs = loadGeminiPrefs();

    UILabel *enLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 13, 220, 28)];
    enLbl.text = @"⚡ 启用「天使守护」总开关";
    enLbl.textColor = [UIColor whiteColor];
    enLbl.font = [UIFont boldSystemFontOfSize:14];
    [topCard addSubview:enLbl];

    self.masterEnableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 64, 11, 50, 30)];
    self.masterEnableSwitch.on = prefs[@"Gemini_Enabled"] ? [prefs[@"Gemini_Enabled"] boolValue] : YES;
    [self.masterEnableSwitch addTarget:self action:@selector(globalControlChanged) forControlEvents:UIControlEventValueChanged];
    [topCard addSubview:topCard];
    [topCard addSubview:self.masterEnableSwitch];

    y += 68.0;

    UILabel *tabHeader = [[UILabel alloc] initWithFrame:CGRectMake(pad + 4, y, cardW, 20)];
    tabHeader.text = @"🛠️ 三大独立模式配置 (每个标签均有独立开关与独立API)：";
    tabHeader.textColor = [UIColor colorWithWhite:0.86 alpha:1.0];
    tabHeader.font = [UIFont boldSystemFontOfSize:12.5];
    [scroll addSubview:tabHeader];
    y += 24.0;

    self.configModuleTabSeg = [[UISegmentedControl alloc] initWithItems:@[@"🎙️ 纯正Live", @"📹 独立视频AI", @"💬 纯文本模式"]];
    self.configModuleTabSeg.frame = CGRectMake(pad, y, cardW, 36);
    self.configModuleTabSeg.selectedSegmentIndex = 0;
    self.configModuleTabSeg.backgroundColor = [UIColor colorWithRed:0.16 green:0.16 blue:0.25 alpha:1.0];
    [self.configModuleTabSeg addTarget:self action:@selector(moduleTabSwitched:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:self.configModuleTabSeg];
    y += 44.0;

    UIView *moduleCard = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cardW, 480)];
    moduleCard.backgroundColor = [UIColor colorWithRed:0.13 green:0.13 blue:0.20 alpha:1.0];
    moduleCard.layer.cornerRadius = 16.0;
    moduleCard.layer.borderWidth = 0.8;
    moduleCard.layer.borderColor = [UIColor colorWithRed:0.40 green:0.65 blue:1.0 alpha:0.35].CGColor;
    [scroll addSubview:moduleCard];

    CGFloat cy = 12.0;

    self.tabSwitchRowView = [[UIView alloc] initWithFrame:CGRectMake(12, cy, cardW - 24, 40)];
    self.tabSwitchRowView.backgroundColor = [UIColor colorWithRed:0.18 green:0.26 blue:0.36 alpha:0.75];
    self.tabSwitchRowView.layer.cornerRadius = 10.0;
    [moduleCard addSubview:self.tabSwitchRowView];

    self.tabSwitchTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 5, cardW - 92, 30)];
    self.tabSwitchTitleLabel.textColor = [UIColor colorWithRed:0.60 green:0.95 blue:0.80 alpha:1.0];
    self.tabSwitchTitleLabel.font = [UIFont boldSystemFontOfSize:12.5];
    [self.tabSwitchRowView addSubview:self.tabSwitchTitleLabel];

    self.tabEnableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 80, 5, 50, 30)];
    [self.tabEnableSwitch addTarget:self action:@selector(saveCurrentTabFieldsToDisk) forControlEvents:UIControlEventValueChanged];
    [self.tabSwitchRowView addSubview:self.tabEnableSwitch];

    cy += 48.0;

    self.endpointField = [self createStyledTextFieldWithFrame:CGRectMake(12, cy, cardW - 24, 38)
                                                  placeholder:@"🔗 独立接口地址 (如 https://generativelanguage.googleapis.com)"];
    [self.endpointField addTarget:self action:@selector(apiInputFieldsDidChange) forControlEvents:UIControlEventEditingChanged];
    [moduleCard addSubview:self.endpointField];
    cy += 46.0;

    self.apiKeyField = [self createStyledTextFieldWithFrame:CGRectMake(12, cy, cardW - 24, 38)
                                                placeholder:@"🔑 独立 API Key (AIza... 或 sk-...)"];
    [self.apiKeyField addTarget:self action:@selector(apiInputFieldsDidChange) forControlEvents:UIControlEventEditingChanged];
    [moduleCard addSubview:self.apiKeyField];
    cy += 46.0;

    self.proxyField = [self createStyledTextFieldWithFrame:CGRectMake(12, cy, cardW - 24, 38)
                                               placeholder:@"🌐 独立代理端口 (如 7890，国内接口直连留空)"];
    [self.proxyField addTarget:self action:@selector(saveCurrentTabFieldsToDisk) forControlEvents:UIControlEventEditingChanged];
    [moduleCard addSubview:self.proxyField];
    cy += 46.0;

    self.modelField = [self createStyledTextFieldWithFrame:CGRectMake(12, cy, cardW - 142, 38)
                                               placeholder:@"🤖 模型名称 (可手动输入或右侧获取)"];
    [self.modelField addTarget:self action:@selector(saveCurrentTabFieldsToDisk) forControlEvents:UIControlEventEditingChanged];
    [moduleCard addSubview:self.modelField];

    self.fetchModelsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.fetchModelsBtn.frame = CGRectMake(cardW - 124, cy, 112, 38);
    self.fetchModelsBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.55 blue:0.95 alpha:0.95];
    self.fetchModelsBtn.layer.cornerRadius = 10.0;
    [self.fetchModelsBtn setTitle:@"🔍 点击获取模型" forState:UIControlStateNormal];
    [self.fetchModelsBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.fetchModelsBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
    [self.fetchModelsBtn addTarget:self action:@selector(fetchModelsForCurrentTabTapped) forControlEvents:UIControlEventTouchUpInside];
    [moduleCard addSubview:self.fetchModelsBtn];
    cy += 46.0;

    self.modelSectionHintLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, cardW - 28, 20)];
    self.modelSectionHintLabel.text = @"📋 当前模块可用模型选择 (点击下方直接切换生效)：";
    self.modelSectionHintLabel.textColor = [UIColor colorWithRed:0.65 green:0.85 blue:1.0 alpha:1.0];
    self.modelSectionHintLabel.font = [UIFont boldSystemFontOfSize:12.0];
    [moduleCard addSubview:self.modelSectionHintLabel];
    cy += 22.0;

    self.modelsTableView = [[UITableView alloc] initWithFrame:CGRectMake(8, cy, cardW - 16, 210) style:UITableViewStylePlain];
    self.modelsTableView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    self.modelsTableView.layer.cornerRadius = 10.0;
    self.modelsTableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    self.modelsTableView.delegate = self;
    self.modelsTableView.dataSource = self;
    self.modelsTableView.rowHeight = 36.0;
    [moduleCard addSubview:self.modelsTableView];

    scroll.contentSize = CGSizeMake(w, y + 500.0);

    self.currentEditingTab = AGConfigTabNativeLive;
    [self loadFieldsForTab:AGConfigTabNativeLive];
}

- (UITextField *)createStyledTextFieldWithFrame:(CGRect)frame placeholder:(NSString *)placeholder {
    UITextField *tf = [[UITextField alloc] initWithFrame:frame];
    tf.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    tf.layer.cornerRadius = 10.0;
    tf.layer.borderWidth = 0.7;
    tf.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    tf.textColor = [UIColor whiteColor];
    tf.font = [UIFont systemFontOfSize:13.0];
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.returnKeyType = UIReturnKeyDone;
    tf.delegate = self;
    tf.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1.0]}];
    return tf;
}

- (void)globalControlChanged {
    NSMutableDictionary *p = loadGeminiPrefs();
    p[@"Gemini_Enabled"] = @(self.masterEnableSwitch.isOn);
    saveGeminiPrefs(p);
}

- (void)moduleTabSwitched:(UISegmentedControl *)seg {
    [self saveCurrentTabFieldsToDisk];
    self.currentEditingTab = (AGConfigTab)seg.selectedSegmentIndex;
    [self loadFieldsForTab:self.currentEditingTab];
}

- (void)loadFieldsForTab:(AGConfigTab)tab {
    self.tabEnableSwitch.enabled = YES;
    self.tabEnableSwitch.on = agIsTabEnabled(tab);

    if (tab == AGConfigTabNativeLive) {
        self.tabSwitchTitleLabel.text = @"🎙️ 启用「纯正 Live 模式」 (底部显示🎙️按钮)";
    } else if (tab == AGConfigTabVideoAI) {
        self.tabSwitchTitleLabel.text = @"📹 启用「独立视频 AI 模式」 (底部显示📹按钮)";
    } else {
        self.tabSwitchTitleLabel.text = @"💬 启用「纯文本模式」 (底部显示💬按钮)";
    }

    self.endpointField.text = agEndpointForTab(tab);
    self.apiKeyField.text = agAPIKeyForTab(tab);
    self.proxyField.text = agProxyForTab(tab);
    self.modelField.text = agModelForTab(tab);

    [self.currentTabModels removeAllObjects];
    [self.currentTabModels addObjectsFromArray:agCachedModelsForTab(tab)];
    [self.modelsTableView reloadData];
    [self updateFetchButtonVisibility];
}

- (void)updateFetchButtonVisibility {
    NSString *ep = [self.endpointField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key = [self.apiKeyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL canFetch = (ep.length >= 5 && key.length >= 5);
    CGFloat cardW = self.endpointField.superview.bounds.size.width;
    CGFloat cy = self.modelField.frame.origin.y;

    [UIView animateWithDuration:0.18 animations:^{
        self.fetchModelsBtn.hidden = !canFetch;
        self.fetchModelsBtn.alpha = canFetch ? 1.0 : 0.0;
        if (canFetch) {
            self.modelField.frame = CGRectMake(12, cy, cardW - 142, 38);
        } else {
            self.modelField.frame = CGRectMake(12, cy, cardW - 24, 38);
        }
    }];
}

- (void)apiInputFieldsDidChange {
    [self updateFetchButtonVisibility];
    [self saveCurrentTabFieldsToDisk];
}

- (void)saveCurrentTabFieldsToDisk {
    NSMutableDictionary *p = loadGeminiPrefs();
    NSString *prefix = agPrefixForTab(self.currentEditingTab);

    NSString *ep = [self.endpointField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key = [self.apiKeyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *proxy = [self.proxyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *model = [self.modelField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    p[[NSString stringWithFormat:@"%@_Enabled", prefix]] = @(self.tabEnableSwitch.isOn);
    p[[NSString stringWithFormat:@"%@_Endpoint", prefix]] = (ep.length > 0) ? ep : @"https://generativelanguage.googleapis.com";
    p[[NSString stringWithFormat:@"%@_APIKey", prefix]] = key ?: @"";
    p[[NSString stringWithFormat:@"%@_ProxyPort", prefix]] = proxy ?: @"";
    if (model.length > 0) {
        p[[NSString stringWithFormat:@"%@_Model", prefix]] = model;
    }
    saveGeminiPrefs(p);
}

- (void)fetchModelsForCurrentTabTapped {
    [self.view endEditing:YES];
    [self saveCurrentTabFieldsToDisk];

    AGConfigTab tab = self.currentEditingTab;
    NSString *ep = self.endpointField.text ?: @"";
    NSString *key = self.apiKeyField.text ?: @"";
    NSString *proxy = self.proxyField.text ?: @"";

    [self.fetchModelsBtn setTitle:@"⏳ 获取中..." forState:UIControlStateNormal];
    self.fetchModelsBtn.enabled = NO;
    self.modelSectionHintLabel.text = @"☁️ 正在连接接口验证并筛选真正可用的模型...";

    agFetchCloudModelsForTab(tab, ep, key, proxy, ^(BOOL success, NSArray<NSDictionary *> *models, NSString *errorMsg) {
        self.fetchModelsBtn.enabled = YES;
        [self.fetchModelsBtn setTitle:@"🔍 点击获取模型" forState:UIControlStateNormal];

        if (!success) {
            self.modelSectionHintLabel.text = [NSString stringWithFormat:@"❌ %@", errorMsg ?: @"获取失败"];
            self.modelSectionHintLabel.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0];
            return;
        }

        self.modelSectionHintLabel.textColor = [UIColor colorWithRed:0.45 green:0.95 blue:0.65 alpha:1.0];
        self.modelSectionHintLabel.text = [NSString stringWithFormat:@"✅ 成功获取 %lu 个可用模型 (点击下方直接选用)：", (unsigned long)models.count];

        [self.currentTabModels removeAllObjects];
        [self.currentTabModels addObjectsFromArray:models];

        NSMutableDictionary *p = loadGeminiPrefs();
        NSString *prefix = agPrefixForTab(tab);
        p[[NSString stringWithFormat:@"%@_CachedModels", prefix]] = models;
        if (models.count > 0) {
            NSString *firstID = models.firstObject[@"id"];
            self.modelField.text = firstID;
            p[[NSString stringWithFormat:@"%@_Model", prefix]] = firstID;
        }
        saveGeminiPrefs(p);
        [self.modelsTableView reloadData];
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.currentTabModels.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"AGSettingsModelCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    }
    NSDictionary *m = self.currentTabModels[indexPath.row];
    NSString *mID = m[@"id"];
    NSString *mTitle = m[@"title"] ?: mID;
    BOOL isSelected = [mID isEqualToString:self.modelField.text];
    cell.textLabel.text = isSelected ? [NSString stringWithFormat:@"✅ %@", mTitle] : [NSString stringWithFormat:@"    %@", mTitle];
    cell.textLabel.textColor = isSelected ? [UIColor colorWithRed:0.45 green:0.95 blue:0.65 alpha:1.0] : [UIColor whiteColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *m = self.currentTabModels[indexPath.row];
    NSString *mID = m[@"id"];
    if (mID) {
        self.modelField.text = mID;
        [self saveCurrentTabFieldsToDisk];
        [self.modelsTableView reloadData];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self saveCurrentTabFieldsToDisk];
    return YES;
}

- (void)saveAndDismissTapped {
    [self.view endEditing:YES];
    [self globalControlChanged];
    [self saveCurrentTabFieldsToDisk];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// ==================== 4. 手机《设置》App 注入入口与桌面拦截钩子 ====================
%hook UINavigationController
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.apple.Preferences"]) {
        UIViewController *topVC = self.topViewController;
        if (topVC && ![topVC isKindOfClass:[AngelGuardianSettingsViewController class]] && topVC.navigationItem && !topVC.navigationItem.rightBarButtonItem) {
            UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"✨天使守护" style:UIBarButtonItemStyleDone target:self action:@selector(angelGuardianOpenPrefsModal)];
            btn.tintColor = [UIColor colorWithRed:0.55 green:0.36 blue:0.96 alpha:1.0];
            topVC.navigationItem.rightBarButtonItem = btn;
        }
    }
}

%new
- (void)angelGuardianOpenPrefsModal {
    AngelGuardianSettingsViewController *vc = [[AngelGuardianSettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.navigationBar.tintColor = [UIColor whiteColor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}
%end

%hook NSBundle
- (NSDictionary *)infoDictionary {
    NSDictionary *orig = %orig;
    if (self == [NSBundle mainBundle] && orig) {
        NSMutableDictionary *mutableInfo = [orig mutableCopy];
        mutableInfo[@"NSMicrophoneUsageDescription"] = @"天使守护需要使用麦克风进行官方 WebSocket Live 实时语音对讲";
        mutableInfo[@"NSCameraUsageDescription"] = @"天使守护需要使用相机进行独立实景视频 AI 对话";
        mutableInfo[@"NSContactsUsageDescription"] = @"天使守护需要访问通讯录为您拨打电话与发送短信";
        return mutableInfo;
    }
    return orig;
}
%end

%hook SBLockHardwareButtonActions
- (void)performLongPressActions {
    if ([[GeminiAssistantManager sharedManager] isTweakEnabled] && !isDeviceCurrentlyLocked()) {
        [[GeminiAssistantManager sharedManager] triggerFromSystemHook];
        return;
    }
    %orig;
}
%end

%hook SBHomeHardwareButtonActions
- (void)performLongPressActions {
    if ([[GeminiAssistantManager sharedManager] isTweakEnabled] && !isDeviceCurrentlyLocked()) {
        [[GeminiAssistantManager sharedManager] triggerFromSystemHook];
        return;
    }
    %orig;
}
%end

%hook SBAssistantController
- (void)_activateSiriWithContext:(id)context {
    if ([[GeminiAssistantManager sharedManager] isTweakEnabled] && !isDeviceCurrentlyLocked()) {
        [[GeminiAssistantManager sharedManager] triggerFromSystemHook];
        return;
    }
    %orig(context);
}
- (void)_activateSiriForPPTWithOptions:(id)arg1 {
    if ([[GeminiAssistantManager sharedManager] isTweakEnabled] && !isDeviceCurrentlyLocked()) {
        [[GeminiAssistantManager sharedManager] triggerFromSystemHook];
        return;
    }
    %orig(arg1);
}
- (void)handleSiriButtonDownEventFromSource:(NSInteger)source activationEvent:(NSInteger)event {
    if ([[GeminiAssistantManager sharedManager] isTweakEnabled] && !isDeviceCurrentlyLocked()) {
        [[GeminiAssistantManager sharedManager] triggerFromSystemHook];
        return;
    }
    %orig(source, event);
}
- (BOOL)activateIgnoringTouches:(BOOL)arg1 {
    if ([[GeminiAssistantManager sharedManager] isTweakEnabled] && !isDeviceCurrentlyLocked()) {
        [[GeminiAssistantManager sharedManager] triggerFromSystemHook];
        return NO;
    }
    return %orig(arg1);
}
%end

%hook SiriPresentationSpringBoardMainScreenViewController
- (void)requestSiriPresentation:(id)arg1 withOptions:(id)arg2 {
    if ([[GeminiAssistantManager sharedManager] isTweakEnabled] && !isDeviceCurrentlyLocked()) {
        if ([self respondsToSelector:@selector(dismissSiriViewController:withReason:)]) {
            [self dismissSiriViewController:nil withReason:0];
        } else if ([self respondsToSelector:@selector(dismissSiriViewController:)]) {
            [self dismissSiriViewController:nil];
        }
        [[GeminiAssistantManager sharedManager] triggerFromSystemHook];
        return;
    }
    %orig(arg1, arg2);
}
- (void)_activateSiriWithContext:(id)context {
    if ([[GeminiAssistantManager sharedManager] isTweakEnabled] && !isDeviceCurrentlyLocked()) {
        [[GeminiAssistantManager sharedManager] triggerFromSystemHook];
        return;
    }
    %orig(context);
}
- (void)viewWillAppear:(BOOL)animated {
    if ([[GeminiAssistantManager sharedManager] isTweakEnabled] && !isDeviceCurrentlyLocked()) {
        self.view.hidden = YES;
        self.view.alpha = 0.0;
        if ([self respondsToSelector:@selector(dismissSiriViewController:withReason:)]) {
            [self dismissSiriViewController:nil withReason:0];
        } else if ([self respondsToSelector:@selector(dismissSiriViewController:)]) {
            [self dismissSiriViewController:nil];
        }
        return;
    }
    %orig(animated);
}
%end
