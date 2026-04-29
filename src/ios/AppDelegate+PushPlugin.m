//
//  AppDelegate+PushPlugin.m
//
//  Created by Robert Easterday on 10/26/12.
//

#import "AppDelegate+PushPlugin.h"
#import "PushPlugin.h"
#import "PushPluginConstants.h"
#import <objc/runtime.h>
#import <os/log.h>

// Public-tagged log macro — iOS 15+ Console redacts NSLog %@/%s output as
// <private> by default. os_log with %{public}s explicitly opts out so the
// diagnostic dumps are actually readable.
#define PPLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[PushPlugin] " fmt, ##__VA_ARGS__)

// Captured during the swizzled didFinishLaunchingWithOptions:. PushPlugin's
// pluginInitialize consumes this once via +pushPluginConsumeLaunchNotification.
// Plain static — only written on the main thread during launch and read once
// after pluginInitialize, no synchronization needed.
static NSDictionary *_pushPluginCapturedLaunchNotification = nil;

@implementation AppDelegate (PushPlugin)

// its dangerous to override a method from within a category.
// Instead we will use method swizzling. we set this up in the load call.
+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class class = [self class];
        PPLOG("+load: installing swizzles on class %{public}s", [NSStringFromClass(class) UTF8String]);

        // Swizzle init — sets the UNUserNotificationCenter delegate before
        // anything else can fire user-notification callbacks.
        {
            SEL originalSelector = @selector(init);
            SEL swizzledSelector = @selector(pushPluginSwizzledInit);

            Method original = class_getInstanceMethod(class, originalSelector);
            Method swizzled = class_getInstanceMethod(class, swizzledSelector);

            BOOL didAddMethod = class_addMethod(class, originalSelector, method_getImplementation(swizzled), method_getTypeEncoding(swizzled));

            if (didAddMethod) {
                class_replaceMethod(class, swizzledSelector, method_getImplementation(original), method_getTypeEncoding(original));
            } else {
                method_exchangeImplementations(original, swizzled);
            }
            PPLOG("+load: init swizzle installed (didAdd=%d)", didAddMethod);
        }

        // Swizzle application:didFinishLaunchingWithOptions: — captures any
        // remote-notification payload from launchOptions before the app's
        // own didFinishLaunching runs. This is the only path that reliably
        // delivers a cold-start tap payload to a Cordova plugin: by the
        // time PushPlugin.pluginInitialize registers its NSNotificationCenter
        // observers, iOS has already called didReceiveNotificationResponse
        // and posted to a NotificationCenter with no observers. The launch-
        // options key is the surviving copy.
        //
        // Only swizzle if the host AppDelegate (or its parent CDVAppDelegate)
        // already implements the selector. CDVAppDelegate always does, so
        // this branch should always be taken in a Cordova app — guarding
        // against the unlikely case prevents an infinite-recursion crash
        // if class_addMethod adds our swizzled impl as the original (then
        // calling [self pushPluginSwizzledApplication:...] would re-enter).
        {
            SEL originalSelector = @selector(application:didFinishLaunchingWithOptions:);
            SEL swizzledSelector = @selector(pushPluginSwizzledApplication:didFinishLaunchingWithOptions:);

            Method original = class_getInstanceMethod(class, originalSelector);
            Method swizzled = class_getInstanceMethod(class, swizzledSelector);

            if (original != NULL) {
                BOOL didAddMethod = class_addMethod(class, originalSelector, method_getImplementation(swizzled), method_getTypeEncoding(swizzled));
                if (didAddMethod) {
                    class_replaceMethod(class, swizzledSelector, method_getImplementation(original), method_getTypeEncoding(original));
                } else {
                    method_exchangeImplementations(original, swizzled);
                }
                PPLOG("+load: didFinishLaunchingWithOptions swizzle installed (didAdd=%d)", didAddMethod);
            } else {
                PPLOG("+load: WARNING — AppDelegate has no application:didFinishLaunchingWithOptions:, cold-start tap payload cannot be captured.");
            }
        }
    });
}

- (AppDelegate *)pushPluginSwizzledInit {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    // This actually calls the original init method over in AppDelegate. Equivilent to calling super
    // on an overrided method, this is not recursive, although it appears that way. neat huh?
    return [self pushPluginSwizzledInit];
}

// Dumps a dict as a JSON string via %s so iOS Console doesn't redact it
// as <private>. Falls back to %@ if serialization fails (e.g. non-JSON
// values like blocks/closures inside).
static NSString *_dumpDict(NSDictionary *dict) {
    if (!dict) return @"(nil)";
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (data) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"(non-JSON: %@)", dict.description];
}

- (BOOL)pushPluginSwizzledApplication:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    PPLOG("swizzledDidFinishLaunching: launchOptions has %lu keys=%{public}s",
          (unsigned long)launchOptions.count, [launchOptions.allKeys.description UTF8String]);

    // Capture the launch-time remote notification payload — surviving copy
    // for the cold-start tap path. Consumed exactly once by
    // PushPlugin.pluginInitialize → +pushPluginConsumeLaunchNotification.
    NSDictionary *launchUserInfo = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
    if ([launchUserInfo isKindOfClass:[NSDictionary class]] && launchUserInfo.count > 0) {
        _pushPluginCapturedLaunchNotification = [launchUserInfo copy];
        PPLOG("swizzledDidFinishLaunching: CAPTURED remote-notification launchOption:\n%{public}s",
              [_dumpDict(launchUserInfo) UTF8String]);
    } else {
        PPLOG("swizzledDidFinishLaunching: no UIApplicationLaunchOptionsRemoteNotificationKey in launchOptions");
    }
    // Call original (this is not recursion — see init swizzle comment above).
    return [self pushPluginSwizzledApplication:application didFinishLaunchingWithOptions:launchOptions];
}

+ (NSDictionary *)pushPluginConsumeLaunchNotification {
    NSDictionary *captured = _pushPluginCapturedLaunchNotification;
    _pushPluginCapturedLaunchNotification = nil;
    if (captured) {
        PPLOG("+pushPluginConsumeLaunchNotification: returning:\n%{public}s",
              [_dumpDict(captured) UTF8String]);
    } else {
        PPLOG("+pushPluginConsumeLaunchNotification: returning nil (already consumed or never captured)");
    }
    return captured;
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    [NSNotificationCenter.defaultCenter postNotificationName:PluginDidRegisterForRemoteNotificationsWithDeviceToken object:deviceToken];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    [NSNotificationCenter.defaultCenter postNotificationName:PluginDidFailToRegisterForRemoteNotificationsWithError object:error];
}

- (void)application:(UIApplication *)application
didReceiveRemoteNotification:(NSDictionary *)userInfo
fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    NSDictionary *notificationInfo = @{@"userInfo" : userInfo, @"completionHandler" : completionHandler};
    [NSNotificationCenter.defaultCenter postNotificationName:PluginDidReceiveRemoteNotification object:nil userInfo:notificationInfo];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    NSDictionary *notificationInfo = @{@"notification" : notification, @"completionHandler" : completionHandler};
    [NSNotificationCenter.defaultCenter postNotificationName:PluginWillPresentNotification object:nil userInfo:notificationInfo];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSDictionary *notificationInfo = @{@"response" : response, @"completionHandler" : completionHandler};
    [NSNotificationCenter.defaultCenter postNotificationName:PluginDidReceiveNotificationResponse object:nil userInfo:notificationInfo];
}

@end
