// Перехват исключений Objective-C (NSException) для вызовов AVAudioEngine из Swift.
// AVAudioEngine сообщает о неверном формате/устройстве исключением, которое Swift
// перехватить не может — без этой обёртки приложение падает.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCSafe : NSObject
/// Выполняет блок; возвращает nil при успехе или текст исключения.
+ (nullable NSString *)run:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
