// ==============================================================================
// Project: wangjianchengsiri (Angel Guardian v4.1.0)
// Target: iOS 15.0 - 17.x Dopamine Rootless (arm64 + arm64e PAC)
// ==============================================================================

// ==============================================================================
// 软件名称: 天使守护 (Angel Guardian v4.1.0 - 双核Live对讲 + 独立视频AI + 零旋转纯净柔光版)
// 适配环境: Dopamine 3.x 全系列越狱机型与系统 (iOS 15.0 - 17.x, arm64 / arm64e)
// ==============================================================================

#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <Contacts/Contacts.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>

// ==================== 配置模块枚举 ====================
typedef NS_ENUM(NSInteger, AGConfigTab) {
    AGConfigTabTextLive = 0,   // 纯文本流式实时交流
    AGConfigTabNativeLive = 1, // 纯正 Live API 交流
    AGConfigTabVideoAI = 2     // 独立视频 AI 模式
};

static NSString * const kAGPrefsChangedNotification = @"com.custom.geminisirioverlay.prefsChanged";
static NSMutableDictionary *gCachedPrefs = nil;

// ==================== 跨进程共享配置 (内存高速缓存 + Darwin 通知同步) ====================
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

// ==================== 系统私有接口声明 (兼容 iOS 15.0 - 17.x 全机型) ====================
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

// ==================== 通用辅助：读取与保存三大独立模块的配置 ====================
static NSString *agPrefixForTab(AGConfigTab tab) {
    switch (tab) {
        case AGConfigTabTextLive:   return @"AG_Text";
        case AGConfigTabNativeLive: return @"AG_Live";
        case AGConfigTabVideoAI:    return @"AG_Video";
    }
    return @"AG_Text";
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
    if ((!val || val.length == 0) && tab != AGConfigTabVideoAI) {
        val = p[@"Gemini_APIKey"] ?: @"";
    }
    return val ?: @"";
}

static NSString *agProxyForTab(AGConfigTab tab) {
    NSDictionary *p = loadGeminiPrefs();
    NSString *key = [NSString stringWithFormat:@"%@_ProxyPort", agPrefixForTab(tab)];
    NSString *val = p[key];
    if (!val && tab != AGConfigTabVideoAI) {
        val = p[@"Gemini_ProxyPort"] ?: @"";
    }
    return val ?: @"";
}

static NSString *agModelForTab(AGConfigTab tab) {
    NSDictionary *p = loadGeminiPrefs();
    NSString *key = [NSString stringWithFormat:@"%@_Model", agPrefixForTab(tab)];
    NSString *val = p[key];
    if (!val || val.length == 0) {
        if (tab == AGConfigTabNativeLive) return @"models/gemini-2.0-flash-exp";
        if (tab == AGConfigTabVideoAI) return @"models/gemini-2.5-flash";
        return p[@"Gemini_Model"] ?: @"models/gemini-2.5-flash";
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
            @{@"id": @"models/gemini-2.0-flash-exp", @"title": @"🎙️ gemini-2.0-flash-exp (原生Live音频流)"},
            @{@"id": @"gpt-4o-realtime-preview", @"title": @"⚡ gpt-4o-realtime-preview (OpenAI Realtime)"},
            @{@"id": @"qwen-omni-turbo-realtime", @"title": @"🔥 qwen-omni-turbo-realtime (阿里千问实时音频)"},
            @{@"id": @"glm-4-voice", @"title": @"✨ glm-4-voice (智谱原生语音对讲)"}
        ];
    } else if (tab == AGConfigTabVideoAI) {
        return @[
            @{@"id": @"models/gemini-2.5-flash", @"title": @"📹 gemini-2.5-flash (极速多模态视觉)"},
            @{@"id": @"gpt-4o", @"title": @"👁️ gpt-4o (OpenAI 旗舰视觉)"},
            @{@"id": @"qwen-vl-max", @"title": @"🔥 qwen-vl-max (通义千问视觉旗舰)"},
            @{@"id": @"glm-4v-plus", @"title": @"✨ glm-4v-plus (智谱高清视觉)"}
        ];
    }
    return @[
        @{@"id": @"models/gemini-2.5-flash", @"title": @"🚀 gemini-2.5-flash (流式极速对话)"},
        @{@"id": @"deepseek-chat", @"title": @"🔥 deepseek-chat (DeepSeek V3 极速流式)"},
        @{@"id": @"qwen-max", @"title": @"⚡ qwen-max (阿里通义千问旗舰)"},
        @{@"id": @"gpt-4o", @"title": @"🤖 gpt-4o (OpenAI 多模态旗舰)"},
        @{@"id": @"claude-3-7-sonnet-latest", @"title": @"✨ claude-3-7-sonnet (Claude 旗舰)"}
    ];
}

static BOOL agIsGoogleNativeProtocol(NSString *endpoint, NSString *model) {
    NSString *lowerEP = [endpoint lowercaseString];
    if ([lowerEP containsString:@"googleapis.com"] || [lowerEP containsString:@"v1beta"]) {
        if (![lowerEP containsString:@"/v1/chat/completions"] && ![lowerEP containsString:@"openai"]) {
            return YES;
        }
    }
    return NO;
}

static NSURLSession *agCreateSessionWithProxy(NSString *proxyStr, id<NSURLSessionDelegate> delegate, NSOperationQueue *queue) {
    NSString *cleanProxy = [proxyStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 25.0;
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

// ==================== 全平台云端模型拉取与按模式智能过滤引擎 ====================
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
            if (!isGoogle) {
                NSString *fallbackURL = [NSString stringWithFormat:@"%@/v1beta/models?pageSize=100&key=%@", cleanEP, cleanKey];
                [[session dataTaskWithURL:[NSURL URLWithString:fallbackURL] completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
                    if (e2 || !d2) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (completion) completion(NO, nil, err.localizedDescription ?: @"网络连接失败，请检查接口地址与代理端口");
                        });
                        return;
                    }
                    NSDictionary *j2 = [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil];
                    NSArray *raw2 = j2[@"models"] ?: j2[@"data"];
                    if (![raw2 isKindOfClass:[NSArray class]] || raw2.count == 0) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (completion) completion(NO, nil, @"未获取到可用模型，请检查 API Key");
                        });
                        return;
                    }
                    NSMutableArray *parsed = [NSMutableArray array];
                    for (NSDictionary *m in raw2) {
                        NSString *mID = m[@"name"] ?: m[@"id"];
                        if (mID.length > 0) {
                            NSString *shortName = [mID stringByReplacingOccurrencesOfString:@"models/" withString:@""];
                            [parsed addObject:@{@"id": mID, @"title": [NSString stringWithFormat:@"✨ %@", shortName]}];
                        }
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(YES, parsed, nil);
                    });
                }] resume];
                return;
            }
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
        NSMutableArray<NSDictionary *> *allBackup = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];

        for (NSDictionary *m in rawModels) {
            if (![m isKindOfClass:[NSDictionary class]]) continue;
            NSString *mID = m[@"name"] ?: m[@"id"];
            if (!mID || mID.length == 0 || [seen containsObject:mID]) continue;
            [seen addObject:mID];

            NSString *lower = [mID lowercaseString];
            if ([lower containsString:@"embedding"] || [lower containsString:@"rerank"] ||
                [lower containsString:@"moderation"] || [lower containsString:@"dall-e"] ||
                [lower containsString:@"imagen"] || [lower containsString:@"veo"] ||
                [lower containsString:@"bison"] || [lower containsString:@"gecko"] ||
                [lower containsString:@"aqa"] || [lower containsString:@"whisper"] ||
                [lower containsString:@"tts-1"]) {
                continue;
            }

            NSString *shortName = [mID stringByReplacingOccurrencesOfString:@"models/" withString:@""];
            NSDictionary *entry = @{@"id": mID, @"title": [NSString stringWithFormat:@"🔥 %@", shortName]};
            [allBackup addObject:entry];

            if (tab == AGConfigTabNativeLive) {
                if ([lower containsString:@"live"] || [lower containsString:@"realtime"] ||
                    [lower containsString:@"audio"] || [lower containsString:@"omni"] ||
                    [lower containsString:@"voice"] || [lower containsString:@"flash"] ||
                    [lower containsString:@"gpt-4o"]) {
                    [filtered addObject:@{@"id": mID, @"title": [NSString stringWithFormat:@"🎙️ %@", shortName]}];
                }
            } else if (tab == AGConfigTabVideoAI) {
                if ([lower containsString:@"gemini"] || [lower containsString:@"vl"] ||
                    [lower containsString:@"vision"] || [lower containsString:@"4o"] ||
                    [lower containsString:@"claude-3"] || [lower containsString:@"omni"] ||
                    [lower containsString:@"pixtral"] || [lower containsString:@"qvq"] ||
                    [lower containsString:@"glm-4v"] || [lower containsString:@"doubao"]) {
                    [filtered addObject:@{@"id": mID, @"title": [NSString stringWithFormat:@"📹 %@", shortName]}];
                }
            } else {
                [filtered addObject:entry];
            }
        }

        NSArray *finalList = (filtered.count > 0) ? filtered : allBackup;
        if (finalList.count > 35) {
            finalList = [finalList subarrayWithRange:NSMakeRange(0, 35)];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (finalList.count == 0) {
                if (completion) completion(NO, nil, @"未过滤出可用对话模型");
            } else {
                if (completion) completion(YES, finalList, nil);
            }
        });
    }] resume];
}

