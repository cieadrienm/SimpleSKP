#import "SimpleSKPVideoBridge.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

// MARK: - NDI C ABI Declarations

typedef struct NDIlib_find_instance_type *NDIlib_find_instance_t;
typedef struct NDIlib_recv_instance_type *NDIlib_recv_instance_t;

typedef struct NDIlib_source_t {
    const char *p_ndi_name;
    const char *p_url_address;
} NDIlib_source_t;

typedef struct NDIlib_find_create_t {
    bool show_local_sources;
    const char *p_groups;
    const char *p_extra_ips;
} NDIlib_find_create_t;

typedef enum NDIlib_recv_bandwidth_e {
    NDIlib_recv_bandwidth_metadata_only = -10,
    NDIlib_recv_bandwidth_audio_only = 10,
    NDIlib_recv_bandwidth_lowest = 0,
    NDIlib_recv_bandwidth_highest = 100,
    NDIlib_recv_bandwidth_max = 0x7fffffff
} NDIlib_recv_bandwidth_e;

typedef enum NDIlib_recv_color_format_e {
    NDIlib_recv_color_format_BGRX_BGRA = 0,
    NDIlib_recv_color_format_UYVY_BGRA = 1,
    NDIlib_recv_color_format_RGBX_RGBA = 2,
    NDIlib_recv_color_format_UYVY_RGBA = 3,
    NDIlib_recv_color_format_fastest = 100,
    NDIlib_recv_color_format_best = 101,
    NDIlib_recv_color_format_max = 0x7fffffff
} NDIlib_recv_color_format_e;

typedef struct NDIlib_recv_create_v3_t {
    NDIlib_source_t source_to_connect_to;
    NDIlib_recv_color_format_e color_format;
    NDIlib_recv_bandwidth_e bandwidth;
    bool allow_video_fields;
    const char *p_ndi_recv_name;
} NDIlib_recv_create_v3_t;

typedef enum NDIlib_frame_type_e {
    NDIlib_frame_type_none = 0,
    NDIlib_frame_type_video = 1,
    NDIlib_frame_type_audio = 2,
    NDIlib_frame_type_metadata = 3,
    NDIlib_frame_type_error = 4,
    NDIlib_frame_type_status_change = 100,
    NDIlib_frame_type_max = 0x7fffffff
} NDIlib_frame_type_e;

typedef enum NDIlib_frame_format_type_e {
    NDIlib_frame_format_type_interleaved = 0,
    NDIlib_frame_format_type_progressive = 1,
    NDIlib_frame_format_type_field_0 = 2,
    NDIlib_frame_format_type_field_1 = 3,
    NDIlib_frame_format_type_max = 0x7fffffff
} NDIlib_frame_format_type_e;

#define SSKP_FOURCC(c0, c1, c2, c3) \
    ((uint32_t)(uint8_t)(c0) | ((uint32_t)(uint8_t)(c1) << 8) | ((uint32_t)(uint8_t)(c2) << 16) | ((uint32_t)(uint8_t)(c3) << 24))

static const uint32_t kNDIFourCC_BGRA = SSKP_FOURCC('B', 'G', 'R', 'A');
static const uint32_t kNDIFourCC_BGRX = SSKP_FOURCC('B', 'G', 'R', 'X');
static const uint32_t kNDIFourCC_RGBA = SSKP_FOURCC('R', 'G', 'B', 'A');
static const uint32_t kNDIFourCC_RGBX = SSKP_FOURCC('R', 'G', 'B', 'X');

typedef struct NDIlib_video_frame_v2_t {
    int xres, yres;
    uint32_t FourCC;
    int frame_rate_N, frame_rate_D;
    float picture_aspect_ratio;
    NDIlib_frame_format_type_e frame_format_type;
    int64_t timecode;
    uint8_t *p_data;
    int line_stride_in_bytes;
    const char *p_metadata;
    int64_t timestamp;
} NDIlib_video_frame_v2_t;

typedef bool (*PFN_NDIlib_initialize)(void);
typedef void (*PFN_NDIlib_destroy)(void);
typedef const char *(*PFN_NDIlib_version)(void);
typedef NDIlib_find_instance_t (*PFN_NDIlib_find_create_v2)(const NDIlib_find_create_t *);
typedef void (*PFN_NDIlib_find_destroy)(NDIlib_find_instance_t);
typedef const NDIlib_source_t *(*PFN_NDIlib_find_get_current_sources)(NDIlib_find_instance_t, uint32_t *);
typedef bool (*PFN_NDIlib_find_wait_for_sources)(NDIlib_find_instance_t, uint32_t);
typedef NDIlib_recv_instance_t (*PFN_NDIlib_recv_create_v3)(const NDIlib_recv_create_v3_t *);
typedef void (*PFN_NDIlib_recv_destroy)(NDIlib_recv_instance_t);
typedef NDIlib_frame_type_e (*PFN_NDIlib_recv_capture_v2)(NDIlib_recv_instance_t, NDIlib_video_frame_v2_t *, void *, void *, uint32_t);
typedef void (*PFN_NDIlib_recv_free_video_v2)(NDIlib_recv_instance_t, const NDIlib_video_frame_v2_t *);
typedef int (*PFN_NDIlib_recv_get_no_connections)(NDIlib_recv_instance_t);

typedef struct SSKPNDIFunctions {
    void *handle;
    PFN_NDIlib_initialize initialize;
    PFN_NDIlib_destroy destroy;
    PFN_NDIlib_version version;
    PFN_NDIlib_find_create_v2 find_create_v2;
    PFN_NDIlib_find_destroy find_destroy;
    PFN_NDIlib_find_get_current_sources find_get_current_sources;
    PFN_NDIlib_find_wait_for_sources find_wait_for_sources;
    PFN_NDIlib_recv_create_v3 recv_create_v3;
    PFN_NDIlib_recv_destroy recv_destroy;
    PFN_NDIlib_recv_capture_v2 recv_capture_v2;
    PFN_NDIlib_recv_free_video_v2 recv_free_video_v2;
    PFN_NDIlib_recv_get_no_connections recv_get_no_connections;
} SSKPNDIFunctions;

static NSString *SSKPVideoExecutableDirectory(void) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    if (size == 0) {
        return nil;
    }
    char *buf = malloc(size);
    if (!buf) {
        return nil;
    }
    NSString *result = nil;
    if (_NSGetExecutablePath(buf, &size) == 0) {
        NSString *execPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:buf length:strlen(buf)];
        result = [[execPath stringByResolvingSymlinksInPath] stringByDeletingLastPathComponent];
    }
    free(buf);
    return result;
}

// MARK: - SSKPVideoSourceDescriptor

@implementation SSKPVideoSourceDescriptor

