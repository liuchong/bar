#import "BarNative.h"
#import <dlfcn.h>

// These declarations describe runtime selectors, and introduce no static framework dependency.
@protocol BARConfigurationAPI
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                 allowedBundleIdentifiers:(NSArray<NSString *> *)bundles;
@end
@protocol BARAssertionAPI
- (void)activateWithConfiguration:(id)configuration completionHandler:(void (^)(NSError *))completion;
- (void)invalidate;
@end

@interface BARVisibilityLease ()
@property(nonatomic, strong) id<BARAssertionAPI> assertion;
@end

@implementation BARVisibilityLease
+ (BOOL)isAvailable {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory
                                                            inDomains:NSSystemDomainMask].firstObject;
        NSURL *binary = [library URLByAppendingPathComponent:
            @"PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"];
        loaded = dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL) != NULL;
    });
    if (!loaded) return NO;
    Class config = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
    return [config instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)]
        && [assertion instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)]
        && [assertion instancesRespondToSelector:@selector(invalidate)];
}

+ (void)activateWithBundles:(NSArray<NSString *> *)bundles
               systemItems:(NSArray<NSNumber *> *)systemItems
                completion:(void (^)(BARVisibilityLease *, NSError *))completion {
    if (![self isAvailable]) {
        completion(nil, [NSError errorWithDomain:@"Bar.Visibility" code:1
                      userInfo:@{NSLocalizedDescriptionKey: @"当前系统未提供可用的图标显隐接口。"}]);
        return;
    }
    @try {
        Class configType = NSClassFromString(@"MBAssessmentModeConfiguration");
        id configuration = [(id<BARConfigurationAPI>)[configType alloc]
                            initWithAllowedSystemItems:systemItems allowedBundleIdentifiers:bundles];
        id<BARAssertionAPI> assertion = [NSClassFromString(@"MBAssessmentModeAssertion") new];
        if (!configuration || !assertion) @throw [NSException exceptionWithName:@"BarUnavailable"
            reason:@"系统显隐服务初始化失败。" userInfo:nil];
        BARVisibilityLease *lease = [BARVisibilityLease new];
        lease.assertion = assertion;
        __block BOOL completed = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (completed) return;
            completed = YES;
            [lease invalidate];
            completion(nil, [NSError errorWithDomain:@"Bar.Visibility" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"系统显隐服务响应超时。"}]);
        });
        [assertion activateWithConfiguration:configuration completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completed) { [lease invalidate]; return; }
                completed = YES;
                if (error) [lease invalidate];
                completion(error ? nil : lease, error);
            });
        }];
    } @catch (NSException *exception) {
        completion(nil, [NSError errorWithDomain:@"Bar.Visibility" code:2
                      userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"系统显隐接口发生变化。"}]);
    }
}

- (void)invalidate {
    @try { [self.assertion invalidate]; } @catch (NSException *exception) { /* Best effort on teardown. */ }
    self.assertion = nil;
}
- (void)dealloc { [self invalidate]; }
@end