// ==================== 1. 防穿透与防底层App误滑窗口 ====================
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

// ==================== 2. 核心控制器 (双核 Live 对讲 + 独立实景视频 AI + 零旋转纯净柔光) ====================
@interface GeminiAssistantManager : NSObject <AVSpeechSynthesizerDelegate, AVAudioRecorderDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, UITextFieldDelegate, UITableViewDelegate, UITableViewDataSource, NSURLSessionDataDelegate, NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) GeminiPassthroughWindow *overlayWindow;
@property (nonatomic, weak) UIWindow *previousKeyWindow;

@property (nonatomic, strong) UIView *edgeGlowContainer;
@property (nonatomic, strong) CAGradientLayer *screenNeonLayer;
@property (nonatomic, strong) UIView *aiOrbView;
@property (nonatomic, strong) UILabel *titleMaskLabel;
@property (nonatomic, strong) CAGradientLayer *titleGradientLayer;
@property (nonatomic, strong) UILabel *modeBadgeLabel;
@property (nonatomic, strong) NSMutableArray<UIView *> *waveBars;

@property (nonatomic, strong) UIView *innerGlassBox;
@property (nonatomic, strong) UILabel *subStatusLabel;
@property (nonatomic, strong) UITextView *responseTextView;
@property (nonatomic, strong) UILabel *actionBannerLabel;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *micButton;
@property (nonatomic, strong) UIButton *videoToggleButton;

// 实景摄像头画中画组件 + GPU 按需零拷贝编码器
@property (nonatomic, strong) UIView *cameraPreviewContainer;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *cameraPreviewLayer;
@property (nonatomic, strong) UILabel *cameraFlipHintLabel;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) CIContext *gpuImageContext;
@property (nonatomic, assign) CVPixelBufferRef latestPixelBuffer;
@property (nonatomic, assign) BOOL isVideoChatActive;
@property (nonatomic, assign) BOOL useFrontCamera;

// 悬浮窗内模型与模式快捷切换面板
@property (nonatomic, strong) UIView *modelPickerContainer;
@property (nonatomic, strong) UITableView *modelTableView;
@property (nonatomic, strong) UIButton *modeSwitchHeaderBtn;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *availableModelsList;

// 实时语音流识别 + 录音引擎 + 全双工打断 (Barge-in) + 触觉反馈
@property (nonatomic, strong) UIImpactFeedbackGenerator *impactHaptic;
@property (nonatomic, strong) UINotificationFeedbackGenerator *notifyHaptic;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask *recognitionTask;
@property (nonatomic, copy) NSString *livePartialTranscript;

@property (nonatomic, strong) AVAudioRecorder *audioRecorder;
@property (nonatomic, strong) NSTimer *meterTimer;
@property (nonatomic, assign) BOOL hasDetectedSpeech;
@property (nonatomic, assign) NSTimeInterval speechFirstDetectedTime;
@property (nonatomic, assign) NSTimeInterval silenceStartTime;
@property (nonatomic, assign) NSTimeInterval recordStartTime;
@property (nonatomic, assign) BOOL isFollowUpListening;
@property (nonatomic, copy) NSString *audioFilePath;

// 流式 SSE 网络与句子级流式语音播报 + WebSocket Live 通道
@property (nonatomic, strong) AVSpeechSynthesizer *synthesizer;
@property (nonatomic, strong) NSURLSession *streamSession;
@property (nonatomic, strong) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) NSURLSessionWebSocketTask *liveWebSocketTask;
@property (nonatomic, strong) NSMutableString *sseLineBuffer;
@property (nonatomic, strong) NSMutableString *accumulatedReplyText;
@property (nonatomic, strong) NSMutableString *pendingSpeechChunk;
@property (nonatomic, assign) NSInteger activeSpeechUtteranceCount;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *chatHistory;

@property (nonatomic, assign) NSTimeInterval lastTriggerTime;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *builtinAppMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *cachedInstalledApps;

+ (instancetype)sharedManager;
- (BOOL)isTweakEnabled;
- (BOOL)isNativeLiveVoiceMode;
- (BOOL)isDedicatedVideoAIReady;
- (AGConfigTab)currentActiveTab;
- (NSString *)currentVendorBrandName;
- (void)refreshBottomBarLayoutForVideoButton;
- (void)forceKillNativeSiri;
- (void)triggerFromSystemHook;
- (void)dismissOverlay;
@end

static void agDarwinPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadGeminiPrefsCache();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[GeminiAssistantManager sharedManager] refreshBottomBarLayoutForVideoButton];
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
        _audioEngine = [[AVAudioEngine alloc] init];
        _speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
        _gpuImageContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _impactHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        _notifyHaptic = [[UINotificationFeedbackGenerator alloc] init];
        _waveBars = [NSMutableArray array];
        _cachedInstalledApps = [NSMutableDictionary dictionary];
        _chatHistory = [NSMutableArray array];
        _sseLineBuffer = [NSMutableString string];
        _accumulatedReplyText = [NSMutableString string];
        _pendingSpeechChunk = [NSMutableString string];
        _useFrontCamera = NO;
        _audioFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"angel_guardian_v41_voice.m4a"];
        _availableModelsList = [NSMutableArray arrayWithArray:agCachedModelsForTab([self currentActiveTab])];

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

#pragma mark - 三大模式状态读取与路由判定

- (BOOL)isTweakEnabled {
    NSNumber *val = loadGeminiPrefs()[@"Gemini_Enabled"];
    return val ? [val boolValue] : YES;
}

- (BOOL)isAutoSpeakEnabled {
    NSNumber *val = loadGeminiPrefs()[@"Gemini_AutoSpeak"];
    return val ? [val boolValue] : YES;
}

- (BOOL)isNativeLiveVoiceMode {
    NSNumber *val = loadGeminiPrefs()[@"AG_VoiceMode"];
    return (val && [val integerValue] == 1);
}