- (instancetype)initWithKind:(SSKPVideoSourceKind)kind
                  identifier:(NSString *)identifier
                        name:(NSString *)name
                     appName:(NSString *)appName
                displayTitle:(NSString *)displayTitle
                   matchText:(NSString *)matchText
           syphonDescription:(nullable NSDictionary<NSString *, id> *)syphonDescription
                 ndiFullName:(nullable NSString *)ndiFullName
               ndiURLAddress:(nullable NSString *)ndiURLAddress {
    self = [super init];
    if (self) {
        _kind = kind;
        _identifier = [identifier copy];
        _name = [name copy];
        _appName = [appName copy];
        _displayTitle = [displayTitle copy];
        _matchText = [matchText copy];
        _syphonDescription = syphonDescription;
        _ndiFullName = [ndiFullName copy];
        _ndiURLAddress = [ndiURLAddress copy];
    }
    return self;
}

@end

// MARK: - Syphon Dynamic Loader & Metal Subclasses

typedef struct SSKPSyphonRuntime {
    BOOL loaded;
    NSString * __strong frameworkPath;
    Class directoryClass;
    Class clientBaseClass;
    Class serverBaseClass;
    Class metalClientSubclass;
    Class metalServerSubclass;
    NSString * __strong keyUUID;
    NSString * __strong keyName;
    NSString * __strong keyAppName;
    NSString * __strong optIsPrivate;
    NSString * __strong notifAnnounce;
    NSString * __strong notifUpdate;
    NSString * __strong notifRetire;
} SSKPSyphonRuntime;

static const void *kSSKPSyphonWrapperAssocKey = &kSSKPSyphonWrapperAssocKey;

@interface SSKPVideoSyphonClient ()
- (void)_handleSurfaceInvalidated;
@end

static void SSKPSyphonMetalClient_invalidateFrame(id self, SEL _cmd) {
    Class superCls = class_getSuperclass(object_getClass(self));
    struct objc_super sup = { .receiver = self, .super_class = superCls };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
    SSKPVideoSyphonClient *wrapper = objc_getAssociatedObject(self, kSSKPSyphonWrapperAssocKey);
    [wrapper _handleSurfaceInvalidated];
}

static SSKPSyphonRuntime *SSKPVideoGetSyphonRuntime(void) {
    static SSKPSyphonRuntime rt;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        NSString *bundleFrameworks = [NSBundle mainBundle].privateFrameworksPath;
        if (bundleFrameworks.length > 0) {
            [candidates addObject:[bundleFrameworks stringByAppendingPathComponent:@"Syphon.framework"]];
        }
        NSString *execDir = SSKPVideoExecutableDirectory();
        if (execDir.length > 0) {
            NSString *rel = [[execDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Frameworks/Syphon.framework"];
            [candidates addObject:rel];
        }
        [candidates addObject:@"/Users/adrien/Programmation/emotion/lib/Syphon/build/Release/Syphon.framework"];
        [candidates addObject:@"/Library/Frameworks/Syphon.framework"];

        void *dylibHandle = NULL;
        NSString *chosenPath = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *fwPath in candidates) {
            NSString *binPath = [fwPath stringByAppendingPathComponent:@"Syphon"];
            if ([fm fileExistsAtPath:binPath]) {
                dylibHandle = dlopen(binPath.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
                if (dylibHandle != NULL) {
                    chosenPath = fwPath;
                    break;
                }
            }
        }
        if (!dylibHandle) {
            return;
        }

        rt.directoryClass = NSClassFromString(@"SyphonServerDirectory");
        rt.clientBaseClass = NSClassFromString(@"SyphonClientBase");
        rt.serverBaseClass = NSClassFromString(@"SyphonServerBase");
        if (!rt.directoryClass || !rt.clientBaseClass) {
            return;
        }

        NSString * __strong *pUUID = (NSString * __strong *)dlsym(dylibHandle, "SyphonServerDescriptionUUIDKey");
        NSString * __strong *pName = (NSString * __strong *)dlsym(dylibHandle, "SyphonServerDescriptionNameKey");
        NSString * __strong *pApp = (NSString * __strong *)dlsym(dylibHandle, "SyphonServerDescriptionAppNameKey");
        NSString * __strong *pPriv = (NSString * __strong *)dlsym(dylibHandle, "SyphonServerOptionIsPrivate");
        NSString * __strong *pAnn = (NSString * __strong *)dlsym(dylibHandle, "SyphonServerAnnounceNotification");
        NSString * __strong *pUpd = (NSString * __strong *)dlsym(dylibHandle, "SyphonServerUpdateNotification");
        NSString * __strong *pRet = (NSString * __strong *)dlsym(dylibHandle, "SyphonServerRetireNotification");

        rt.keyUUID = pUUID ? *pUUID : @"SyphonServerDescriptionUUIDKey";
        rt.keyName = pName ? *pName : @"SyphonServerDescriptionNameKey";
        rt.keyAppName = pApp ? *pApp : @"SyphonServerDescriptionAppNameKey";
        rt.optIsPrivate = pPriv ? *pPriv : @"SyphonServerOptionIsPrivate";
        rt.notifAnnounce = pAnn ? *pAnn : @"SyphonServerAnnounceNotification";
        rt.notifUpdate = pUpd ? *pUpd : @"SyphonServerUpdateNotification";
        rt.notifRetire = pRet ? *pRet : @"SyphonServerRetireNotification";

        Class sub = objc_allocateClassPair(rt.clientBaseClass, "SSKPSyphonMetalClient", 0);
        if (sub) {
            SEL invSel = sel_registerName("invalidateFrame");
            class_addMethod(sub, invSel, (IMP)SSKPSyphonMetalClient_invalidateFrame, "v@:");
            objc_registerClassPair(sub);
            rt.metalClientSubclass = sub;
        } else {
            rt.metalClientSubclass = NSClassFromString(@"SSKPSyphonMetalClient") ?: rt.clientBaseClass;
        }

        if (rt.serverBaseClass) {
            Class srvSub = objc_allocateClassPair(rt.serverBaseClass, "SSKPSyphonMetalServer", 0);
            if (srvSub) {
                objc_registerClassPair(srvSub);
                rt.metalServerSubclass = srvSub;
            } else {
                rt.metalServerSubclass = NSClassFromString(@"SSKPSyphonMetalServer") ?: rt.serverBaseClass;
            }
        }

        rt.frameworkPath = chosenPath;
        rt.loaded = YES;
    });
    return &rt;
}

@implementation SSKPVideoSyphonBridge

+ (BOOL)isAvailable {
    return SSKPVideoGetSyphonRuntime()->loaded;
}

+ (nullable NSString *)loadedFrameworkPath {
    return SSKPVideoGetSyphonRuntime()->frameworkPath;
}

