#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Runtime-loaded, exception-contained adapter for the current system's visibility service.
@interface BARVisibilityLease : NSObject
+ (BOOL)isAvailable;
+ (void)activateWithBundles:(NSArray<NSString *> *)bundles
               systemItems:(NSArray<NSNumber *> *)systemItems
                completion:(void (^)(BARVisibilityLease * _Nullable, NSError * _Nullable))completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