- (BOOL)isDedicatedVideoAIReady {
    NSDictionary *p = loadGeminiPrefs();
    BOOL videoSwitchOn = [p[@"AG_Video_Enabled"] boolValue];
    NSString *videoKey = [agAPIKeyForTab(AGConfigTabVideoAI) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *videoEndpoint = [agEndpointForTab(AGConfigTabVideoAI) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *videoModel = [agModelForTab(AGConfigTabVideoAI) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return (videoSwitchOn && videoKey.length >= 6 && videoEndpoint.length >= 6 && videoModel.length > 0);
}

- (AGConfigTab)currentActiveTab {
    if (self.isVideoChatActive && [self isDedicatedVideoAIReady]) {
        return AGConfigTabVideoAI;
    }
    return [self isNativeLiveVoiceMode] ? AGConfigTabNativeLive : AGConfigTabTextLive;
}

- (NSString *)currentVendorBrandName {
    NSString *rawModel = [agModelForTab([self currentActiveTab]) stringByReplacingOccurrencesOfString:@"models/" withString:@""];
    NSString *lower = [rawModel lowercaseString];

    if ([lower containsString:@"deepseek"]) return @"DeepSeek";
    if ([lower containsString:@"qwen"] || [lower containsString:@"qvq"]) return @"Qwen";
    if ([lower containsString:@"doubao"] || [lower containsString:@"ep-"]) return @"Doubao";
    if ([lower containsString:@"glm"]) return @"ChatGLM";
    if ([lower containsString:@"kimi"] || [lower containsString:@"moonshot"]) return @"Kimi";
    if ([lower containsString:@"claude"]) return @"Claude";
    if ([lower containsString:@"grok"]) return @"Grok";
    if ([lower containsString:@"chatgpt"] || [lower hasPrefix:@"gpt"] || [lower hasPrefix:@"o1"] || [lower hasPrefix:@"o3"]) return @"ChatGPT";
    if ([lower containsString:@"gemini"] || [lower containsString:@"gemma"]) return @"Gemini";

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^([a-zA-Z]+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:rawModel options:0 range:NSMakeRange(0, rawModel.length)];
    if (match && match.numberOfRanges > 1) {
        NSString *prefix = [rawModel substringWithRange:[match rangeAtIndex:1]];
        if (prefix.length > 0) return [prefix capitalizedString];
    }
    return @"AI Live";
}

- (void)updateHeaderBadges {
    self.titleMaskLabel.text = [self currentVendorBrandName];
    if (self.isVideoChatActive && [self isDedicatedVideoAIReady]) {
        self.modeBadgeLabel.text = @"独立视频AI";
        self.modeBadgeLabel.textColor = [UIColor colorWithRed:0.45 green:0.98 blue:0.75 alpha:1.0];
        self.modeBadgeLabel.layer.borderColor = [UIColor colorWithRed:0.35 green:0.90 blue:0.65 alpha:0.55].CGColor;
    } else if ([self isNativeLiveVoiceMode]) {
        self.modeBadgeLabel.text = @"Live 原声";
        self.modeBadgeLabel.textColor = [UIColor colorWithRed:0.98 green:0.65 blue:0.88 alpha:1.0];
        self.modeBadgeLabel.layer.borderColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.80 alpha:0.55].CGColor;
    } else {
        self.modeBadgeLabel.text = @"实时流";
        self.modeBadgeLabel.textColor = [UIColor colorWithRed:0.55 green:0.85 blue:1.00 alpha:1.0];
        self.modeBadgeLabel.layer.borderColor = [UIColor colorWithRed:0.40 green:0.78 blue:1.00 alpha:0.55].CGColor;
    }
}

#pragma mark - 键盘处理与多场景兼容

- (void)keyboardWillShow:(NSNotification *)notification {
    if (!self.overlayWindow || self.overlayWindow.hidden) return;
    [self stopAllVoiceCaptureAndCancel:YES];
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
        frame.origin.y = screenBounds.size.height - capsuleHeight - 28.0;
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

#pragma mark - iOS 18 级柔光液态玻璃界面构建 (无任何内部旋转动画)

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

    // 1. 全屏边缘静谧柔光层 (仅做柔和透明度呼吸与音量厚度联动，绝不旋转)
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

    CGFloat screenCorner = (screenBounds.size.height >= 812.0) ? 52.0 : 20.0;
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

    // 2. 底部液态晶石胶囊卡片
    CGFloat capsuleHeight = 320.0;
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
    UIVisualEffectView *cardBlurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    cardBlurView.frame = wrapper.bounds;
    cardBlurView.layer.cornerRadius = 32.0;
    cardBlurView.layer.masksToBounds = YES;
    [wrapper addSubview:cardBlurView];

    UIView *content = cardBlurView.contentView;
    content.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.12 alpha:0.78];

    CAGradientLayer *ambientLayer = [CAGradientLayer layer];
    ambientLayer.frame = content.bounds;
    ambientLayer.colors = @[
        (__bridge id)[UIColor colorWithRed:0.45 green:0.25 blue:0.95 alpha:0.24].CGColor,
        (__bridge id)[UIColor colorWithRed:0.95 green:0.25 blue:0.55 alpha:0.12].CGColor,
        (__bridge id)[UIColor colorWithRed:0.00 green:0.78 blue:0.95 alpha:0.18].CGColor
    ];
    ambientLayer.startPoint = CGPointMake(0.0, 0.0);
    ambientLayer.endPoint = CGPointMake(1.0, 1.0);
    [content.layer addSublayer:ambientLayer];

    CAGradientLayer *borderGrad = [CAGradientLayer layer];
    borderGrad.frame = content.bounds;
    borderGrad.colors = @[
        (__bridge id)[UIColor colorWithRed:0.65 green:0.45 blue:1.00 alpha:0.95].CGColor,
        (__bridge id)[UIColor colorWithRed:0.98 green:0.35 blue:0.60 alpha:0.95].CGColor,
        (__bridge id)[UIColor colorWithRed:0.20 green:0.88 blue:0.98 alpha:0.95].CGColor
    ];
    borderGrad.startPoint = CGPointMake(0.0, 0.0);
    borderGrad.endPoint = CGPointMake(1.0, 1.0);

    UIBezierPath *bOuter = [UIBezierPath bezierPathWithRoundedRect:content.bounds cornerRadius:32.0];
    UIBezierPath *bInner = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(content.bounds, 1.6, 1.6) cornerRadius:30.4];
    [bOuter appendPath:bInner];
    bOuter.usesEvenOddFillRule = YES;

    CAShapeLayer *bMask = [CAShapeLayer layer];
    bMask.path = bOuter.CGPath;
    bMask.fillRule = kCAFillRuleEvenOdd;
    borderGrad.mask = bMask;
    [content.layer addSublayer:borderGrad];

    // 左上角静态柔光晶石图标 (无旋转)
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

    UITapGestureRecognizer *orbTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(micButtonTapped)];
    [self.aiOrbView addGestureRecognizer:orbTap];
    [content addSubview:self.aiOrbView];

    UIView *titleWrap = [[UIView alloc] initWithFrame:CGRectMake(56, 17, 105, 30)];
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

    // 模式胶囊徽章
    self.modeBadgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(158, 22, 66, 20)];
    self.modeBadgeLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.modeBadgeLabel.font = [UIFont boldSystemFontOfSize:10.0];
    self.modeBadgeLabel.textAlignment = NSTextAlignmentCenter;
    self.modeBadgeLabel.layer.cornerRadius = 10.0;
    self.modeBadgeLabel.layer.borderWidth = 0.8;
    self.modeBadgeLabel.layer.masksToBounds = YES;
    [content addSubview:self.modeBadgeLabel];
    [self updateHeaderBadges];

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

    self.innerGlassBox = [[UIView alloc] initWithFrame:CGRectMake(16, 56, capsuleWidth - 32, 198)];
    self.innerGlassBox.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.20 alpha:0.55];
    self.innerGlassBox.layer.cornerRadius = 20.0;
    self.innerGlassBox.layer.masksToBounds = YES;
    self.innerGlassBox.layer.borderWidth = 0.8;
    self.innerGlassBox.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    [content addSubview:self.innerGlassBox];

    self.subStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, self.innerGlassBox.bounds.size.width - 28, 20)];
    self.subStatusLabel.textColor = [UIColor colorWithRed:0.58 green:0.78 blue:1.00 alpha:1.0];
    self.subStatusLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.subStatusLabel.text = @"🎙️ 正在倾听您的语音指令...";
    [self.innerGlassBox addSubview:self.subStatusLabel];

    self.responseTextView = [[UITextView alloc] initWithFrame:CGRectMake(10, 34, self.innerGlassBox.bounds.size.width - 20, 156)];
    self.responseTextView.backgroundColor = [UIColor clearColor];
    self.responseTextView.textColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    self.responseTextView.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    self.responseTextView.editable = NO;
    self.responseTextView.selectable = YES;
    self.responseTextView.text = @"“直接开口说话，支持流式秒回与随时插话打断...”";
    [self.innerGlassBox addSubview:self.responseTextView];

    CGFloat camW = 106.0;
    CGFloat camH = 144.0;
    self.cameraPreviewContainer = [[UIView alloc] initWithFrame:CGRectMake(self.innerGlassBox.bounds.size.width - camW - 10, 42, camW, camH)];
    self.cameraPreviewContainer.backgroundColor = [UIColor blackColor];
    self.cameraPreviewContainer.layer.cornerRadius = 14.0;
    self.cameraPreviewContainer.layer.masksToBounds = YES;
    self.cameraPreviewContainer.layer.borderWidth = 1.4;
    self.cameraPreviewContainer.layer.borderColor = [UIColor colorWithRed:0.35 green:0.85 blue:1.0 alpha:0.9].CGColor;
    self.cameraPreviewContainer.hidden = YES;
    [self.innerGlassBox addSubview:self.cameraPreviewContainer];

    self.cameraFlipHintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, camH - 22, camW, 22)];
    self.cameraFlipHintLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
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

    self.micButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.micButton.frame = CGRectMake(16, capsuleHeight - 50, 38, 38);
    self.micButton.backgroundColor = [UIColor colorWithRed:0.92 green:0.28 blue:0.60 alpha:0.88];
    self.micButton.layer.cornerRadius = 19.0;
    [self.micButton setTitle:@"🎙️" forState:UIControlStateNormal];
    self.micButton.titleLabel.font = [UIFont systemFontOfSize:16];
    [self.micButton addTarget:self action:@selector(micButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.micButton];

    self.videoToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.videoToggleButton.frame = CGRectMake(60, capsuleHeight - 50, 38, 38);
    self.videoToggleButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    self.videoToggleButton.layer.cornerRadius = 19.0;
    self.videoToggleButton.layer.borderWidth = 0.8;
    self.videoToggleButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    [self.videoToggleButton setTitle:@"📹" forState:UIControlStateNormal];
    self.videoToggleButton.titleLabel.font = [UIFont systemFontOfSize:16];
    [self.videoToggleButton addTarget:self action:@selector(videoToggleButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.videoToggleButton];

    self.inputField = [[UITextField alloc] initWithFrame:CGRectMake(104, capsuleHeight - 50, capsuleWidth - 182, 38)];
    self.inputField.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    self.inputField.layer.cornerRadius = 19.0;
    self.inputField.layer.borderWidth = 0.7;
    self.inputField.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    self.inputField.textColor = [UIColor whiteColor];
    self.inputField.font = [UIFont systemFontOfSize:13.0];
    self.inputField.returnKeyType = UIReturnKeySend;
    self.inputField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.inputField.delegate = self;
    [content addSubview:self.inputField];

    UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sendBtn.frame = CGRectMake(capsuleWidth - 70, capsuleHeight - 50, 54, 38);
    sendBtn.backgroundColor = [UIColor colorWithRed:0.35 green:0.48 blue:0.98 alpha:0.92];
    sendBtn.layer.cornerRadius = 19.0;
    [sendBtn setTitle:@"发送" forState:UIControlStateNormal];
    [sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    sendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13.5];
    [sendBtn addTarget:self action:@selector(sendButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:sendBtn];

    [self setupEmbeddedModelPickerInView:content width:capsuleWidth height:capsuleHeight];
    [self refreshBottomBarLayoutForVideoButton];
}

- (void)refreshBottomBarLayoutForVideoButton {
    if (!self.overlayWindow || !self.overlayWindow.capsuleWrapper) return;
    CGFloat capsuleWidth = self.overlayWindow.capsuleWrapper.bounds.size.width;
    CGFloat capsuleHeight = self.overlayWindow.capsuleWrapper.bounds.size.height;
    BOOL showVideoBtn = [self isDedicatedVideoAIReady];

    if (!showVideoBtn && self.isVideoChatActive) {
        [self stopCameraSession];
    }

    self.videoToggleButton.hidden = !showVideoBtn;
    if (showVideoBtn) {
        self.inputField.frame = CGRectMake(104, capsuleHeight - 50, capsuleWidth - 182, 38);
        self.inputField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"  直接说话，或点📹边看边聊..." attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.68 alpha:1.0]}];
    } else {
        self.inputField.frame = CGRectMake(60, capsuleHeight - 50, capsuleWidth - 138, 38);
        self.inputField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"  直接说话对讲，或输入文字..." attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.68 alpha:1.0]}];
    }
    [self updateHeaderBadges];
}