+ (NSArray<SSKPVideoSourceDescriptor *> *)availableServers {
    SSKPSyphonRuntime *rt = SSKPVideoGetSyphonRuntime();
    if (!rt->loaded) {
        return @[];
    }
    SEL sharedSel = sel_registerName("sharedDirectory");
    SEL serversSel = sel_registerName("servers");
    id directory = ((id (*)(id, SEL))objc_msgSend)(rt->directoryClass, sharedSel);
    if (!directory) {
        return @[];
    }
    NSArray *rawServers = ((NSArray * (*)(id, SEL))objc_msgSend)(directory, serversSel);
    if (![rawServers isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<SSKPVideoSourceDescriptor *> *out = [NSMutableArray arrayWithCapacity:rawServers.count];
    for (id item in rawServers) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *dict = (NSDictionary *)item;
        NSString *uuid = [dict[rt->keyUUID] isKindOfClass:[NSString class]] ? dict[rt->keyUUID] : @"";
        NSString *name = [dict[rt->keyName] isKindOfClass:[NSString class]] ? dict[rt->keyName] : @"";
        NSString *appName = [dict[rt->keyAppName] isKindOfClass:[NSString class]] ? dict[rt->keyAppName] : @"";
        if (uuid.length == 0 && name.length == 0 && appName.length == 0) {
            continue;
        }
        NSString *ident = [NSString stringWithFormat:@"syphon:%@", uuid.length > 0 ? uuid : [NSString stringWithFormat:@"%@-%@", appName, name]];
        NSString *display = nil;
        if (appName.length > 0 && name.length > 0) {
            display = [NSString stringWithFormat:@"%@ — %@", appName, name];
        } else if (name.length > 0) {
            display = name;
        } else {
            display = appName;
        }
        NSString *match = [NSString stringWithFormat:@"%@ %@", appName, name];
        SSKPVideoSourceDescriptor *desc = [[SSKPVideoSourceDescriptor alloc] initWithKind:SSKPVideoSourceKindSyphon
                                                                               identifier:ident
                                                                                     name:name.length > 0 ? name : appName
                                                                                  appName:appName
                                                                             displayTitle:display
                                                                                matchText:match
                                                                        syphonDescription:dict
                                                                              ndiFullName:nil
                                                                            ndiURLAddress:nil];
        [out addObject:desc];
    }
    return out;
}

+ (id)observeChanges:(void (^)(void))handler {
    SSKPSyphonRuntime *rt = SSKPVideoGetSyphonRuntime();
    if (!rt->loaded || !handler) {
        return [NSNull null];
    }
    SEL sharedSel = sel_registerName("sharedDirectory");
    (void)((id (*)(id, SEL))objc_msgSend)(rt->directoryClass, sharedSel);

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSMutableArray *tokens = [NSMutableArray arrayWithCapacity:3];
    for (NSString *notif in @[rt->notifAnnounce, rt->notifUpdate, rt->notifRetire]) {
        id tok = [nc addObserverForName:notif object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
            handler();
        }];
        if (tok) {
            [tokens addObject:tok];
        }
    }
    return tokens;
}

+ (void)removeObserver:(id)observer {
    if ([observer isKindOfClass:[NSArray class]]) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        for (id tok in (NSArray *)observer) {
            [nc removeObserver:tok];
        }
    }
}

@end

// MARK: - SSKPVideoSyphonServer

static const void *kSSKPLayerSyphonServerAssocKey = &kSSKPLayerSyphonServerAssocKey;
static const void *kSSKPLayerSwizzledAssocKey = &kSSKPLayerSwizzledAssocKey;

@interface SSKPVideoSyphonServer ()
- (void)_didAcquireDrawableTexture:(id<MTLTexture>)texture;
@end

static NSString * const kSSKPSyphonBlitShaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
struct SyphonBlitOut {\n\
    float4 position [[position]];\n\
    float2 uv;\n\
};\n\
vertex SyphonBlitOut sskp_syphonOutVS(constant uint2 &flags [[buffer(0)]], uint vid [[vertex_id]]) {\n\
    float2 pos[3] = {\n\
        float2(-1.0, -1.0),\n\
        float2( 3.0, -1.0),\n\
        float2(-1.0,  3.0)\n\
    };\n\
    float2 p = pos[vid];\n\
    SyphonBlitOut out;\n\
    out.position = float4(p, 0.0, 1.0);\n\
    float u = 0.5 * (p.x + 1.0);\n\
    float vTop = 0.5 * (1.0 - p.y);\n\
    out.uv = float2(u, (flags.x != 0u) ? (1.0 - vTop) : vTop);\n\
    return out;\n\
}\n\
inline float3 sskp_linearToSRGB(float3 c) {\n\
    c = clamp(c, 0.0, 1.0);\n\
    float3 lo = c * 12.92;\n\
    float3 hi = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;\n\
    return select(hi, lo, c <= 0.0031308);\n\
}\n\
fragment float4 sskp_syphonOutFS(SyphonBlitOut in [[stage_in]], texture2d<float, access::sample> srcTex [[texture(0)]], constant uint2 &flags [[buffer(0)]]) {\n\
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);\n\
    float4 c = srcTex.sample(s, in.uv);\n\
    float3 rgb = (flags.y != 0u) ? sskp_linearToSRGB(c.rgb) : c.rgb;\n\
    return float4(rgb, 1.0);\n\
}\n";

@implementation SSKPVideoSyphonServer {
    id _syphonServer;
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _blitPipeline;
    id<MTLTexture> _cachedSurfaceTexture;
    IOSurfaceID _cachedSurfaceID;
    id<MTLTexture> _capturedLayerTexture;
    __weak CALayer *_attachedLayer;
    uint64_t _publishedFrameCount;
    NSUInteger _lastPublishedWidth;
    NSUInteger _lastPublishedHeight;
    os_unfair_lock _lock;
    BOOL _stopped;
}

