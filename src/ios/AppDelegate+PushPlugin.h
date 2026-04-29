//
//  AppDelegate+PushPlugin.h
//
//  Created by Robert Easterday on 10/26/12.
//

#import "AppDelegate.h"

@import UserNotifications;

@interface AppDelegate (PushPlugin) <UNUserNotificationCenterDelegate>

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken;
- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error;
- (void)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler;

/**
 * Returns and clears the cold-start remote-notification payload captured
 * from `launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey]`
 * during didFinishLaunching. Called once by PushPlugin.pluginInitialize
 * to seed self.notificationMessage so the cold-start tap fires through
 * to JS even though the plugin's NSNotificationCenter observers register
 * after the AppDelegate's didReceiveNotificationResponse has already run.
 *
 * Returns nil if there was no remote notification in launchOptions
 * (i.e. the app was launched normally, not from a tap).
 */
+ (NSDictionary *)pushPluginConsumeLaunchNotification;

@end