#pragma mark - 📹 实景摄像头视频采集 + GPU 按需零拷贝截图引擎 (杜绝发热)

- (void)videoToggleButtonTapped {
    if (![self isDedicatedVideoAIReady]) {
        [self showActionBanner:@"⚠️ 请先在《设置》开启并配置独立视频 AI"];
        return;
    }
    [self.impactHaptic impactOccurred];
    if (self.isVideoChatActive) {
        [self stopCameraSession];
        [self updateHeaderBadges];
        [self showActionBanner:@"📷 已关闭实景视频，切回主语音通道"];
    } else {
        [self startCameraSession];
        [self updateHeaderBadges];
        [self showActionBanner:@"📹 已接入独立视频 AI (对着物体说话即可)"];
    }
}

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
    self.videoToggleButton.backgroundColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.50 alpha:0.92];

    CGFloat fullW = self.innerGlassBox.bounds.size.width;
    [UIView animateWithDuration:0.2 animations:^{
        self.responseTextView.frame = CGRectMake(10, 34, fullW - 130, 156);
    }];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @try {
            if (self.captureSession) {
                [self.captureSession stopRunning];
                self.captureSession = nil;
            }

            AVCaptureSession *session = [[AVCaptureSession alloc] init];
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
                [self.cameraPreviewContainer bringSubviewToFront:self.cameraFlipHintLabel];
            });
        } @catch (NSException *e) {}
    });
}

- (void)stopCameraSession {
    self.isVideoChatActive = NO;
    @synchronized (self) {
        if (self.latestPixelBuffer) {
            CVPixelBufferRelease(self.latestPixelBuffer);
            self.latestPixelBuffer = NULL;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.cameraPreviewContainer.hidden = YES;
        self.videoToggleButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        CGFloat fullW = self.innerGlassBox.bounds.size.width;
        [UIView animateWithDuration:0.2 animations:^{
            self.responseTextView.frame = CGRectMake(10, 34, fullW - 20, 156);
        }];
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.captureSession && self.captureSession.isRunning) {
            [self.captureSession stopRunning];
        }
        self.captureSession = nil;
    });
}

// 零 CPU 开销：平时只保留最新 PixelBuffer 指针引用，绝不进行 CPU 位图重绘
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;
    @synchronized (self) {
        if (self.latestPixelBuffer) {
            CVPixelBufferRelease(self.latestPixelBuffer);
        }
        self.latestPixelBuffer = CVPixelBufferRetain(imageBuffer);
    }
}

// 仅在语音说完、真正需要发往独立视频 AI 的那一刻，用 GPU 极速生成一次 JPEG
- (NSData *)captureSnapshotJPEGOnDemand {
    if (!self.isVideoChatActive) return nil;
    CVPixelBufferRef bufferToEncode = NULL;
    @synchronized (self) {
        if (self.latestPixelBuffer) {
            bufferToEncode = CVPixelBufferRetain(self.latestPixelBuffer);
        }
    }
    if (!bufferToEncode) return nil;

    NSData *jpegData = nil;
    @try {
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:bufferToEncode];
        if (ciImage && self.gpuImageContext) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            jpegData = [self.gpuImageContext JPEGRepresentationOfImage:ciImage
                                                            colorSpace:cs
                                                               options:@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(0.72)}];
            CGColorSpaceRelease(cs);
        }
    } @catch (NSException *e) {}
    CVPixelBufferRelease(bufferToEncode);
    return jpegData;
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

// 音量律动同时微调全屏柔光边缘亮度 (无任何旋转)
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

#pragma mark - 双核全双工 Live 对讲引擎 (硬件级 AEC 回声抑制 + 随时打断 Barge-in)

- (void)forceKillNativeSiri {
    SBAssistantController *ac = [%c(SBAssistantController) sharedInstance];
    if (ac) {
        if ([ac respondsToSelector:@selector(dismissAssistantViewIfNecessaryWithAnimation:)]) {
            [ac dismissAssistantViewIfNecessaryWithAnimation:0];
        } else if ([ac respondsToSelector:@selector(dismissAssistantViewIfNecessary)]) {
            [ac dismissAssistantViewIfNecessary];
        }
    }
}

- (void)startVoiceRecordingWithFollowUp:(BOOL)isFollowUp {
    if (!self.overlayWindow || self.overlayWindow.hidden) return;
    [self forceKillNativeSiri];
    [self stopAllVoiceCaptureAndCancel:YES];

    self.isFollowUpListening = isFollowUp;
    self.livePartialTranscript = @"";
    [self updateHeaderBadges];

    NSString *modeBadge = [self isNativeLiveVoiceMode] ? @"[Live原声]" : @"[实时流]";
    if (self.isVideoChatActive && [self isDedicatedVideoAIReady]) {
        modeBadge = @"[视频AI]";
    }

    if (isFollowUp) {
        self.subStatusLabel.text = [NSString stringWithFormat:@"🎙️ %@ 请继续说或随时插话 (10秒无音自动收起)...", modeBadge];
    } else {
        self.subStatusLabel.text = [NSString stringWithFormat:@"🎙️ %@ 正在全双工倾听 (随时开口对讲)...", modeBadge];
        if (self.chatHistory.count == 0) {
            self.responseTextView.text = [self isDedicatedVideoAIReady]
                ? @"“直接开口实时对讲，或点左下角 📹 接入独立视频 AI 边看边聊...”"
                : @"“直接开口实时对讲，AI 边想边说，您可随时开口插话打断...”";
        }
    }
    [self setWaveBarsLevel:0.0];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @try {
            // 开启 VoiceChat 硬件级回声消除模式 (AEC)，防止扬声器声音误打断
            AVAudioSession *session = [AVAudioSession sharedInstance];
            [session setCategory:AVAudioSessionCategoryPlayAndRecord
                            mode:AVAudioSessionModeVoiceChat
                         options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionMixWithOthers
                           error:nil];
            [session setActive:YES withOptions:0 error:nil];

            NSDictionary *settings = @{
                AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                AVSampleRateKey: @(16000.0),
                AVNumberOfChannelsKey: @(1),
                AVEncoderAudioQualityKey: @(AVAudioQualityMedium)
            };

            [[NSFileManager defaultManager] removeItemAtPath:self.audioFilePath error:nil];
            NSError *err = nil;
            self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:self.audioFilePath] settings:settings error:&err];
            if (self.audioRecorder && !err) {
                self.audioRecorder.delegate = self;
                self.audioRecorder.meteringEnabled = YES;
                [self.audioRecorder prepareToRecord];
                [self.audioRecorder record];
            }

            AGConfigTab activeTab = [self currentActiveTab];
            BOOL useRealtimeSTT = (activeTab == AGConfigTabTextLive) ||
                                  (activeTab == AGConfigTabVideoAI && !agIsGoogleNativeProtocol(agEndpointForTab(activeTab), agModelForTab(activeTab)));

            if (useRealtimeSTT && self.speechRecognizer && self.speechRecognizer.isAvailable) {
                [self startRealtimeSpeechRecognitionEngine];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                self.hasDetectedSpeech = NO;
                self.speechFirstDetectedTime = 0;
                self.silenceStartTime = 0;
                self.recordStartTime = [[NSDate date] timeIntervalSince1970];
                [self.meterTimer invalidate];
                self.meterTimer = [NSTimer timerWithTimeInterval:0.06 target:self selector:@selector(updateAudioMeters) userInfo:nil repeats:YES];
                [[NSRunLoop mainRunLoop] addTimer:self.meterTimer forMode:NSRunLoopCommonModes];
            });
        } @catch (NSException *e) {}
    });
}