- (nullable instancetype)initWithName:(nullable NSString *)name
                               device:(id<MTLDevice>)device
                            isPrivate:(BOOL)isPrivate {
    SSKPSyphonRuntime *rt = SSKPVideoGetSyphonRuntime();
    if (!rt->loaded || !rt->metalServerSubclass || !device) {
        return nil;
    }
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _device = device;
        SEL initSel = sel_registerName("initWithName:options:");
        NSDictionary *opts = isPrivate ? @{ rt->optIsPrivate : @YES } : nil;
        id instance = [rt->metalServerSubclass alloc];
        instance = ((id (*)(id, SEL, NSString *, NSDictionary *))objc_msgSend)(instance, initSel, name ?: @"", opts);
        if (!instance) {
            return nil;
        }
        _syphonServer = instance;
        SEL descSel = sel_registerName("serverDescription");
        NSDictionary *desc = ((NSDictionary * (*)(id, SEL))objc_msgSend)(instance, descSel);
        NSString *uuid = [desc[rt->keyUUID] isKindOfClass:[NSString class]] ? desc[rt->keyUUID] : @"";
        _serverUUID = [uuid copy];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isValid {
    os_unfair_lock_lock(&_lock);
    BOOL ok = (_syphonServer != nil && !_stopped);
    os_unfair_lock_unlock(&_lock);
    return ok;
}

- (nullable NSString *)name {
    os_unfair_lock_lock(&_lock);
    id srv = _stopped ? nil : _syphonServer;
    os_unfair_lock_unlock(&_lock);
    if (!srv) {
        return nil;
    }
    SEL nameSel = sel_registerName("name");
    return ((NSString * (*)(id, SEL))objc_msgSend)(srv, nameSel);
}

- (void)setName:(nullable NSString *)name {
    os_unfair_lock_lock(&_lock);
    id srv = _stopped ? nil : _syphonServer;
    os_unfair_lock_unlock(&_lock);
    if (!srv) {
        return;
    }
    SEL setNameSel = sel_registerName("setName:");
    ((void (*)(id, SEL, NSString *))objc_msgSend)(srv, setNameSel, name ?: @"");
}

- (BOOL)hasClients {
    os_unfair_lock_lock(&_lock);
    id srv = _stopped ? nil : _syphonServer;
    os_unfair_lock_unlock(&_lock);
    if (!srv) {
        return NO;
    }
    SEL hasClientsSel = sel_registerName("hasClients");
    return ((BOOL (*)(id, SEL))objc_msgSend)(srv, hasClientsSel);
}

- (uint64_t)publishedFrameCount {
    os_unfair_lock_lock(&_lock);
    uint64_t c = _publishedFrameCount;
    os_unfair_lock_unlock(&_lock);
    return c;
}

- (NSUInteger)lastPublishedWidth {
    os_unfair_lock_lock(&_lock);
    NSUInteger w = _lastPublishedWidth;
    os_unfair_lock_unlock(&_lock);
    return w;
}

- (NSUInteger)lastPublishedHeight {
    os_unfair_lock_lock(&_lock);
    NSUInteger h = _lastPublishedHeight;
    os_unfair_lock_unlock(&_lock);
    return h;
}

- (nullable NSDictionary<NSString *, id> *)serverDescription {
    os_unfair_lock_lock(&_lock);
    id srv = _stopped ? nil : _syphonServer;
    os_unfair_lock_unlock(&_lock);
    if (!srv) {
        return nil;
    }
    SEL descSel = sel_registerName("serverDescription");
    return ((NSDictionary * (*)(id, SEL))objc_msgSend)(srv, descSel);
}

- (nullable id<MTLRenderPipelineState>)_ensureBlitPipeline {
    os_unfair_lock_lock(&_lock);
    id<MTLRenderPipelineState> existing = _blitPipeline;
    os_unfair_lock_unlock(&_lock);
    if (existing) {
        return existing;
    }
    NSError *err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:kSSKPSyphonBlitShaderSource options:nil error:&err];
    if (!lib) {
        return nil;
    }
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [lib newFunctionWithName:@"sskp_syphonOutVS"];
    desc.fragmentFunction = [lib newFunctionWithName:@"sskp_syphonOutFS"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pso = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (pso) {
        os_unfair_lock_lock(&_lock);
        _blitPipeline = pso;
        os_unfair_lock_unlock(&_lock);
    }
    return pso;
}

- (BOOL)publishTexture:(id<MTLTexture>)sourceTexture
          commandQueue:(id<MTLCommandQueue>)commandQueue
           outputWidth:(NSUInteger)outputWidth
          outputHeight:(NSUInteger)outputHeight
               flipped:(BOOL)flipped
         waitUntilDone:(BOOL)waitUntilDone {
    if (!sourceTexture || !commandQueue) {
        return NO;
    }
    NSUInteger w = outputWidth > 0 ? outputWidth : sourceTexture.width;
    NSUInteger h = outputHeight > 0 ? outputHeight : sourceTexture.height;
    if (w == 0 || h == 0) {
        return NO;
    }

    os_unfair_lock_lock(&_lock);
    id srv = _stopped ? nil : _syphonServer;
    os_unfair_lock_unlock(&_lock);
    if (!srv) {
        return NO;
    }

    id<MTLRenderPipelineState> pso = [self _ensureBlitPipeline];
    if (!pso) {
        return NO;
    }

    SEL copySurfSel = sel_registerName("copySurfaceForWidth:height:options:");
    SEL publishSel = sel_registerName("publish");
    IOSurfaceRef surf = ((IOSurfaceRef (*)(id, SEL, size_t, size_t, NSDictionary *))objc_msgSend)(srv, copySurfSel, w, h, nil);
    if (!surf) {
        return NO;
    }

    IOSurfaceID sid = IOSurfaceGetID(surf);
    id<MTLTexture> targetTex = nil;
    os_unfair_lock_lock(&_lock);
    if (_cachedSurfaceTexture != nil && _cachedSurfaceID == sid && _cachedSurfaceTexture.width == w && _cachedSurfaceTexture.height == h) {
        targetTex = _cachedSurfaceTexture;
        os_unfair_lock_unlock(&_lock);
    } else {
        os_unfair_lock_unlock(&_lock);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:w
                                                                                     height:h
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        targetTex = [_device newTextureWithDescriptor:td iosurface:surf plane:0];
        if (targetTex) {
            os_unfair_lock_lock(&_lock);
            _cachedSurfaceTexture = targetTex;
            _cachedSurfaceID = sid;
            os_unfair_lock_unlock(&_lock);
        }
    }
    CFRelease(surf);

    if (!targetTex) {
        return NO;
    }

    id<MTLCommandBuffer> cmdBuf = [commandQueue commandBuffer];
    if (!cmdBuf) {
        return NO;
    }

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = targetTex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    if (!enc) {
        return NO;
    }

    MTLPixelFormat srcFmt = sourceTexture.pixelFormat;
    BOOL needsLinearToSRGB = (srcFmt == MTLPixelFormatBGRA8Unorm_sRGB ||
                              srcFmt == MTLPixelFormatRGBA8Unorm_sRGB ||
                              srcFmt == MTLPixelFormatRGBA16Float ||
                              srcFmt == MTLPixelFormatRGBA32Float);
    uint32_t flags[2] = { flipped ? 1u : 0u, needsLinearToSRGB ? 1u : 0u };
    [enc setRenderPipelineState:pso];
    [enc setVertexBytes:flags length:sizeof(flags) atIndex:0];
    [enc setFragmentBytes:flags length:sizeof(flags) atIndex:0];
    [enc setFragmentTexture:sourceTexture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    if (waitUntilDone) {
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];
        os_unfair_lock_lock(&_lock);
        id activeSrv = _stopped ? nil : _syphonServer;
        if (activeSrv) {
            _publishedFrameCount += 1;
            _lastPublishedWidth = w;
            _lastPublishedHeight = h;
        }
        os_unfair_lock_unlock(&_lock);
        if (activeSrv) {
            ((void (*)(id, SEL))objc_msgSend)(activeSrv, publishSel);
        }
    } else {
        id<MTLTexture> retainedSource = sourceTexture;
        __weak SSKPVideoSyphonServer *weakSelf = self;
        [cmdBuf addCompletedHandler:^(__unused id<MTLCommandBuffer> cb) {
            (void)retainedSource;
            SSKPVideoSyphonServer *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            os_unfair_lock_lock(&strongSelf->_lock);
            id activeSrv = strongSelf->_stopped ? nil : strongSelf->_syphonServer;
            if (activeSrv) {
                strongSelf->_publishedFrameCount += 1;
                strongSelf->_lastPublishedWidth = w;
                strongSelf->_lastPublishedHeight = h;
            }
            os_unfair_lock_unlock(&strongSelf->_lock);
            if (activeSrv) {
                ((void (*)(id, SEL))objc_msgSend)(activeSrv, publishSel);
            }
        }];
        [cmdBuf commit];
    }
    return YES;
}

- (BOOL)republishLastFrame {
    os_unfair_lock_lock(&_lock);
    id srv = (_stopped || _publishedFrameCount == 0) ? nil : _syphonServer;
    os_unfair_lock_unlock(&_lock);
    if (!srv) {
        return NO;
    }
    SEL publishSel = sel_registerName("publish");
    ((void (*)(id, SEL))objc_msgSend)(srv, publishSel);
    return YES;
}

- (void)_didAcquireDrawableTexture:(id<MTLTexture>)texture {
    os_unfair_lock_lock(&_lock);
    _capturedLayerTexture = texture;
    os_unfair_lock_unlock(&_lock);
}

- (nullable id<MTLTexture>)consumeCapturedLayerTexture {
    os_unfair_lock_lock(&_lock);
    id<MTLTexture> tex = _capturedLayerTexture;
    _capturedLayerTexture = nil;
    os_unfair_lock_unlock(&_lock);
    return tex;
}

- (void)attachToMetalLayer:(nullable CALayer *)layer {
    os_unfair_lock_lock(&_lock);
    CALayer *prevLayer = _attachedLayer;
    _attachedLayer = layer;
    _capturedLayerTexture = nil;
    os_unfair_lock_unlock(&_lock);

    if (prevLayer && prevLayer != layer) {
        objc_setAssociatedObject(prevLayer, kSSKPLayerSyphonServerAssocKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    if (!layer || ![layer isKindOfClass:[CAMetalLayer class]]) {
        return;
    }

    CAMetalLayer *metalLayer = (CAMetalLayer *)layer;
    metalLayer.framebufferOnly = NO;
    objc_setAssociatedObject(metalLayer, kSSKPLayerSyphonServerAssocKey, self, OBJC_ASSOCIATION_ASSIGN);

    Class cls = object_getClass(metalLayer);
    @synchronized (cls) {
        if (!objc_getAssociatedObject(cls, kSSKPLayerSwizzledAssocKey)) {
            SEL nextSel = @selector(nextDrawable);
            Method m = class_getInstanceMethod(cls, nextSel);
            if (m) {
                IMP origImp = method_getImplementation(m);
                id<CAMetalDrawable> (^block)(id) = ^id<CAMetalDrawable>(id slf) {
                    id<CAMetalDrawable> drawable = ((id<CAMetalDrawable> (*)(id, SEL))origImp)(slf, nextSel);
                    if (drawable) {
                        SSKPVideoSyphonServer *srv = objc_getAssociatedObject(slf, kSSKPLayerSyphonServerAssocKey);
                        if (srv) {
                            [srv _didAcquireDrawableTexture:drawable.texture];
                        }
                    }
                    return drawable;
                };
                IMP newImp = imp_implementationWithBlock(block);
                if (!class_addMethod(cls, nextSel, newImp, method_getTypeEncoding(m))) {
                    method_setImplementation(m, newImp);
                }
                objc_setAssociatedObject(cls, kSSKPLayerSwizzledAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

- (BOOL)publishTestQuadrantsWithWidth:(NSUInteger)width
                               height:(NSUInteger)height
                             topLeftR:(uint8_t)tlR topLeftG:(uint8_t)tlG topLeftB:(uint8_t)tlB
                            topRightR:(uint8_t)trR topRightG:(uint8_t)trG topRightB:(uint8_t)trB
                          bottomLeftR:(uint8_t)blR bottomLeftG:(uint8_t)blG bottomLeftB:(uint8_t)blB
                         bottomRightR:(uint8_t)brR bottomRightG:(uint8_t)brG bottomRightB:(uint8_t)brB {
    if (width == 0 || height == 0) {
        return NO;
    }
    os_unfair_lock_lock(&_lock);
    id srv = _stopped ? nil : _syphonServer;
    os_unfair_lock_unlock(&_lock);
    if (!srv) {
        return NO;
    }

    SEL copySurfSel = sel_registerName("copySurfaceForWidth:height:options:");
    SEL publishSel = sel_registerName("publish");
    IOSurfaceRef surf = ((IOSurfaceRef (*)(id, SEL, size_t, size_t, NSDictionary *))objc_msgSend)(srv, copySurfSel, width, height, nil);
    if (!surf) {
        return NO;
    }

    IOSurfaceLock(surf, 0, NULL);
    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surf);
    size_t bpr = IOSurfaceGetBytesPerRow(surf);
    if (base && bpr >= width * 4) {
        // Syphon IOSurface has bottom-left origin: y = 0 is bottom, y = height-1 is top
        for (NSUInteger y = 0; y < height; y++) {
            BOOL isTop = (y >= height / 2);
            uint8_t *row = base + y * bpr;
            for (NSUInteger x = 0; x < width; x++) {
                BOOL isRight = (x >= width / 2);
                uint8_t r, g, b;
                if (isTop && !isRight) {
                    r = tlR; g = tlG; b = tlB;
                } else if (isTop && isRight) {
                    r = trR; g = trG; b = trB;
                } else if (!isTop && !isRight) {
                    r = blR; g = blG; b = blB;
                } else {
                    r = brR; g = brG; b = brB;
                }
                row[x * 4 + 0] = b;
                row[x * 4 + 1] = g;
                row[x * 4 + 2] = r;
                row[x * 4 + 3] = 255;
            }
        }
    }
    IOSurfaceUnlock(surf, 0, NULL);
    CFRelease(surf);

    os_unfair_lock_lock(&_lock);
    _publishedFrameCount += 1;
    _lastPublishedWidth = width;
    _lastPublishedHeight = height;
    os_unfair_lock_unlock(&_lock);

    ((void (*)(id, SEL))objc_msgSend)(srv, publishSel);
    return YES;
}

- (void)stop {
    id srvToStop = nil;
    CALayer *layerToDetach = nil;
    os_unfair_lock_lock(&_lock);
    if (!_stopped) {
        _stopped = YES;
        srvToStop = _syphonServer;
        _syphonServer = nil;
        _cachedSurfaceTexture = nil;
        _cachedSurfaceID = 0;
        _capturedLayerTexture = nil;
        layerToDetach = _attachedLayer;
        _attachedLayer = nil;
    }
    os_unfair_lock_unlock(&_lock);
    if (layerToDetach) {
        objc_setAssociatedObject(layerToDetach, kSSKPLayerSyphonServerAssocKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    if (srvToStop) {
        SEL stopSel = sel_registerName("stop");
        ((void (*)(id, SEL))objc_msgSend)(srvToStop, stopSel);
    }
}

@end

// MARK: - SSKPVideoSyphonClient

@implementation SSKPVideoSyphonClient {
    id _syphonClient;
    id<MTLDevice> _device;
    id<MTLTexture> _cachedTexture;
    IOSurfaceID _cachedSurfaceID;
    uint64_t _frameRevision;
    os_unfair_lock _lock;
    BOOL _stopped;
}

- (nullable instancetype)initWithServer:(SSKPVideoSourceDescriptor *)server
                                 device:(id<MTLDevice>)device
                             onNewFrame:(void (^ _Nullable)(void))onNewFrame {
    if (!server.syphonDescription) {
        return nil;
    }
    return [self initWithServerDescription:server.syphonDescription
                                identifier:server.identifier
                                    device:device
                                onNewFrame:onNewFrame];
}

- (nullable instancetype)initWithServerDescription:(NSDictionary<NSString *, id> *)serverDescription
                                        identifier:(NSString *)identifier
                                            device:(id<MTLDevice>)device
                                        onNewFrame:(void (^ _Nullable)(void))onNewFrame {
    SSKPSyphonRuntime *rt = SSKPVideoGetSyphonRuntime();
    if (!rt->loaded || !serverDescription || !device) {
        return nil;
    }
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _device = device;
        _sourceIdentifier = [identifier copy];
        _frameRevision = 0;

        SEL initSel = sel_registerName("initWithServerDescription:options:newFrameHandler:");
        void (^frameBlock)(id) = ^(__unused id clientObj) {
            if (onNewFrame) {
                onNewFrame();
            }
        };

        id instance = [rt->metalClientSubclass alloc];
        instance = ((id (*)(id, SEL, NSDictionary *, NSDictionary *, id))objc_msgSend)(
            instance, initSel, serverDescription, nil, frameBlock
        );
        if (!instance) {
            return nil;
        }
        objc_setAssociatedObject(instance, kSSKPSyphonWrapperAssocKey, self, OBJC_ASSOCIATION_ASSIGN);
        _syphonClient = instance;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isValid {
    os_unfair_lock_lock(&_lock);
    id client = _syphonClient;
    BOOL stopped = _stopped;
    os_unfair_lock_unlock(&_lock);
    if (stopped || !client) {
        return NO;
    }
    SEL validSel = sel_registerName("isValid");
    return ((BOOL (*)(id, SEL))objc_msgSend)(client, validSel);
}

- (uint64_t)frameRevision {
    os_unfair_lock_lock(&_lock);
    uint64_t rev = _frameRevision;
    os_unfair_lock_unlock(&_lock);
    return rev;
}

- (void)_handleSurfaceInvalidated {
    os_unfair_lock_lock(&_lock);
    _cachedTexture = nil;
    _cachedSurfaceID = 0;
    os_unfair_lock_unlock(&_lock);
}

- (nullable id<MTLTexture>)currentTexture {
    os_unfair_lock_lock(&_lock);
    if (_stopped || !_syphonClient) {
        os_unfair_lock_unlock(&_lock);
        return nil;
    }
    id client = _syphonClient;
    id<MTLTexture> existing = _cachedTexture;
    os_unfair_lock_unlock(&_lock);

    SEL hasNewSel = sel_registerName("hasNewFrame");
    BOOL hasNew = ((BOOL (*)(id, SEL))objc_msgSend)(client, hasNewSel);
    if (!hasNew && existing != nil) {
        return existing;
    }

    SEL newSurfSel = sel_registerName("newSurface");
    IOSurfaceRef surf = ((IOSurfaceRef (*)(id, SEL))objc_msgSend)(client, newSurfSel);
    if (!surf) {
        return existing;
    }

    size_t w = IOSurfaceGetWidth(surf);
    size_t h = IOSurfaceGetHeight(surf);
    IOSurfaceID sid = IOSurfaceGetID(surf);
    id<MTLTexture> resultTex = nil;

    if (w > 0 && h > 0) {
        os_unfair_lock_lock(&_lock);
        if (_cachedTexture != nil && _cachedSurfaceID == sid && _cachedTexture.width == w && _cachedTexture.height == h) {
            resultTex = _cachedTexture;
            _frameRevision += 1;
            os_unfair_lock_unlock(&_lock);
        } else {
            os_unfair_lock_unlock(&_lock);
            // Use MTLPixelFormatBGRA8Unorm so gamma-encoded sRGB bytes are preserved 1:1 when blitted into colorAtlasTexture (.rgba8Unorm)
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                            width:w
                                                                                           height:h
                                                                                        mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead;
            resultTex = [_device newTextureWithDescriptor:desc iosurface:surf plane:0];
            if (!resultTex) {
                desc.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
                resultTex = [_device newTextureWithDescriptor:desc iosurface:surf plane:0];
            }
            if (resultTex) {
                os_unfair_lock_lock(&_lock);
                _cachedTexture = resultTex;
                _cachedSurfaceID = sid;
                _frameRevision += 1;
                os_unfair_lock_unlock(&_lock);
            }
        }
    }

    CFRelease(surf);
    return resultTex ?: existing;
}

- (void)stop {
    id clientToStop = nil;
    os_unfair_lock_lock(&_lock);
    if (!_stopped) {
        _stopped = YES;
        clientToStop = _syphonClient;
        _syphonClient = nil;
        _cachedTexture = nil;
        _cachedSurfaceID = 0;
    }
    os_unfair_lock_unlock(&_lock);

    if (clientToStop) {
        objc_setAssociatedObject(clientToStop, kSSKPSyphonWrapperAssocKey, nil, OBJC_ASSOCIATION_ASSIGN);
        SEL stopSel = sel_registerName("stop");
        ((void (*)(id, SEL))objc_msgSend)(clientToStop, stopSel);
    }
}

@end

// MARK: - NDI Dynamic Loader

static NSString *gLoadedNDIPath = nil;

static SSKPNDIFunctions *SSKPVideoGetNDI(void) {
    static SSKPNDIFunctions ndi;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        NSString *bundleFrameworks = [NSBundle mainBundle].privateFrameworksPath;
        if (bundleFrameworks.length > 0) {
            [candidates addObject:[bundleFrameworks stringByAppendingPathComponent:@"libndi_advanced.dylib"]];
            [candidates addObject:[bundleFrameworks stringByAppendingPathComponent:@"libndi.dylib"]];
        }
        NSString *execDir = SSKPVideoExecutableDirectory();
        if (execDir.length > 0) {
            NSString *fwDir = [[execDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Frameworks"];
            [candidates addObject:[fwDir stringByAppendingPathComponent:@"libndi_advanced.dylib"]];
            [candidates addObject:[fwDir stringByAppendingPathComponent:@"libndi.dylib"]];
        }
        [candidates addObject:@"/Library/NDI Advanced SDK for Apple/lib/macOS/libndi_advanced.dylib"];
        [candidates addObject:@"/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"];

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in candidates) {
            if (![fm fileExistsAtPath:path]) {
                continue;
            }
            void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
            if (!h) {
                continue;
            }
            ndi.initialize = (PFN_NDIlib_initialize)dlsym(h, "NDIlib_initialize");
            ndi.destroy = (PFN_NDIlib_destroy)dlsym(h, "NDIlib_destroy");
            ndi.version = (PFN_NDIlib_version)dlsym(h, "NDIlib_version");
            ndi.find_create_v2 = (PFN_NDIlib_find_create_v2)dlsym(h, "NDIlib_find_create_v2");
            ndi.find_destroy = (PFN_NDIlib_find_destroy)dlsym(h, "NDIlib_find_destroy");
            ndi.find_get_current_sources = (PFN_NDIlib_find_get_current_sources)dlsym(h, "NDIlib_find_get_current_sources");
            ndi.find_wait_for_sources = (PFN_NDIlib_find_wait_for_sources)dlsym(h, "NDIlib_find_wait_for_sources");
            ndi.recv_create_v3 = (PFN_NDIlib_recv_create_v3)dlsym(h, "NDIlib_recv_create_v3");
            ndi.recv_destroy = (PFN_NDIlib_recv_destroy)dlsym(h, "NDIlib_recv_destroy");
            ndi.recv_capture_v2 = (PFN_NDIlib_recv_capture_v2)dlsym(h, "NDIlib_recv_capture_v2");
            ndi.recv_free_video_v2 = (PFN_NDIlib_recv_free_video_v2)dlsym(h, "NDIlib_recv_free_video_v2");
            ndi.recv_get_no_connections = (PFN_NDIlib_recv_get_no_connections)dlsym(h, "NDIlib_recv_get_no_connections");

            if (ndi.initialize && ndi.find_create_v2 && ndi.recv_create_v3 && ndi.recv_capture_v2 && ndi.initialize()) {
                ndi.handle = h;
                gLoadedNDIPath = [path copy];
                break;
            } else {
                dlclose(h);
                memset(&ndi, 0, sizeof(ndi));
            }
        }
    });
    return &ndi;
}

@implementation SSKPVideoNDIBridge {
    NDIlib_find_instance_t _finder;
    NSThread *_thread;
    os_unfair_lock _lock;
    NSArray<SSKPVideoSourceDescriptor *> *_sources;
    BOOL _stopped;
    void (^_onSourcesChanged)(void);
}

+ (BOOL)isAvailable {
    return SSKPVideoGetNDI()->handle != NULL;
}

+ (nullable NSString *)loadedLibraryPath {
    (void)SSKPVideoGetNDI();
    return gLoadedNDIPath;
}

+ (nullable NSString *)ndiVersion {
    SSKPNDIFunctions *ndi = SSKPVideoGetNDI();
    if (!ndi->handle || !ndi->version) {
        return nil;
    }
    const char *v = ndi->version();
    return v ? [NSString stringWithUTF8String:v] : nil;
}

- (nullable instancetype)initWithOnSourcesChanged:(void (^ _Nullable)(void))onSourcesChanged {
    SSKPNDIFunctions *ndi = SSKPVideoGetNDI();
    if (!ndi->handle) {
        return nil;
    }
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _sources = @[];
        _onSourcesChanged = [onSourcesChanged copy];

        NDIlib_find_create_t cfg = {
            .show_local_sources = true,
            .p_groups = NULL,
            .p_extra_ips = NULL,
        };
        _finder = ndi->find_create_v2(&cfg);
        if (!_finder) {
            return nil;
        }
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(_discoveryLoop) object:nil];
        _thread.name = @"fr.cieadrienm.simpleskp.ndi-finder";
        _thread.qualityOfService = NSQualityOfServiceUtility;
        [_thread start];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSArray<SSKPVideoSourceDescriptor *> *)currentSources {
    os_unfair_lock_lock(&_lock);
    NSArray<SSKPVideoSourceDescriptor *> *copy = _sources;
    os_unfair_lock_unlock(&_lock);
    return copy;
}

- (void)_discoveryLoop {
    SSKPNDIFunctions *ndi = SSKPVideoGetNDI();
    NSArray<NSString *> *lastIDs = @[];

    while (YES) {
        @autoreleasepool {
            os_unfair_lock_lock(&_lock);
            BOOL shouldStop = _stopped;
            NDIlib_find_instance_t finder = _finder;
            os_unfair_lock_unlock(&_lock);
            if (shouldStop || !finder) {
                break;
            }

            if (ndi->find_wait_for_sources) {
                (void)ndi->find_wait_for_sources(finder, 1200);
            } else {
                [NSThread sleepForTimeInterval:1.2];
            }

            os_unfair_lock_lock(&_lock);
            shouldStop = _stopped;
            finder = _finder;
            os_unfair_lock_unlock(&_lock);
            if (shouldStop || !finder) {
                break;
            }

            uint32_t count = 0;
            const NDIlib_source_t *raw = ndi->find_get_current_sources(finder, &count);
            NSMutableArray<SSKPVideoSourceDescriptor *> *parsed = [NSMutableArray arrayWithCapacity:count];
            NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:count];

            for (uint32_t i = 0; i < count; i++) {
                if (!raw[i].p_ndi_name) {
                    continue;
                }
                NSString *fullName = [NSString stringWithUTF8String:raw[i].p_ndi_name];
                if (fullName.length == 0) {
                    continue;
                }
                NSString *url = raw[i].p_url_address ? [NSString stringWithUTF8String:raw[i].p_url_address] : nil;
                NSString *host = @"NDI";
                NSString *stream = fullName;
                NSRange openParen = [fullName rangeOfString:@" ("];
                if (openParen.location != NSNotFound && [fullName hasSuffix:@")"]) {
                    host = [fullName substringToIndex:openParen.location];
                    NSUInteger start = openParen.location + 2;
                    NSUInteger len = fullName.length - start - 1;
                    if (len > 0) {
                        stream = [fullName substringWithRange:NSMakeRange(start, len)];
                    }
                }
                NSString *ident = [NSString stringWithFormat:@"ndi:%@", fullName];
                [ids addObject:ident];
                SSKPVideoSourceDescriptor *desc = [[SSKPVideoSourceDescriptor alloc] initWithKind:SSKPVideoSourceKindNDI
                                                                                       identifier:ident
                                                                                             name:stream
                                                                                          appName:host
                                                                                     displayTitle:fullName
                                                                                        matchText:fullName
                                                                                syphonDescription:nil
                                                                                      ndiFullName:fullName
                                                                                    ndiURLAddress:url];
                [parsed addObject:desc];
            }

            if (![ids isEqualToArray:lastIDs]) {
                lastIDs = [ids copy];
                os_unfair_lock_lock(&_lock);
                _sources = [parsed copy];
                os_unfair_lock_unlock(&_lock);
                void (^cb)(void) = _onSourcesChanged;
                if (cb) {
                    dispatch_async(dispatch_get_main_queue(), cb);
                }
            }
        }
    }
}

- (void)stop {
    os_unfair_lock_lock(&_lock);
    if (_stopped) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _stopped = YES;
    NDIlib_find_instance_t finder = _finder;
    _finder = NULL;
    os_unfair_lock_unlock(&_lock);

    if (_thread && ![_thread isFinished]) {
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:1.35];
        while (![_thread isFinished] && [limit timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.02];
        }
    }
    if (finder) {
        SSKPVideoGetNDI()->find_destroy(finder);
    }
}

@end

// MARK: - SSKPVideoNDIReceiver

@implementation SSKPVideoNDIReceiver {
    NDIlib_recv_instance_t _receiver;
    id<MTLDevice> _device;
    NSThread *_captureThread;
    os_unfair_lock _lock;
    id<MTLTexture> _textureRing[3];
    NSInteger _writeIndex;
    id<MTLTexture> _latestTexture;
    uint64_t _frameRevision;
    BOOL _stopped;
    BOOL _connected;
    void (^_onNewFrame)(void);
}

- (nullable instancetype)initWithSource:(SSKPVideoSourceDescriptor *)source
                                 device:(id<MTLDevice>)device
                             onNewFrame:(void (^ _Nullable)(void))onNewFrame {
    SSKPNDIFunctions *ndi = SSKPVideoGetNDI();
    if (!ndi->handle || !source.ndiFullName || !device) {
        return nil;
    }
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _device = device;
        _sourceIdentifier = [source.identifier copy];
        _onNewFrame = [onNewFrame copy];
        _frameRevision = 0;

        const char *cName = source.ndiFullName.UTF8String;
        const char *cURL = source.ndiURLAddress.length > 0 ? source.ndiURLAddress.UTF8String : NULL;
        NDIlib_recv_create_v3_t cfg;
        memset(&cfg, 0, sizeof(cfg));
        cfg.source_to_connect_to.p_ndi_name = cName;
        cfg.source_to_connect_to.p_url_address = cURL;
        cfg.color_format = NDIlib_recv_color_format_BGRX_BGRA;
        cfg.bandwidth = NDIlib_recv_bandwidth_highest;
        cfg.allow_video_fields = false;
        cfg.p_ndi_recv_name = "SimpleSKP";

        _receiver = ndi->recv_create_v3(&cfg);
        if (!_receiver) {
            return nil;
        }
        _captureThread = [[NSThread alloc] initWithTarget:self selector:@selector(_captureLoop) object:nil];
        _captureThread.name = [NSString stringWithFormat:@"fr.cieadrienm.simpleskp.ndi-recv.%@", source.name];
        _captureThread.qualityOfService = NSQualityOfServiceUserInteractive;
        [_captureThread start];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isConnected {
    os_unfair_lock_lock(&_lock);
    BOOL c = _connected && !_stopped;
    os_unfair_lock_unlock(&_lock);
    return c;
}

- (uint64_t)frameRevision {
    os_unfair_lock_lock(&_lock);
    uint64_t rev = _frameRevision;
    os_unfair_lock_unlock(&_lock);
    return rev;
}

- (nullable id<MTLTexture>)currentTexture {
    os_unfair_lock_lock(&_lock);
    id<MTLTexture> tex = _stopped ? nil : _latestTexture;
    os_unfair_lock_unlock(&_lock);
    return tex;
}

- (void)_captureLoop {
    SSKPNDIFunctions *ndi = SSKPVideoGetNDI();
    while (YES) {
        @autoreleasepool {
            os_unfair_lock_lock(&_lock);
            BOOL shouldStop = _stopped;
            NDIlib_recv_instance_t recv = _receiver;
            os_unfair_lock_unlock(&_lock);
            if (shouldStop || !recv) {
                break;
            }

            NDIlib_video_frame_v2_t vframe;
            memset(&vframe, 0, sizeof(vframe));
            NDIlib_frame_type_e ftype = ndi->recv_capture_v2(recv, &vframe, NULL, NULL, 100);

            if (ftype == NDIlib_frame_type_video) {
                if (vframe.p_data != NULL && vframe.xres > 1 && vframe.yres > 1) {
                    BOOL isBGRA = (vframe.FourCC == kNDIFourCC_BGRA || vframe.FourCC == kNDIFourCC_BGRX);
                    BOOL isRGBA = (vframe.FourCC == kNDIFourCC_RGBA || vframe.FourCC == kNDIFourCC_RGBX);
                    if (isBGRA || isRGBA) {
                        MTLPixelFormat fmt = isBGRA ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm;
                        NSUInteger w = (NSUInteger)vframe.xres;
                        NSUInteger h = (NSUInteger)vframe.yres;
                        NSUInteger stride = vframe.line_stride_in_bytes > 0 ? (NSUInteger)vframe.line_stride_in_bytes : (w * 4);

                        NSInteger slot = (_writeIndex + 1) % 3;
                        id<MTLTexture> tex = _textureRing[slot];
                        if (!tex || tex.width != w || tex.height != h || tex.pixelFormat != fmt) {
                            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                                          width:w
                                                                                                         height:h
                                                                                                      mipmapped:NO];
                            td.usage = MTLTextureUsageShaderRead;
                            if (_device.hasUnifiedMemory) {
                                td.storageMode = MTLStorageModeShared;
                            }
                            tex = [_device newTextureWithDescriptor:td];
                            _textureRing[slot] = tex;
                        }
                        if (tex) {
                            [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
                                   mipmapLevel:0
                                     withBytes:vframe.p_data
                                   bytesPerRow:stride];
                            _writeIndex = slot;
                            os_unfair_lock_lock(&_lock);
                            _latestTexture = tex;
                            _connected = YES;
                            _frameRevision += 1;
                            os_unfair_lock_unlock(&_lock);

                            void (^cb)(void) = _onNewFrame;
                            if (cb) {
                                cb();
                            }
                        }
                    }
                }
                ndi->recv_free_video_v2(recv, &vframe);
            } else if (ftype == NDIlib_frame_type_error) {
                os_unfair_lock_lock(&_lock);
                _connected = NO;
                os_unfair_lock_unlock(&_lock);
                [NSThread sleepForTimeInterval:0.05];
            }
        }
    }
}

- (void)stop {
    os_unfair_lock_lock(&_lock);
    if (_stopped) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _stopped = YES;
    _connected = NO;
    NDIlib_recv_instance_t recv = _receiver;
    _receiver = NULL;
    _latestTexture = nil;
    os_unfair_lock_unlock(&_lock);

    if (_captureThread && ![_captureThread isFinished]) {
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:0.25];
        while (![_captureThread isFinished] && [limit timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.01];
        }
    }
    for (int i = 0; i < 3; i++) {
        _textureRing[i] = nil;
    }
    if (recv) {
        SSKPVideoGetNDI()->recv_destroy(recv);
    }
}

@end
