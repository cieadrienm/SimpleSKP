#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SSKPVideoSourceKind) {
    SSKPVideoSourceKindSyphon = 0,
    SSKPVideoSourceKindNDI = 1,
};

@interface SSKPVideoSourceDescriptor : NSObject
@property (nonatomic, readonly) SSKPVideoSourceKind kind;
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *appName;
@property (nonatomic, copy, readonly) NSString *displayTitle;
@property (nonatomic, copy, readonly) NSString *matchText;
@property (nonatomic, strong, readonly, nullable) NSDictionary<NSString *, id> *syphonDescription;
@property (nonatomic, copy, readonly, nullable) NSString *ndiFullName;
@property (nonatomic, copy, readonly, nullable) NSString *ndiURLAddress;
@end

@interface SSKPVideoSyphonBridge : NSObject
+ (BOOL)isAvailable;
+ (nullable NSString *)loadedFrameworkPath;
+ (NSArray<SSKPVideoSourceDescriptor *> *)availableServers;
+ (id)observeChanges:(void (^)(void))handler;
+ (void)removeObserver:(id)observer;
@end

@interface SSKPVideoSyphonServer : NSObject
@property (nonatomic, readonly) BOOL isValid;
@property (nonatomic, copy, readonly) NSString *serverUUID;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, readonly) BOOL hasClients;
@property (nonatomic, readonly) uint64_t publishedFrameCount;
@property (nonatomic, readonly) NSUInteger lastPublishedWidth;
@property (nonatomic, readonly) NSUInteger lastPublishedHeight;
@property (nonatomic, strong, readonly, nullable) NSDictionary<NSString *, id> *serverDescription;

- (nullable instancetype)initWithName:(nullable NSString *)name
                               device:(id<MTLDevice>)device
                            isPrivate:(BOOL)isPrivate;

/// Publishes `sourceTexture` into the Syphon IOSurface (converting to BGRA8Unorm and flipping vertically to match Syphon's bottom-left origin when `flipped == YES`).
/// If `outputWidth` or `outputHeight` is 0, uses `sourceTexture.width` and `sourceTexture.height`.
- (BOOL)publishTexture:(id<MTLTexture>)sourceTexture
          commandQueue:(id<MTLCommandQueue>)commandQueue
           outputWidth:(NSUInteger)outputWidth
          outputHeight:(NSUInteger)outputHeight
               flipped:(BOOL)flipped
         waitUntilDone:(BOOL)waitUntilDone;

/// Re-broadcasts the last published IOSurface frame notification to connected Syphon clients (0 GPU cost).
- (BOOL)republishLastFrame;

/// Attaches or detaches this server as an automatic drawable observer on a `CAMetalLayer` (sets `framebufferOnly = NO` when attached).
- (void)attachToMetalLayer:(nullable CALayer *)layer;
- (nullable id<MTLTexture>)consumeCapturedLayerTexture;

/// Publishes a solid or quadrant-colored test pattern of size `width x height` into the Syphon IOSurface (bottom-left origin).
- (BOOL)publishTestQuadrantsWithWidth:(NSUInteger)width
                               height:(NSUInteger)height
                             topLeftR:(uint8_t)tlR topLeftG:(uint8_t)tlG topLeftB:(uint8_t)tlB
                            topRightR:(uint8_t)trR topRightG:(uint8_t)trG topRightB:(uint8_t)trB
                          bottomLeftR:(uint8_t)blR bottomLeftG:(uint8_t)blG bottomLeftB:(uint8_t)blB
                         bottomRightR:(uint8_t)brR bottomRightG:(uint8_t)brG bottomRightB:(uint8_t)brB;

- (void)stop;
@end

@interface SSKPVideoSyphonClient : NSObject
@property (nonatomic, readonly) BOOL isValid;
@property (nonatomic, copy, readonly) NSString *sourceIdentifier;
@property (nonatomic, readonly) uint64_t frameRevision;

- (nullable instancetype)initWithServer:(SSKPVideoSourceDescriptor *)server
                                 device:(id<MTLDevice>)device
                             onNewFrame:(void (^ _Nullable)(void))onNewFrame;

- (nullable instancetype)initWithServerDescription:(NSDictionary<NSString *, id> *)serverDescription
                                        identifier:(NSString *)identifier
                                            device:(id<MTLDevice>)device
                                        onNewFrame:(void (^ _Nullable)(void))onNewFrame;

/// Acquires the latest IOSurface zero-copy MTLTexture when a new frame is available.
- (nullable id<MTLTexture>)currentTexture;
- (void)stop;
@end

@interface SSKPVideoNDIBridge : NSObject
+ (BOOL)isAvailable;
+ (nullable NSString *)loadedLibraryPath;
+ (nullable NSString *)ndiVersion;

- (nullable instancetype)initWithOnSourcesChanged:(void (^ _Nullable)(void))onSourcesChanged;
- (NSArray<SSKPVideoSourceDescriptor *> *)currentSources;
- (void)stop;
@end

@interface SSKPVideoNDIReceiver : NSObject
@property (nonatomic, copy, readonly) NSString *sourceIdentifier;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) uint64_t frameRevision;

- (nullable instancetype)initWithSource:(SSKPVideoSourceDescriptor *)source
                                 device:(id<MTLDevice>)device
                             onNewFrame:(void (^ _Nullable)(void))onNewFrame;
- (nullable id<MTLTexture>)currentTexture;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