- (void)startRealtimeSpeechRecognitionEngine {
    @try {
        if (self.recognitionTask) {
            [self.recognitionTask cancel];
            self.recognitionTask = nil;
        }
        if (self.audioEngine.isRunning) {
            [self.audioEngine stop];
            [self.audioEngine.inputNode removeTapOnBus:0];
        }

        self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.recognitionRequest.shouldReportPartialResults = YES;
        if (@available(iOS 13.0, *)) {
            self.recognitionRequest.requiresOnDeviceRecognition = NO;
        }

        AVAudioInputNode *inputNode = self.audioEngine.inputNode;
        AVAudioFormat *recordingFormat = [inputNode outputFormatForBus:0];
        [inputNode removeTapOnBus:0];
        __weak typeof(self) weakSelf = self;
        [inputNode installTapOnBus:0 bufferSize:1024 format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
            [weakSelf.recognitionRequest appendAudioPCMBuffer:buffer];
        }];

        [self.audioEngine prepare];
        [self.audioEngine startAndReturnError:nil];

        self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
            if (result) {
                NSString *transcribed = result.bestTranscription.formattedString;
                if (transcribed.length > 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        weakSelf.livePartialTranscript = transcribed;
                        if ([weakSelf.synthesizer isSpeaking] && transcribed.length >= 2) {
                            [weakSelf interruptAISpeakingForBargeIn];
                        }
                        if (![weakSelf.synthesizer isSpeaking]) {
                            weakSelf.responseTextView.text = [NSString stringWithFormat:@"🗣️ “%@...”", transcribed];
                        }
                    });
                }
            }
        }];
    } @catch (NSException *e) {}
}

- (void)interruptAISpeakingForBargeIn {
    if ([self.synthesizer isSpeaking]) {
        [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    }
    [self.impactHaptic impactOccurred];
    self.activeSpeechUtteranceCount = 0;
    [self.pendingSpeechChunk setString:@""];
    if (self.currentTask) {
        [self.currentTask cancel];
        self.currentTask = nil;
    }
    self.subStatusLabel.text = @"⚡ 已打断 AI，正在倾听您的新指令...";
}

- (void)updateAudioMeters {
    if (!self.audioRecorder || !self.audioRecorder.isRecording) return;
    [self.audioRecorder updateMeters];
    float power = [self.audioRecorder averagePowerForChannel:0];
    float peak = [self.audioRecorder peakPowerForChannel:0];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    if ([self.synthesizer isSpeaking] || self.activeSpeechUtteranceCount > 0) {
        self.recordStartTime = now;
        if (power > -15.0f && peak > -5.5f) {
            [self interruptAISpeakingForBargeIn];
            self.hasDetectedSpeech = YES;
            self.speechFirstDetectedTime = now;
            self.silenceStartTime = 0;
        }
        return;
    }

    if (power > -37.0f || peak > -27.0f) {
        if (!self.hasDetectedSpeech) {
            self.hasDetectedSpeech = YES;
            self.speechFirstDetectedTime = now;
            self.subStatusLabel.text = self.isVideoChatActive ? @"📹 正在实时捕捉您的声音与画面..." : @"🔊 正在实时接收您的语音 (说完秒回)...";
        }
        self.silenceStartTime = 0;
        CGFloat activeLevel = MAX(0.18, MIN(1.0, (power + 40.0) / 32.0));
        [self setWaveBarsLevel:activeLevel];
    } else {
        [self setWaveBarsLevel:0.0];
        if (self.hasDetectedSpeech) {
            if (now - self.speechFirstDetectedTime < 0.40) {
                return;
            }
            if (self.silenceStartTime == 0) {
                self.silenceStartTime = now;
            } else if (now - self.silenceStartTime >= 0.72) {
                [self finishVoiceTurnAndDispatch];
            }
        } else if (now - self.recordStartTime >= 10.0) {
            [self stopAllVoiceCaptureAndCancel:YES];
            [self dismissOverlay];
        }
    }
}

- (void)stopAllVoiceCaptureAndCancel:(BOOL)cancel {
    [self.meterTimer invalidate];
    self.meterTimer = nil;
    [self setWaveBarsLevel:0.0];

    if (self.recognitionTask) {
        [self.recognitionTask finish];
        self.recognitionTask = nil;
    }
    if (self.recognitionRequest) {
        [self.recognitionRequest endAudio];
        self.recognitionRequest = nil;
    }
    if (self.audioEngine.isRunning) {
        [self.audioEngine stop];
        @try { [self.audioEngine.inputNode removeTapOnBus:0]; } @catch (NSException *e) {}
    }

    if (self.audioRecorder && self.audioRecorder.isRecording) {
        [self.audioRecorder stop];
    }
    self.audioRecorder = nil;
    if (cancel) {
        [[NSFileManager defaultManager] removeItemAtPath:self.audioFilePath error:nil];
    }
}

- (void)finishVoiceTurnAndDispatch {
    NSString *recognizedText = [self.livePartialTranscript stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self stopAllVoiceCaptureAndCancel:NO];

    NSData *audioData = [NSData dataWithContentsOfFile:self.audioFilePath];
    AGConfigTab activeTab = [self currentActiveTab];
    NSString *ep = agEndpointForTab(activeTab);
    NSString *model = agModelForTab(activeTab);
    BOOL isGoogle = agIsGoogleNativeProtocol(ep, model);

    if (recognizedText.length > 0 && [self tryExecuteDirectLocalCommand:recognizedText]) {
        return;
    }

    if (activeTab == AGConfigTabNativeLive || (isGoogle && recognizedText.length == 0)) {
        if (audioData.length < 400) {
            [self startVoiceRecordingWithFollowUp:YES];
            return;
        }
        [self dispatchAudioOrMultimodalRequestWithAudio:audioData transcript:recognizedText forTab:activeTab];
        return;
    }

    if (recognizedText.length > 0) {
        [self dispatchStreamingRequestWithText:recognizedText audioData:nil forTab:activeTab];
    } else if (audioData.length >= 400 && isGoogle) {
        [self dispatchAudioOrMultimodalRequestWithAudio:audioData transcript:nil forTab:activeTab];
    } else {
        [self startVoiceRecordingWithFollowUp:YES];
    }
}

- (void)micButtonTapped {
    [self.impactHaptic impactOccurred];
    [self.inputField resignFirstResponder];
    if ([self.synthesizer isSpeaking]) {
        [self interruptAISpeakingForBargeIn];
        [self startVoiceRecordingWithFollowUp:YES];
        return;
    }
    if (self.audioRecorder && self.audioRecorder.isRecording) {
        [self finishVoiceTurnAndDispatch];
    } else {
        [self startVoiceRecordingWithFollowUp:NO];
    }
}

- (void)sendButtonTapped {
    [self.impactHaptic impactOccurred];
    if (self.inputField.text.length > 0) {
        [self textFieldShouldReturn:self.inputField];
    } else if (self.audioRecorder && self.audioRecorder.isRecording) {
        [self finishVoiceTurnAndDispatch];
    }
}

#pragma mark - 3. 手机操作引擎 (打开应用、拨打电话、发送短信)

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

    if (responseText.length < 30 && [self tryExecuteDirectLocalCommand:responseText]) {
        if (outExecuted) *outExecuted = YES;
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

#pragma mark - 4. 悬浮窗右上角 ⚙️ 快捷切换面板 (支持一键切模式 + 同步当前模块模型)

- (void)setupEmbeddedModelPickerInView:(UIView *)parent width:(CGFloat)w height:(CGFloat)h {
    self.modelPickerContainer = [[UIView alloc] initWithFrame:CGRectMake(16, 56, w - 32, 198)];
    self.modelPickerContainer.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.14 alpha:0.99];
    self.modelPickerContainer.layer.cornerRadius = 20.0;
    self.modelPickerContainer.layer.borderWidth = 1.2;
    self.modelPickerContainer.layer.borderColor = [UIColor colorWithRed:0.45 green:0.70 blue:1.0 alpha:0.45].CGColor;
    self.modelPickerContainer.clipsToBounds = YES;
    self.modelPickerContainer.hidden = YES;
    [parent addSubview:self.modelPickerContainer];

    CGFloat mw = self.modelPickerContainer.bounds.size.width;

    self.modeSwitchHeaderBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.modeSwitchHeaderBtn.frame = CGRectMake(10, 7, mw - 156, 26);
    self.modeSwitchHeaderBtn.backgroundColor = [UIColor colorWithRed:0.42 green:0.25 blue:0.85 alpha:0.65];
    self.modeSwitchHeaderBtn.layer.cornerRadius = 7.0;
    [self.modeSwitchHeaderBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.modeSwitchHeaderBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.0];
    [self.modeSwitchHeaderBtn addTarget:self action:@selector(quickSwitchVoiceModeInOverlay) forControlEvents:UIControlEventTouchUpInside];
    [self.modelPickerContainer addSubview:self.modeSwitchHeaderBtn];

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

    self.modelTableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 38, mw, 160) style:UITableViewStylePlain];
    self.modelTableView.backgroundColor = [UIColor clearColor];
    self.modelTableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    self.modelTableView.delegate = self;
    self.modelTableView.dataSource = self;
    self.modelTableView.rowHeight = 38.0;
    self.modelTableView.delaysContentTouches = NO;
    [self.modelPickerContainer addSubview:self.modelTableView];
}

- (void)refreshOverlayPickerHeader {
    AGConfigTab tab = [self currentActiveTab];
    if (tab == AGConfigTabVideoAI) {
        [self.modeSwitchHeaderBtn setTitle:@"📹 当前：独立视频AI通道 (点击切语音)" forState:UIControlStateNormal];
    } else if (tab == AGConfigTabNativeLive) {
        [self.modeSwitchHeaderBtn setTitle:@"🔄 语音：纯正 Live API (点击切文本流)" forState:UIControlStateNormal];
    } else {
        [self.modeSwitchHeaderBtn setTitle:@"🔄 语音：纯文本实时流 (点击切纯Live)" forState:UIControlStateNormal];
    }
    [self.availableModelsList removeAllObjects];
    [self.availableModelsList addObjectsFromArray:agCachedModelsForTab(tab)];
    [self.modelTableView reloadData];
}

- (void)quickSwitchVoiceModeInOverlay {
    [self.impactHaptic impactOccurred];
    if (self.isVideoChatActive) {
        [self stopCameraSession];
    } else {
        NSMutableDictionary *p = loadGeminiPrefs();
        BOOL curLive = [self isNativeLiveVoiceMode];
        p[@"AG_VoiceMode"] = curLive ? @(0) : @(1);
        saveGeminiPrefs(p);
    }
    [self refreshOverlayPickerHeader];
    [self updateHeaderBadges];
    [self showActionBanner:([self isNativeLiveVoiceMode] ? @"🎙️ 已切换为：纯正 Live API 交流" : @"⚡ 已切换为：纯文本流式实时交流")];
}

- (void)togglePureModelPicker {
    [self.impactHaptic impactOccurred];
    [self.inputField resignFirstResponder];
    self.modelPickerContainer.hidden = !self.modelPickerContainer.hidden;
    self.overlayWindow.lockFullScreenTouch = !self.modelPickerContainer.hidden;

    if (!self.modelPickerContainer.hidden) {
        [self stopAllVoiceCaptureAndCancel:YES];
        [self refreshOverlayPickerHeader];
        [self.modelPickerContainer.superview bringSubviewToFront:self.modelPickerContainer];
    } else {
        [self startVoiceRecordingWithFollowUp:NO];
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
    NSString *curSaved = agModelForTab([self currentActiveTab]);
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
        AGConfigTab tab = [self currentActiveTab];
        NSMutableDictionary *p = loadGeminiPrefs();
        NSString *modelKey = [NSString stringWithFormat:@"%@_Model", agPrefixForTab(tab)];
        p[modelKey] = selectedID;
        saveGeminiPrefs(p);

        NSString *shortName = [selectedID stringByReplacingOccurrencesOfString:@"models/" withString:@""];
        [self updateHeaderBadges];
        [self showActionBanner:[NSString stringWithFormat:@"✨ 已切换为 %@", shortName]];
        [self.modelTableView reloadData];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.modelPickerContainer.hidden = YES;
            self.overlayWindow.lockFullScreenTouch = NO;
            [self startVoiceRecordingWithFollowUp:NO];
        });
    }
}

- (void)fetchCloudModelsTapped:(UIButton *)sender {
    [self.impactHaptic impactOccurred];
    AGConfigTab tab = [self currentActiveTab];
    NSString *ep = agEndpointForTab(tab);
    NSString *key = agAPIKeyForTab(tab);
    NSString *proxy = agProxyForTab(tab);

    [self showActionBanner:@"☁️ 正在获取当前模块可用模型..."];
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
        [self showActionBanner:[NSString stringWithFormat:@"✅ 已获取 %lu 个真正可用模型", (unsigned long)models.count]];
    });
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSString *text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length > 0) {
        [textField resignFirstResponder];
        textField.text = @"";
        [self stopAllVoiceCaptureAndCancel:YES];
        self.subStatusLabel.text = @"🗣️ 您的提问：";
        self.responseTextView.text = [NSString stringWithFormat:@"“%@”", text];
        if ([self tryExecuteDirectLocalCommand:text]) return YES;
        [self dispatchStreamingRequestWithText:text audioData:nil forTab:[self currentActiveTab]];
    }
    return YES;
}

#pragma mark - 5. 呼出与收起动画 (仅保留静谧柔光呼吸，无任何旋转动画)

- (void)startVisualAnimations {
    [self.screenNeonLayer removeAllAnimations];
    [self.aiOrbView.layer removeAllAnimations];

    // 仅保留柔和的透明度明暗呼吸，不添加任何 rotation 旋转
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

        [self refreshBottomBarLayoutForVideoButton];
        [self.chatHistory removeAllObjects];

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

        AGConfigTab activeTab = [self currentActiveTab];
        if (agAPIKeyForTab(activeTab).length < 5) {
            self.subStatusLabel.text = @"⚠️ 当前模式未配置 API Key";
            self.responseTextView.text = @"请前往手机《设置》App，点击右上角「✨天使守护」配置语音模式或独立视频 AI 的接口与 Key。";
        } else {
            [self startVoiceRecordingWithFollowUp:NO];
        }
    }
}

- (void)dismissOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopAllVoiceCaptureAndCancel:YES];
        [self stopCameraSession];
        [self.inputField resignFirstResponder];
        [self.overlayWindow endEditing:YES];
        self.overlayWindow.lockFullScreenTouch = NO;

        if (self.currentTask) {
            [self.currentTask cancel];
            self.currentTask = nil;
        }
        if (self.liveWebSocketTask) {
            [self.liveWebSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
            self.liveWebSocketTask = nil;
        }
        if ([self.synthesizer isSpeaking]) {
            [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        }
        self.activeSpeechUtteranceCount = 0;

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

#pragma mark - 6. 全平台双协议 SSE 流式引擎 + 纯正 Live 音频引擎 + 独立视频 AI 视觉引擎

- (void)dispatchAudioOrMultimodalRequestWithAudio:(NSData *)audioData transcript:(NSString *)transcript forTab:(AGConfigTab)tab {
    NSString *ep = agEndpointForTab(tab);
    NSString *model = agModelForTab(tab);
    BOOL isGoogle = agIsGoogleNativeProtocol(ep, model);

    if (isGoogle) {
        [self dispatchStreamingRequestWithText:(transcript.length > 0 ? transcript : @"请听这段语音并直接自然回答。") audioData:audioData forTab:tab];
    } else {
        NSString *promptText = transcript.length > 0 ? transcript : @"请回应用户的语音指令。";
        [self dispatchStreamingRequestWithText:promptText audioData:audioData forTab:tab];
    }
}

- (void)dispatchStreamingRequestWithText:(NSString *)userText audioData:(NSData *)audioData forTab:(AGConfigTab)tab {
    NSString *apiKey = agAPIKeyForTab(tab);
    NSString *endpoint = agEndpointForTab(tab);
    NSString *proxy = agProxyForTab(tab);
    NSString *modelPath = agModelForTab(tab);
    NSString *exactModelID = [modelPath stringByReplacingOccurrencesOfString:@"models/" withString:@""];

    if (apiKey.length < 5) {
        self.subStatusLabel.text = @"⚠️ 请前往系统《设置》配置当前模式的 API Key";
        return;
    }

    if ([self.synthesizer isSpeaking]) {
        [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    }
    if (self.currentTask) [self.currentTask cancel];

    [self.sseLineBuffer setString:@""];
    [self.accumulatedReplyText setString:@""];
    [self.pendingSpeechChunk setString:@""];
    self.activeSpeechUtteranceCount = 0;

    [self updateHeaderBadges];
    NSString *modeTag = (tab == AGConfigTabVideoAI) ? @"📹 独立视频AI看图中" : (tab == AGConfigTabNativeLive ? @"🎙️ Live音频流响应中" : @"⚡ 流式秒回中");
    self.subStatusLabel.text = [NSString stringWithFormat:@"%@ (%@)...", modeTag, exactModelID];
    self.responseTextView.text = @"";

    // 按需使用 GPU 提取当前高清摄像头画面帧
    NSData *snapshotJPEG = [self captureSnapshotJPEGOnDemand];

    [self startBackgroundBargeInMonitor];

    NSString *sysPrompt = [NSString stringWithFormat:
        @"请用简明、自然、口语化的中文直接回答，适合实时语音对讲，不要使用复杂的 Markdown 符号。\n"
        @"【身份准则】不要声称自己是 iPhone 语音助手或 Siri。当用户询问你是谁或什么模型时，请如实回答你的真实官方身份与模型版本（当前运行模型：%@）。\n"
        @"【设备控制规则】仅当用户明确要求打开软件/App、拨打电话或发送短信时，输出以下格式标记：\n"
        @"1. 打开应用：[ACTION:{\"type\":\"open_app\",\"app\":\"应用名\"}]\n"
        @"2. 拨打电话：[ACTION:{\"type\":\"make_call\",\"target\":\"姓名或号码\"}]\n"
        @"3. 发送短信：[ACTION:{\"type\":\"send_sms\",\"target\":\"姓名或号码\",\"content\":\"内容\"}]",
        exactModelID];

    BOOL isGoogle = agIsGoogleNativeProtocol(endpoint, modelPath);
    NSMutableURLRequest *request = nil;

    if (isGoogle) {
        NSString *fullModelPath = [modelPath hasPrefix:@"models/"] ? modelPath : [NSString stringWithFormat:@"models/%@", modelPath];
        NSString *urlStr = [NSString stringWithFormat:@"%@/v1beta/%@:streamGenerateContent?alt=sse&key=%@", endpoint, fullModelPath, apiKey];
        request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

        NSMutableArray *userParts = [NSMutableArray array];
        if (snapshotJPEG.length > 0) {
            NSString *b64Img = [snapshotJPEG base64EncodedStringWithOptions:0];
            [userParts addObject:@{@"inline_data": @{@"mime_type": @"image/jpeg", @"data": b64Img}}];
        }
        if (audioData.length > 0) {
            NSString *b64Aud = [audioData base64EncodedStringWithOptions:0];
            [userParts addObject:@{@"inline_data": @{@"mime_type": @"audio/mp4", @"data": b64Aud}}];
        }
        if (userText.length > 0) {
            [userParts addObject:@{@"text": userText}];
        }

        NSMutableArray *contents = [NSMutableArray array];
        for (NSDictionary *hist in self.chatHistory) {
            [contents addObject:@{
                @"role": [hist[@"role"] isEqualToString:@"assistant"] ? @"model" : @"user",
                @"parts": @[@{@"text": hist[@"content"] ?: @""}]
            }];
        }
        [contents addObject:@{@"role": @"user", @"parts": userParts}];

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

        if (snapshotJPEG.length > 0) {
            NSString *b64Img = [snapshotJPEG base64EncodedStringWithOptions:0];
            NSString *dataURI = [NSString stringWithFormat:@"data:image/jpeg;base64,%@", b64Img];
            NSArray *multimodalContent = @[
                @{@"type": @"text", @"text": (userText.length > 0 ? userText : @"请看看我摄像头拍到的实时画面并回答。")},
                @{@"type": @"image_url", @"image_url": @{@"url": dataURI}}
            ];
            [messages addObject:@{@"role": @"user", @"content": multimodalContent}];
        } else {
            [messages addObject:@{@"role": @"user", @"content": (userText.length > 0 ? userText : @"你好")}];
        }

        NSDictionary *body = @{
            @"model": exactModelID,
            @"messages": messages,
            @"stream": @YES
        };
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }

    if (userText.length > 0) {
        [self.chatHistory addObject:@{@"role": @"user", @"content": userText}];
        if (self.chatHistory.count > 10) [self.chatHistory removeObjectAtIndex:0];
    }

    if (self.streamSession) {
        [self.streamSession invalidateAndCancel];
    }
    self.streamSession = agCreateSessionWithProxy(proxy, self, [NSOperationQueue mainQueue]);
    self.currentTask = [self.streamSession dataTaskWithRequest:request];
    [self.currentTask resume];
}

- (void)startBackgroundBargeInMonitor {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            if (!self.audioRecorder || !self.audioRecorder.isRecording) {
                NSDictionary *settings = @{
                    AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: @(16000.0),
                    AVNumberOfChannelsKey: @(1),
                    AVEncoderAudioQualityKey: @(AVAudioQualityLow)
                };
                self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:self.audioFilePath] settings:settings error:nil];
                self.audioRecorder.meteringEnabled = YES;
                [self.audioRecorder prepareToRecord];
                [self.audioRecorder record];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.meterTimer invalidate];
                self.meterTimer = [NSTimer timerWithTimeInterval:0.08 target:self selector:@selector(updateAudioMeters) userInfo:nil repeats:YES];
                [[NSRunLoop mainRunLoop] addTimer:self.meterTimer forMode:NSRunLoopCommonModes];
            });
        } @catch (NSException *e) {}
    });
}

#pragma mark - NSURLSessionDataDelegate (实时解析 SSE 数据流 + 句子级流式语音秒读)

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
        [self appendStreamingTextDelta:deltaText];
    }
}

- (void)appendStreamingTextDelta:(NSString *)delta {
    [self.accumulatedReplyText appendString:delta];
    [self.pendingSpeechChunk appendString:delta];

    self.subStatusLabel.text = [NSString stringWithFormat:@"✨ %@ 实时对讲中 (可直接开口打断)：", [self currentVendorBrandName]];
    self.responseTextView.text = self.accumulatedReplyText;

    if (self.responseTextView.text.length > 0) {
        NSRange bottom = NSMakeRange(self.responseTextView.text.length - 1, 1);
        [self.responseTextView scrollRangeToVisible:bottom];
    }

    if ([self isAutoSpeakEnabled] && ![self.accumulatedReplyText containsString:@"[ACTION:"]) {
        NSCharacterSet *punctSet = [NSCharacterSet characterSetWithCharactersInString:@"，。！？；：,.!?;:\n"];
        NSRange punctRange = [self.pendingSpeechChunk rangeOfCharacterFromSet:punctSet options:NSBackwardsSearch];
        if (punctRange.location != NSNotFound && punctRange.location >= 4) {
            NSString *sentenceToSpeak = [self.pendingSpeechChunk substringToIndex:punctRange.location + 1];
            NSString *remaining = [self.pendingSpeechChunk substringFromIndex:punctRange.location + 1];
            [self.pendingSpeechChunk setString:remaining];
            [self enqueueLiveSpeechSentence:sentenceToSpeak];
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && error.code == NSURLErrorCancelled) return;

    if (self.accumulatedReplyText.length == 0 && self.sseLineBuffer.length > 0) {
        NSData *rawData = [self.sseLineBuffer dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *json = rawData ? [NSJSONSerialization JSONObjectWithData:rawData options:0 error:nil] : nil;
        if ([json isKindOfClass:[NSDictionary class]]) {
            [self processStreamJSONChunk:self.sseLineBuffer];
            if (self.accumulatedReplyText.length == 0 && json[@"error"][@"message"]) {
                self.subStatusLabel.text = @"⚠️ 接口返回提示";
                self.responseTextView.text = json[@"error"][@"message"];
                return;
            }
        }
    }

    if (error && self.accumulatedReplyText.length == 0) {
        self.subStatusLabel.text = @"❌ 网络连接失败，请检查代理或接口地址";
        self.responseTextView.text = error.localizedDescription;
        return;
    }

    BOOL actionExecuted = NO;
    NSString *cleanReply = [self parseAndExecuteActions:self.accumulatedReplyText executed:&actionExecuted];
    if (actionExecuted) {
        self.subStatusLabel.text = @"✅ 正在为您执行操作...";
        self.responseTextView.text = cleanReply.length > 0 ? cleanReply : @"🚀 正在跳转...";
        return;
    }

    if (cleanReply.length > 0) {
        [self.chatHistory addObject:@{@"role": @"assistant", @"content": cleanReply}];
        if (self.chatHistory.count > 10) [self.chatHistory removeObjectAtIndex:0];
    }

    NSString *tail = [self.pendingSpeechChunk stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self.pendingSpeechChunk setString:@""];
    if ([self isAutoSpeakEnabled] && tail.length > 0) {
        [self enqueueLiveSpeechSentence:tail];
    } else if (self.activeSpeechUtteranceCount == 0 && ![self.synthesizer isSpeaking]) {
        if (self.overlayWindow && !self.overlayWindow.hidden && self.modelPickerContainer.hidden) {
            [self startVoiceRecordingWithFollowUp:YES];
        }
    }
}

- (void)enqueueLiveSpeechSentence:(NSString *)sentence {
    NSString *clean = [sentence stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length == 0) return;

    self.activeSpeechUtteranceCount++;
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:clean];
    utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
    utterance.rate = 0.53;
    [self.synthesizer speakUtterance:utterance];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.activeSpeechUtteranceCount > 0) {
            self.activeSpeechUtteranceCount--;
        }
        if (self.activeSpeechUtteranceCount == 0 && ![synthesizer isSpeaking]) {
            if (self.overlayWindow && !self.overlayWindow.hidden && self.modelPickerContainer.hidden) {
                [self startVoiceRecordingWithFollowUp:YES];
            }
        }
    });
}

@end

// ==================== 3. 手机系统《设置》App 原生可视化双模式+独立视频AI配置中心 ====================
@interface AngelGuardianSettingsViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, assign) AGConfigTab currentEditingTab;
@property (nonatomic, strong) UISwitch *masterEnableSwitch;
@property (nonatomic, strong) UISwitch *autoSpeakSwitch;
@property (nonatomic, strong) UISegmentedControl *activeVoiceModeSeg;
@property (nonatomic, strong) UISegmentedControl *configModuleTabSeg;

@property (nonatomic, strong) UIView *videoSwitchRowView;
@property (nonatomic, strong) UISwitch *videoEnableSwitch;

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
    self.title = @"✨ 天使守护 v4.1 配置中心";
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

    UIView *topCard = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cardW, 148)];
    topCard.backgroundColor = [UIColor colorWithRed:0.13 green:0.13 blue:0.20 alpha:1.0];
    topCard.layer.cornerRadius = 16.0;
    topCard.layer.borderWidth = 0.8;
    topCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    [scroll addSubview:topCard];

    NSDictionary *prefs = loadGeminiPrefs();

    UILabel *enLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, 160, 28)];
    enLbl.text = @"⚡ 启用天使守护接管";
    enLbl.textColor = [UIColor whiteColor];
    enLbl.font = [UIFont boldSystemFontOfSize:14];
    [topCard addSubview:enLbl];

    self.masterEnableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 64, 10, 50, 30)];
    self.masterEnableSwitch.on = prefs[@"Gemini_Enabled"] ? [prefs[@"Gemini_Enabled"] boolValue] : YES;
    [self.masterEnableSwitch addTarget:self action:@selector(globalControlChanged) forControlEvents:UIControlEventValueChanged];
    [topCard addSubview:self.masterEnableSwitch];

    UILabel *spkLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 50, 180, 28)];
    spkLbl.text = @"🔊 自动流式语音播报";
    spkLbl.textColor = [UIColor whiteColor];
    spkLbl.font = [UIFont boldSystemFontOfSize:14];
    [topCard addSubview:spkLbl];

    self.autoSpeakSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 64, 48, 50, 30)];
    self.autoSpeakSwitch.on = prefs[@"Gemini_AutoSpeak"] ? [prefs[@"Gemini_AutoSpeak"] boolValue] : YES;
    [self.autoSpeakSwitch addTarget:self action:@selector(globalControlChanged) forControlEvents:UIControlEventValueChanged];
    [topCard addSubview:self.autoSpeakSwitch];

    UILabel *vmLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 86, cardW - 28, 18)];
    vmLbl.text = @"🎙️ 默认语音对讲模式 (唤出 Siri 时生效)：";
    vmLbl.textColor = [UIColor colorWithRed:0.65 green:0.82 blue:1.0 alpha:1.0];
    vmLbl.font = [UIFont boldSystemFontOfSize:12];
    [topCard addSubview:vmLbl];

    self.activeVoiceModeSeg = [[UISegmentedControl alloc] initWithItems:@[@"模式一：纯文本流式实时交流", @"模式二：纯正 Live API 交流"]];
    self.activeVoiceModeSeg.frame = CGRectMake(14, 108, cardW - 28, 30);
    self.activeVoiceModeSeg.selectedSegmentIndex = ([prefs[@"AG_VoiceMode"] integerValue] == 1) ? 1 : 0;
    [self.activeVoiceModeSeg addTarget:self action:@selector(globalControlChanged) forControlEvents:UIControlEventValueChanged];
    [topCard addSubview:self.activeVoiceModeSeg];

    y += 162.0;

    UILabel *tabHeader = [[UILabel alloc] initWithFrame:CGRectMake(pad + 4, y, cardW, 20)];
    tabHeader.text = @"🛠️ 选择下方要独立配置的 API 模块 (各自独立存储)：";
    tabHeader.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    tabHeader.font = [UIFont boldSystemFontOfSize:12.5];
    [scroll addSubview:tabHeader];
    y += 24.0;

    self.configModuleTabSeg = [[UISegmentedControl alloc] initWithItems:@[@"💬 文本流式", @"🎙️ 纯正Live", @"📹 独立视频AI"]];
    self.configModuleTabSeg.frame = CGRectMake(pad, y, cardW, 34);
    self.configModuleTabSeg.selectedSegmentIndex = 0;
    self.configModuleTabSeg.backgroundColor = [UIColor colorWithRed:0.16 green:0.16 blue:0.25 alpha:1.0];
    [self.configModuleTabSeg addTarget:self action:@selector(moduleTabSwitched:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:self.configModuleTabSeg];
    y += 42.0;

    UIView *moduleCard = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cardW, 470)];
    moduleCard.backgroundColor = [UIColor colorWithRed:0.13 green:0.13 blue:0.20 alpha:1.0];
    moduleCard.layer.cornerRadius = 16.0;
    moduleCard.layer.borderWidth = 0.8;
    moduleCard.layer.borderColor = [UIColor colorWithRed:0.40 green:0.65 blue:1.0 alpha:0.35].CGColor;
    [scroll addSubview:moduleCard];

    CGFloat cy = 12.0;

    self.videoSwitchRowView = [[UIView alloc] initWithFrame:CGRectMake(12, cy, cardW - 24, 38)];
    self.videoSwitchRowView.backgroundColor = [UIColor colorWithRed:0.18 green:0.28 blue:0.24 alpha:0.65];
    self.videoSwitchRowView.layer.cornerRadius = 10.0;
    [moduleCard addSubview:self.videoSwitchRowView];

    UILabel *vSwLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 4, cardW - 90, 30)];
    vSwLbl.text = @"📹 启用独立视频AI (开启并填好后显示📹按钮)";
    vSwLbl.textColor = [UIColor colorWithRed:0.55 green:0.98 blue:0.75 alpha:1.0];
    vSwLbl.font = [UIFont boldSystemFontOfSize:12.0];
    [self.videoSwitchRowView addSubview:vSwLbl];

    self.videoEnableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 80, 4, 50, 30)];
    self.videoEnableSwitch.on = [prefs[@"AG_Video_Enabled"] boolValue];
    [self.videoEnableSwitch addTarget:self action:@selector(saveCurrentTabFieldsToDisk) forControlEvents:UIControlEventValueChanged];
    [self.videoSwitchRowView addSubview:self.videoEnableSwitch];

    cy += 46.0;

    self.endpointField = [self createStyledTextFieldWithFrame:CGRectMake(12, cy, cardW - 24, 38)
                                                  placeholder:@"🔗 独立接口地址 (如 https://api.deepseek.com)"];
    [self.endpointField addTarget:self action:@selector(apiInputFieldsDidChange) forControlEvents:UIControlEventEditingChanged];
    [moduleCard addSubview:self.endpointField];
    cy += 46.0;

    self.apiKeyField = [self createStyledTextFieldWithFrame:CGRectMake(12, cy, cardW - 24, 38)
                                                placeholder:@"🔑 独立 API Key (输入后自动出现获取模型按钮)"];
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
    self.modelSectionHintLabel.text = @"📋 当前模块可用模型列表 (点击即可选中生效)：";
    self.modelSectionHintLabel.textColor = [UIColor colorWithRed:0.65 green:0.85 blue:1.0 alpha:1.0];
    self.modelSectionHintLabel.font = [UIFont boldSystemFontOfSize:12.0];
    [moduleCard addSubview:self.modelSectionHintLabel];
    cy += 22.0;

    self.modelsTableView = [[UITableView alloc] initWithFrame:CGRectMake(8, cy, cardW - 16, 206) style:UITableViewStylePlain];
    self.modelsTableView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    self.modelsTableView.layer.cornerRadius = 10.0;
    self.modelsTableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    self.modelsTableView.delegate = self;
    self.modelsTableView.dataSource = self;
    self.modelsTableView.rowHeight = 36.0;
    [moduleCard addSubview:self.modelsTableView];

    scroll.contentSize = CGSizeMake(w, y + 490.0);

    self.currentEditingTab = AGConfigTabTextLive;
    [self loadFieldsForTab:AGConfigTabTextLive];
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
    p[@"Gemini_AutoSpeak"] = @(self.autoSpeakSwitch.isOn);
    p[@"AG_VoiceMode"] = @(self.activeVoiceModeSeg.selectedSegmentIndex);
    saveGeminiPrefs(p);
}

- (void)moduleTabSwitched:(UISegmentedControl *)seg {
    [self saveCurrentTabFieldsToDisk];
    self.currentEditingTab = (AGConfigTab)seg.selectedSegmentIndex;
    [self loadFieldsForTab:self.currentEditingTab];
}

- (void)loadFieldsForTab:(AGConfigTab)tab {
    NSDictionary *p = loadGeminiPrefs();
    self.videoSwitchRowView.alpha = (tab == AGConfigTabVideoAI) ? 1.0 : 0.35;
    self.videoEnableSwitch.enabled = (tab == AGConfigTabVideoAI);
    self.videoEnableSwitch.on = [p[@"AG_Video_Enabled"] boolValue];

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

    p[[NSString stringWithFormat:@"%@_Endpoint", prefix]] = (ep.length > 0) ? ep : @"https://generativelanguage.googleapis.com";
    p[[NSString stringWithFormat:@"%@_APIKey", prefix]] = key ?: @"";
    p[[NSString stringWithFormat:@"%@_ProxyPort", prefix]] = proxy ?: @"";
    if (model.length > 0) {
        p[[NSString stringWithFormat:@"%@_Model", prefix]] = model;
    }
    if (self.currentEditingTab == AGConfigTabVideoAI) {
        p[@"AG_Video_Enabled"] = @(self.videoEnableSwitch.isOn);
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
        mutableInfo[@"NSMicrophoneUsageDescription"] = @"天使守护需要使用麦克风进行全双工 Live 语音对讲";
        mutableInfo[@"NSSpeechRecognitionUsageDescription"] = @"天使守护需要实时语音流识别以支持全平台模型实时交流";
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
        [[GeminiAssistantManager sharedManager] triggerFromSystemHook];
        return;
    }
    %orig(animated);
}
%end

