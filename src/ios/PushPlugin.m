/*
 Copyright 2009-2011 Urban Airship Inc. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binaryform must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided withthe distribution.

 THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC``AS IS'' AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "PushPlugin.h"
#import "PushPluginConstants.h"
#import "PushPluginFCM.h"
#import "PushPluginSettings.h"
#import "AppDelegate+PushPlugin.h"
#import <os/log.h>

// Public-tagged log macro — iOS 15+ Console redacts NSLog %@/%s output as
// <private> by default. os_log with %{public}s explicitly opts out.
#define PPLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[PushPlugin] " fmt, ##__VA_ARGS__)

// Maximum age (seconds) of a captured cold-start tap payload before it's
// discarded. Cold-start re-delivery re-seeds notificationMessage from the
// pendingColdStartMessage on each init: call, until either JS ACKs receipt
// or this TTL expires. 30s comfortably covers vmplayer's slowest bootstrap
// path (settings page → OAuth → dashboard).
static const NSTimeInterval PushPluginColdStartTTLSeconds = 30.0;

// Dump a dict as a JSON string so iOS Console doesn't redact it as <private>.
static NSString *_dumpDictAsJSON(NSDictionary *dict) {
    if (!dict) return @"(nil)";
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (data) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"(non-JSON: %@)", dict.description];
}

@interface PushPlugin ()

@property (nonatomic, strong) PushPluginFCM *pushPluginFCM;

@property (nonatomic, strong) NSDictionary *launchNotification;
@property (nonatomic, strong) NSDictionary *notificationMessage;

// Cold-start tap pending-redelivery copy. Captured by pluginInitialize
// from the swizzled didFinishLaunchingWithOptions's launchOptions; held
// SEPARATELY from notificationMessage so we can re-seed notificationMessage
// across multiple init: calls (vmplayer's bootstrap goes through 2-3
// WebView page loads — Cordova settings page → dashboard — and only the
// final page has the chat handler subscribed). Cleared once a JS context
// successfully ACKs receipt via the new -acknowledgeColdStart command,
// OR automatically after PushPluginColdStartTTL seconds elapsed since
// capture (defense against an indefinitely "armed" notification that
// would re-fire on every subsequent init: forever).
@property (nonatomic, strong) NSDictionary *pendingColdStartMessage;
@property (nonatomic, strong) NSDate *pendingColdStartCapturedAt;
@property (nonatomic, strong) NSMutableDictionary *handlerObj;
@property (nonatomic, strong) UNNotification *previousNotification;

@property (nonatomic, assign) BOOL isInline;
@property (nonatomic, assign) BOOL clearBadge;
@property (nonatomic, assign) BOOL forceShow;
@property (nonatomic, assign) BOOL coldstart;

@property (nonatomic, copy) void (^backgroundTaskcompletionHandler)(UIBackgroundFetchResult);

@end

@implementation PushPlugin

@synthesize callbackId;

- (void)pluginInitialize {
    self.pushPluginFCM = [[PushPluginFCM alloc] initWithGoogleServicePlist];

    if([self.pushPluginFCM isFCMEnabled]) {
        [self.pushPluginFCM configure:self.commandDelegate];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didRegisterForRemoteNotificationsWithDeviceToken:)
                                                 name:PluginDidRegisterForRemoteNotificationsWithDeviceToken
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didFailToRegisterForRemoteNotificationsWithError:)
                                                 name:PluginDidFailToRegisterForRemoteNotificationsWithError
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didReceiveRemoteNotification:)
                                                 name:PluginDidReceiveRemoteNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pushPluginOnApplicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(willPresentNotification:)
                                                 name:PluginWillPresentNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didReceiveNotificationResponse:)
                                                 name:PluginDidReceiveNotificationResponse
                                               object:nil];

    // Cold-start tap recovery. didFinishLaunchingWithOptions's launchOptions
    // is the only path where the tap-to-launch payload survives long enough
    // for a Cordova plugin to see it: by the time pluginInitialize runs (on
    // the first cordova.exec call from JS), iOS has already called
    // didReceiveNotificationResponse and posted to NSNotificationCenter
    // BEFORE this plugin had registered its observers above — so the post is
    // dropped on the floor. The AppDelegate category swizzles
    // didFinishLaunchingWithOptions: and stashes the launch-time userInfo;
    // we consume it once here and seed self.notificationMessage so init's
    // pending-startup-notification path (~line 192) fires it through to JS.
    PPLOG("pluginInitialize: about to consume launch notification");
    NSDictionary *launchUserInfo = [AppDelegate pushPluginConsumeLaunchNotification];
    if (launchUserInfo) {
        PPLOG("pluginInitialize: RECOVERED cold-start launch notification:\n%{public}s",
              [_dumpDictAsJSON(launchUserInfo) UTF8String]);
        NSMutableDictionary *seeded = [launchUserInfo mutableCopy];
        // Mark coldstart on the message so notificationReceived's additionalData
        // shows coldstart=true for this delivery, matching what a
        // didReceiveNotificationResponse path would produce.
        self.coldstart = YES;
        self.notificationMessage = [seeded copy];
        // Stash a separate copy that survives notificationReceived clearing
        // notificationMessage. Each init: call from a fresh WebView context
        // re-seeds notificationMessage from this copy, so the chat-aware
        // page eventually gets the message even if intermediate pages
        // (settings/login) consumed it first into a JS context that's now
        // gone.
        self.pendingColdStartMessage = [seeded copy];
        self.pendingColdStartCapturedAt = [NSDate date];
    } else {
        PPLOG("pluginInitialize: no launch notification was captured during didFinishLaunching");
    }
}

- (void)unregister:(CDVInvokedUrlCommand *)command {
    NSArray* topics = [command argumentAtIndex:0];

    if (topics != nil) {
        [self.pushPluginFCM unsubscribeFromTopics:topics];
    } else {
        [[UIApplication sharedApplication] unregisterForRemoteNotifications];
        [self successWithMessage:command.callbackId withMsg:@"unregistered"];
    }
}

// JS-callable: acknowledge that the cold-start tap payload has been
// delivered to a handler that will act on it. Clears the pending re-delivery
// so subsequent init: calls don't fire it again.
//
// Without this, the only termination path is the TTL — which means a chat
// tap re-fires through every WebView reload for up to 30s. Calling this
// from the chat-aware page after handling the notification keeps the UX
// clean.
- (void)acknowledgeColdStart:(CDVInvokedUrlCommand *)command {
    if (self.pendingColdStartMessage) {
        PPLOG("acknowledgeColdStart: clearing pending cold-start payload");
    } else {
        PPLOG("acknowledgeColdStart: no pending payload to clear");
    }
    self.pendingColdStartMessage = nil;
    self.pendingColdStartCapturedAt = nil;
    [self successWithMessage:command.callbackId withMsg:@"ok"];
}

- (void)subscribe:(CDVInvokedUrlCommand *)command {
    if (!self.pushPluginFCM.isFCMEnabled) {
        NSLog(@"[PushPlugin] The 'subscribe' API not allowed. FCM is not enabled.");
        [self successWithMessage:command.callbackId withMsg:@"The 'subscribe' API not allowed. FCM is not enabled."];
        return;
    }

    NSString* topic = [command argumentAtIndex:0];
    if (topic == nil) {
        NSLog(@"[PushPlugin] There is no topic to subscribe");
        [self successWithMessage:command.callbackId withMsg:@"There is no topic to subscribe"];
        return;
    }

    [self.pushPluginFCM subscribeToTopic:topic];
    [self successWithMessage:command.callbackId withMsg:[NSString stringWithFormat:@"Successfully subscribe to topic %@", topic]];
}

- (void)unsubscribe:(CDVInvokedUrlCommand *)command {
    if (!self.pushPluginFCM.isFCMEnabled) {
        NSLog(@"[PushPlugin] The 'unsubscribe' API not allowed. FCM is not enabled.");
        [self successWithMessage:command.callbackId withMsg:@"The 'unsubscribe' API not allowed. FCM is not enabled."];
        return;
    }

    NSString* topic = [command argumentAtIndex:0];
    if (topic == nil) {
        NSLog(@"[PushPlugin] There is no topic to unsubscribe from.");
        [self successWithMessage:command.callbackId withMsg:@"There is no topic to unsubscribe from."];
        return;
    }

    [self.pushPluginFCM unsubscribeFromTopic:topic];
    [self successWithMessage:command.callbackId withMsg:[NSString stringWithFormat:@"Successfully unsubscribe from topic %@", topic]];
}

- (void)init:(CDVInvokedUrlCommand *)command {
    NSMutableDictionary* options = [command.arguments objectAtIndex:0];
    [[PushPluginSettings sharedInstance] updateSettingsWithOptions:[options objectForKey:@"ios"]];
    PushPluginSettings *settings = [PushPluginSettings sharedInstance];

    if ([self.pushPluginFCM isFCMEnabled]) {
        self.pushPluginFCM.callbackId = command.callbackId;
    }

    self.callbackId = command.callbackId;

    // Cold-start tap re-delivery. vmplayer's bootstrap goes through several
    // WebView page loads (settings/login → dashboard); only the final page
    // has the chat handler subscribed. The original 1.0 logic clears
    // notificationMessage after the FIRST send, so a kill+tap delivers the
    // payload to whichever JS context happens to call init: first — which
    // is likely an intermediate page that has no chat code. By the time
    // the dashboard arrives and calls init: again, the payload is gone.
    //
    // Fix: re-seed notificationMessage from the pending cold-start copy
    // each time init: runs, until either the JS layer ACKs delivery via
    // -acknowledgeColdStart OR the TTL expires. The init: method's
    // existing pending-startup-notification path (~50 lines below) then
    // schedules notificationReceived after 0.5s, exactly as for a first-
    // time delivery.
    if (self.pendingColdStartMessage != nil) {
        NSTimeInterval age = -[self.pendingColdStartCapturedAt timeIntervalSinceNow];
        if (age > PushPluginColdStartTTLSeconds) {
            PPLOG("init: pendingColdStartMessage expired (age=%.1fs > TTL=%.1fs), discarding",
                  age, (double)PushPluginColdStartTTLSeconds);
            self.pendingColdStartMessage = nil;
            self.pendingColdStartCapturedAt = nil;
        } else if (self.notificationMessage == nil) {
            PPLOG("init: re-seeding notificationMessage from pendingColdStartMessage (age=%.1fs)", age);
            self.notificationMessage = [self.pendingColdStartMessage copy];
            self.coldstart = YES;
        }
    }

    if ([settings voipEnabled]) {
        [self.commandDelegate runInBackground:^ {
            NSLog(@"[PushPlugin] VoIP set to true");
            PKPushRegistry *pushRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
            pushRegistry.delegate = self;
            pushRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
        }];
    } else {
        NSLog(@"[PushPlugin] VoIP missing or false");

        [self.commandDelegate runInBackground:^ {
            NSLog(@"[PushPlugin] register called");
            self.isInline = NO;
            self.forceShow = [settings forceShowEnabled];
            self.clearBadge = [settings clearBadgeEnabled];
            if (self.clearBadge) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
                });
            }

            UNAuthorizationOptions authorizationOptions = UNAuthorizationOptionNone;
            if ([settings badgeEnabled]) {
                authorizationOptions |= UNAuthorizationOptionBadge;
            }
            if ([settings soundEnabled]) {
                authorizationOptions |= UNAuthorizationOptionSound;
            }
            if ([settings alertEnabled]) {
                authorizationOptions |= UNAuthorizationOptionAlert;
            }
            if (@available(iOS 12.0, *))
            {
                if ([settings criticalEnabled]) {
                    authorizationOptions |= UNAuthorizationOptionCriticalAlert;
                }
            }
            [self handleNotificationSettingsWithAuthorizationOptions:[NSNumber numberWithInteger:authorizationOptions]];

            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            [center setNotificationCategories:[settings categories]];

            // If there is a pending startup notification, we will delay to allow JS event handlers to setup
            if (self.notificationMessage) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self performSelector:@selector(notificationReceived) withObject:nil afterDelay: 0.5];
                });
            }
        }];
    }
}

- (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSNotification *)notification {
    NSData *deviceToken = notification.object;

    if (self.callbackId == nil) {
        NSLog(@"[PushPlugin] An unexpected case was triggered where the callbackId is missing during the register for remote notification. (device token: %@)", deviceToken);
        return;
    }

    NSLog(@"[PushPlugin] Successfully registered device for remote notification. (device token: %@)", deviceToken);

    if ([self.pushPluginFCM isFCMEnabled]) {
        [self.pushPluginFCM configureTokens:deviceToken];
    } else {
        [self registerWithToken:[self convertTokenToString:deviceToken]];
    }
}

- (NSString *)convertTokenToString:(NSData *)deviceToken {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    // [deviceToken description] is like "{length = 32, bytes = 0xd3d997af 967d1f43 b405374a 13394d2f ... 28f10282 14af515f }"
    return [self hexadecimalStringFromData:deviceToken];
#else
    // [deviceToken description] is like "<124686a5 556a72ca d808f572 00c323b9 3eff9285 92445590 3225757d b83967be>"
    return [[[[deviceToken description] stringByReplacingOccurrencesOfString:@"<"withString:@""]
                        stringByReplacingOccurrencesOfString:@">" withString:@""]
                       stringByReplacingOccurrencesOfString: @" " withString: @""];
#endif
}

- (NSString *)hexadecimalStringFromData:(NSData *)data {
    NSUInteger dataLength = data.length;
    if (dataLength == 0) {
        return nil;
    }

    const unsigned char *dataBuffer = data.bytes;
    NSMutableString *hexString  = [NSMutableString stringWithCapacity:(dataLength * 2)];
    for (int i = 0; i < dataLength; ++i) {
        [hexString appendFormat:@"%02x", dataBuffer[i]];
    }
    return [hexString copy];
}

- (void)didFailToRegisterForRemoteNotificationsWithError:(NSNotification *)notification {
    NSError *error = (NSError *)notification.object;

    if (self.callbackId == nil) {
        NSLog(@"[PushPlugin] An unexpected case was triggered where the callbackId is missing during the failure to register for remote notification. (error: %@)", error);
        return;
    }

    NSLog(@"[PushPlugin] Failed to register for remote notification with error: %@", error);
    [self failWithMessage:self.callbackId withMsg:@"Failed to register for remote notification." withError:error];
}

- (void)didReceiveRemoteNotification:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo[@"userInfo"];

    PPLOG("didReceiveRemoteNotification — full userInfo:\n%{public}s",
          [_dumpDictAsJSON(userInfo) UTF8String]);

    void (^completionHandler)(UIBackgroundFetchResult) = notification.userInfo[@"completionHandler"];

    // app is in the background or inactive, so only call notification callback if this is a silent push
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        NSLog(@"[PushPlugin] app in-active");
        // do some convoluted logic to find out if this should be a silent push.
        long silent = 0;
        id aps = [userInfo objectForKey:@"aps"];

        id contentAvailable = [aps objectForKey:@"content-available"];
        if ([contentAvailable isKindOfClass:[NSString class]] && [contentAvailable isEqualToString:@"1"]) {
            silent = 1;
        } else if ([contentAvailable isKindOfClass:[NSNumber class]]) {
            silent = [contentAvailable integerValue];
        }

        if (silent == 1) {
            NSLog(@"[PushPlugin] this should be a silent push");
            void (^safeHandler)(UIBackgroundFetchResult) = ^(UIBackgroundFetchResult result){
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(result);
                });
            };

            if (self.handlerObj == nil) {
                self.handlerObj = [NSMutableDictionary dictionaryWithCapacity:2];
            }

            // Get the notId
            NSMutableDictionary *mutableUserInfo = [userInfo mutableCopy];
            id notId = [mutableUserInfo objectForKey:@"notId"];
            NSString *notIdKey = notId != nil ? [NSString stringWithFormat:@"%@", notId] : nil;

            if (notIdKey == nil) {
                // Create a unique notId
                notIdKey = [NSString stringWithFormat:@"pushplugin-handler-%f", [NSDate timeIntervalSinceReferenceDate]];
                // Add the unique notId to the userInfo. Passes to front-end payload.
                [mutableUserInfo setValue:notIdKey forKey:@"notId"];
                // Store the handler for the uniquly created notId.
            }

            [self.handlerObj setObject:safeHandler forKey:notIdKey];

            NSLog(@"[PushPlugin] Stored the completion handler for the background processing of notId %@", notIdKey);

            PPLOG("didReceiveRemoteNotification (silent): OVERWRITING notificationMessage with:\n%{public}s",
                  [_dumpDictAsJSON(mutableUserInfo) UTF8String]);
            self.notificationMessage = [mutableUserInfo copy];
            self.isInline = NO;
            [self notificationReceived];
        } else {
            NSLog(@"[PushPlugin] Application is not active, saving notification for later.");

            self.launchNotification = userInfo;
            completionHandler(UIBackgroundFetchResultNewData);
        }
    } else {
        completionHandler(UIBackgroundFetchResultNoData);
    }
}

- (void)pushPluginOnApplicationDidBecomeActive:(NSNotification *)notification {
    NSLog(@"[PushPlugin] pushPluginOnApplicationDidBecomeActive");

    NSString *firstLaunchKey = @"firstLaunchKey";
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"phonegap-plugin-push"];
    if (![defaults boolForKey:firstLaunchKey]) {
        NSLog(@"[PushPlugin] application first launch: remove badge icon number");
        [defaults setBool:YES forKey:firstLaunchKey];
        [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
    }

    UIApplication *application = notification.object;

    if (self.clearBadge) {
        NSLog(@"[PushPlugin] clearing badge");
        application.applicationIconBadgeNumber = 0;
    } else {
        NSLog(@"[PushPlugin] skip clear badge");
    }

    if (self.launchNotification) {
        PPLOG("pushPluginOnApplicationDidBecomeActive: copying launchNotification → notificationMessage:\n%{public}s",
              [_dumpDictAsJSON(self.launchNotification) UTF8String]);
        self.notificationMessage = self.launchNotification;
        self.launchNotification = nil;
        [self performSelectorOnMainThread:@selector(notificationReceived) withObject:self waitUntilDone:NO];
    } else {
        PPLOG("pushPluginOnApplicationDidBecomeActive: launchNotification is nil, no-op");
    }
}

- (void)willPresentNotification:(NSNotification *)notification {
    NSLog(@"[PushPlugin] Notification was received while the app was in the foreground. (willPresentNotification)");

    UIApplicationState applicationState = [UIApplication sharedApplication].applicationState;
    NSNumber *applicationStateNumber = @((int)applicationState);

    // The original notification that comes from the AppDelegate's willPresentNotification.
    UNNotification *originalNotification = notification.userInfo[@"notification"];
    NSDictionary *originalUserInfo = originalNotification.request.content.userInfo;
    NSMutableDictionary *modifiedUserInfo = [originalUserInfo mutableCopy];
    [modifiedUserInfo setObject:applicationStateNumber forKey:@"applicationState"];

    void (^completionHandler)(UNNotificationPresentationOptions) = notification.userInfo[@"completionHandler"];

    if (@available(iOS 18.0, *)) {
        if (@available(iOS 18.1, *)) {
            // Do nothing for iOS 18.1 and higher.
        } else {
            // Note: In iOS 18.0, there is a known issue where "willPresentNotification" is triggered twice for a single payload.
            // The "willPresentNotification" method is normally triggered when a notification is received while the app is in the
            // foreground. Due to this bug, the notification payload is delivered twice, causing the front-end to process the
            // notification event twice as well. This behavior is unintended, so this block of code checks if the payload is a
            // duplicate by comparing the payload content and the timestamp of when it was received.
            NSLog(@"[PushPlugin] Checking for duplicate notification presentation.");
            if ([self isDuplicateNotification:originalNotification]) {
                NSLog(@"[PushPlugin] Duplicate notification detected; processing will be skipped.");
                if (completionHandler) {
                    completionHandler(UNNotificationPresentationOptionNone);
                }
                // Cleanup to remove previous notification to remove leaks
                self.previousNotification = nil;
                return;
            }
            // If it was not duplicate, we will store it to check for the potential second notification
            self.previousNotification = originalNotification;
        }
    }

    self.notificationMessage = [modifiedUserInfo copy];
    self.isInline = YES;
    [self notificationReceived];

    UNNotificationPresentationOptions presentationOption = UNNotificationPresentationOptionNone;
    if (@available(iOS 10, *)) {
        if(self.forceShow) {
            presentationOption = UNNotificationPresentationOptionAlert;
        }
    }

    if (completionHandler) {
        completionHandler(presentationOption);
    }
}

- (void)didReceiveNotificationResponse:(NSNotification *)notification {
    // The original response that comes from the AppDelegate's didReceiveNotificationResponse.
    UNNotificationResponse *response = notification.userInfo[@"response"];

    PPLOG("didReceiveNotificationResponse — actionIdentifier=%{public}s userInfo:\n%{public}s",
          [response.actionIdentifier UTF8String],
          [_dumpDictAsJSON(response.notification.request.content.userInfo) UTF8String]);

    void (^completionHandler)(void) = notification.userInfo[@"completionHandler"];

    UIApplicationState applicationState = [UIApplication sharedApplication].applicationState;
    NSNumber *applicationStateNumber = @((int)applicationState);
    NSDictionary *originalUserInfo = response.notification.request.content.userInfo;
    NSMutableDictionary *modifiedUserInfo = [originalUserInfo mutableCopy];
    [modifiedUserInfo setObject:applicationStateNumber forKey:@"applicationState"];
    [modifiedUserInfo setObject:response.actionIdentifier forKey:@"actionCallback"];

    switch (applicationState) {
        case UIApplicationStateActive:
        {
            NSLog(@"[PushPlugin] App is active. Notification message set with: %@", modifiedUserInfo);

            self.isInline = NO;
            self.notificationMessage = [modifiedUserInfo copy];
            [self notificationReceived];
            if (completionHandler) {
                completionHandler();
            }
            break;
        }
        case UIApplicationStateInactive:
        {
            NSLog(@"[PushPlugin] App is inactive. Storing notification message for later launch with: %@", modifiedUserInfo);

            self.coldstart = YES;
            self.launchNotification = [modifiedUserInfo copy];
            if (completionHandler) {
                completionHandler();
            }
            break;
        }
        case UIApplicationStateBackground:
        {
            NSLog(@"[PushPlugin] App is in the background. Notification message set with: %@", modifiedUserInfo);

            void (^safeHandler)(void) = ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completionHandler) {
                        completionHandler();
                    }
                });
            };

            if (self.handlerObj == nil) {
                self.handlerObj = [NSMutableDictionary dictionaryWithCapacity:2];
            }

            // Get the notId
            id notId = modifiedUserInfo[@"notId"];
            NSString *notIdKey = notId != nil ? [NSString stringWithFormat:@"%@", notId] : nil;

            if (notIdKey == nil) {
                // Create a unique notId
                notIdKey = [NSString stringWithFormat:@"pushplugin-handler-%f", [NSDate timeIntervalSinceReferenceDate]];
                // Add the unique notId to the userInfo. Passes to front-end payload.
                [modifiedUserInfo setValue:notIdKey forKey:@"notId"];
                // Store the handler for the uniquly created notId.
            }

            [self.handlerObj setObject:safeHandler forKey:notIdKey];

            NSLog(@"[PushPlugin] Stored the completion handler for the background processing of notId %@", notIdKey);

            self.isInline = NO;
            self.notificationMessage = [modifiedUserInfo copy];

            [self performSelectorOnMainThread:@selector(notificationReceived) withObject:self waitUntilDone:NO];
            break;
        }
    }
}

- (void)notificationReceived {
    PPLOG("notificationReceived: hasMessage=%d hasCallbackId=%d coldstart=%d isInline=%d",
          (self.notificationMessage != nil),
          (self.callbackId != nil),
          self.coldstart,
          self.isInline);

    if (self.notificationMessage && self.callbackId != nil)
    {
        NSMutableDictionary* mutableNotificationMessage = [self.notificationMessage mutableCopy];
        NSMutableDictionary* message = [NSMutableDictionary dictionaryWithCapacity:4];
        NSMutableDictionary* additionalData = [NSMutableDictionary dictionaryWithCapacity:4];

        // Remove "actionCallback" when application state is not foreground. Only applied to foreground.
        NSNumber *applicationStateNumber = mutableNotificationMessage[@"applicationState"];
        UIApplicationState applicationState = (UIApplicationState)[applicationStateNumber intValue];
        if (applicationState != UIApplicationStateActive
            && [[mutableNotificationMessage objectForKey:@"actionCallback"] isEqualToString:UNNotificationDefaultActionIdentifier]) {
            [mutableNotificationMessage removeObjectForKey:@"actionCallback"];
        }
        // @todo do not sent applicationState data to front for now. Figure out if we can add
        // similar data to the other platforms.
        [mutableNotificationMessage removeObjectForKey:@"applicationState"];
        self.notificationMessage = [mutableNotificationMessage copy];

        for (id key in self.notificationMessage) {
            if ([key isEqualToString:@"aps"]) {
                id aps = [self.notificationMessage objectForKey:@"aps"];

                for(id key in aps) {
                    NSLog(@"[PushPlugin] key: %@", key);
                    id value = [aps objectForKey:key];

                    if ([key isEqualToString:@"alert"]) {
                        if ([value isKindOfClass:[NSDictionary class]]) {
                            for (id messageKey in value) {
                                id messageValue = [value objectForKey:messageKey];
                                if ([messageKey isEqualToString:@"body"]) {
                                    [message setObject:messageValue forKey:@"message"];
                                } else if ([messageKey isEqualToString:@"title"]) {
                                    [message setObject:messageValue forKey:@"title"];
                                } else {
                                    [additionalData setObject:messageValue forKey:messageKey];
                                }
                            }
                        }
                        else {
                            [message setObject:value forKey:@"message"];
                        }
                    } else if ([key isEqualToString:@"title"]) {
                        [message setObject:value forKey:@"title"];
                    } else if ([key isEqualToString:@"badge"]) {
                        [message setObject:value forKey:@"count"];
                    } else if ([key isEqualToString:@"sound"]) {
                        [message setObject:value forKey:@"sound"];
                    } else if ([key isEqualToString:@"image"]) {
                        [message setObject:value forKey:@"image"];
                    } else {
                        [additionalData setObject:value forKey:key];
                    }
                }
            } else {
                [additionalData setObject:[self.notificationMessage objectForKey:key] forKey:key];
            }
        }

        if (self.isInline) {
            [additionalData setObject:[NSNumber numberWithBool:YES] forKey:@"foreground"];
        } else {
            [additionalData setObject:[NSNumber numberWithBool:NO] forKey:@"foreground"];
        }

        if (self.coldstart) {
            [additionalData setObject:[NSNumber numberWithBool:YES] forKey:@"coldstart"];
        } else {
            [additionalData setObject:[NSNumber numberWithBool:NO] forKey:@"coldstart"];
        }

        [message setObject:additionalData forKey:@"additionalData"];

        PPLOG("notificationReceived: SENDING TO JS (callbackId=%{public}s):\n%{public}s",
              [self.callbackId UTF8String], [_dumpDictAsJSON(message) UTF8String]);
        // send notification message
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
        [pluginResult setKeepCallbackAsBool:YES];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];

        self.coldstart = NO;
        self.isInline = NO;
        self.notificationMessage = nil;
    }
}

- (void)clearNotification:(CDVInvokedUrlCommand *)command {
    NSNumber *notId = [command.arguments objectAtIndex:0];
    [[UNUserNotificationCenter currentNotificationCenter] getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications) {
        /*
         * If the server generates a unique "notId" for every push notification, there should only be one match in these arrays, but if not, it will delete
         * all notifications with the same value for "notId"
         */
        NSPredicate *matchingNotificationPredicate = [NSPredicate predicateWithFormat:@"request.content.userInfo.notId == %@", notId];
        NSArray<UNNotification *> *matchingNotifications = [notifications filteredArrayUsingPredicate:matchingNotificationPredicate];
        NSMutableArray<NSString *> *matchingNotificationIdentifiers = [NSMutableArray array];
        for (UNNotification *notification in matchingNotifications) {
            [matchingNotificationIdentifiers addObject:notification.request.identifier];
        }
        [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:matchingNotificationIdentifiers];

        NSString *message = [NSString stringWithFormat:@"Cleared notification with ID: %@", notId];
        CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
        [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
    }];
}

- (void)setApplicationIconBadgeNumber:(CDVInvokedUrlCommand *)command {
    NSMutableDictionary* options = [command.arguments objectAtIndex:0];
    int badge = [[options objectForKey:@"badge"] intValue] ?: 0;

    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:badge];

    NSString* message = [NSString stringWithFormat:@"app badge count set to %d", badge];
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
    [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
}

- (void)getApplicationIconBadgeNumber:(CDVInvokedUrlCommand *)command {
    NSInteger badge = [UIApplication sharedApplication].applicationIconBadgeNumber;

    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(int)badge];
    [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
}

- (void)clearAllNotifications:(CDVInvokedUrlCommand *)command {
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];

    NSString* message = [NSString stringWithFormat:@"cleared all notifications"];
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
    [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
}

- (void)hasPermission:(CDVInvokedUrlCommand *)command {
    if ([self respondsToSelector:@selector(checkUserHasRemoteNotificationsEnabledWithCompletionHandler:)]) {
        [self performSelector:@selector(checkUserHasRemoteNotificationsEnabledWithCompletionHandler:) withObject:^(BOOL isEnabled) {
            NSMutableDictionary* message = [NSMutableDictionary dictionaryWithCapacity:1];
            [message setObject:[NSNumber numberWithBool:isEnabled] forKey:@"isEnabled"];
            CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
            [self.commandDelegate sendPluginResult:commandResult callbackId:command.callbackId];
        }];
    }
}

- (void)successWithMessage:(NSString *)myCallbackId withMsg:(NSString *)message {
    if (myCallbackId != nil)
    {
        CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
        [self.commandDelegate sendPluginResult:commandResult callbackId:myCallbackId];
    }
}

- (void)registerWithToken:(NSString *)token {
    NSMutableDictionary* message = [NSMutableDictionary dictionaryWithCapacity:2];
    [message setObject:token forKey:@"registrationId"];
    [message setObject:@"APNS" forKey:@"registrationType"];

    // Send result to trigger 'registration' event but keep callback
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:message];
    [pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void)failWithMessage:(NSString *)myCallbackId withMsg:(NSString *)message withError:(NSError *)error {
    NSString        *errorMessage = (error) ? [NSString stringWithFormat:@"%@ - %@", message, [error localizedDescription]] : message;
    CDVPluginResult *commandResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];

    [self.commandDelegate sendPluginResult:commandResult callbackId:myCallbackId];
}

- (void) finish:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate runInBackground:^ {
        NSString* notId = [command.arguments objectAtIndex:0];

        if (notId == nil || [notId isKindOfClass:[NSNull class]]) {
            // @todo review "didReceiveNotificationResponse"
            NSLog(@"[PushPlugin] Skipping 'finish' API as notId is unavailable.");
        } else {
            NSLog(@"[PushPlugin] The 'finish' API was triggered for notId: %@", notId);
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"[PushPlugin] Creating timer scheduled for notId: %@", notId);
                [NSTimer scheduledTimerWithTimeInterval:0.1
                                                 target:self
                                               selector:@selector(stopBackgroundTask:)
                                               userInfo:notId
                                                repeats:NO];
            });
        }

        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

- (void)stopBackgroundTask:(NSTimer *)timer {
    // If the handler object is nil, there is nothing to process
    if (!self.handlerObj) {
        NSLog(@"[PushPlugin] Warning (stopBackgroundTask): handlerObj was nil.");
        return;
    }

    // Get the notification ID from the timer's userInfo dictionary
    NSString *notId = (NSString *)[timer userInfo];

    // Get the safe handler (completionHandler) for the notification ID.
    void (^safeHandler)(UIBackgroundFetchResult) = self.handlerObj[notId];

    // If the handler is missing for the notification ID, nothing to process.
    if (!safeHandler) {
        NSLog(@"[PushPlugin] Warning (stopBackgroundTask): No handler was found for notId: %@.", notId);
        return;
    }

    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState == UIApplicationStateBackground) {
        NSLog(@"[PushPlugin] Processing background task for notId: %@. Background time remaining: %f", notId, app.backgroundTimeRemaining);
    } else {
        NSLog(@"[PushPlugin] Processing background task for notId: %@. App is now in the foreground.", notId);
    }

    // Execute the handler to complete the background task
    safeHandler(UIBackgroundFetchResultNewData);

    // Remove the handler to prevent memory leaks.
    [self.handlerObj removeObjectForKey:notId];
    NSLog(@"[PushPlugin] Removed handler for notId: %@", notId);
}

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(NSString *)type {
    if([credentials.token length] == 0) {
        NSLog(@"[PushPlugin] VoIP register error - No device token:");
        return;
    }

    NSLog(@"[PushPlugin] VoIP register success");
    const unsigned *tokenBytes = [credentials.token bytes];
    NSString *sToken = [NSString stringWithFormat:@"%08x%08x%08x%08x%08x%08x%08x%08x",
                        ntohl(tokenBytes[0]), ntohl(tokenBytes[1]), ntohl(tokenBytes[2]),
                        ntohl(tokenBytes[3]), ntohl(tokenBytes[4]), ntohl(tokenBytes[5]),
                        ntohl(tokenBytes[6]), ntohl(tokenBytes[7])];

    [self registerWithToken:sToken];
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(NSString *)type {
    NSLog(@"[PushPlugin] VoIP Notification received");
    self.notificationMessage = payload.dictionaryPayload;
    [self notificationReceived];
}

- (void)handleNotificationSettingsWithAuthorizationOptions:(NSNumber *)authorizationOptionsObject {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    UNAuthorizationOptions authorizationOptions = [authorizationOptionsObject unsignedIntegerValue];

    __weak UNUserNotificationCenter *weakCenter = center;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            // If the status is not determined, request permissions
            [weakCenter requestAuthorizationWithOptions:authorizationOptions completionHandler:^(BOOL granted, NSError * _Nullable error) {
                if (error) {
                    NSLog(@"[PushPlugin] Error during authorization request: %@", error.localizedDescription);
                }

                if (granted) {
                    NSLog(@"[PushPlugin] Notification permissions granted.");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[UIApplication sharedApplication] registerForRemoteNotifications];
                    });
                } else {
                    NSLog(@"[PushPlugin] Notification permissions denied.");
                }
            }];
        } else {
            UNAuthorizationOptions currentGrantedOptions = UNAuthorizationOptionNone;

            // Check for current granted permissions
            if (settings.badgeSetting == UNNotificationSettingEnabled) {
                currentGrantedOptions |= UNAuthorizationOptionBadge;
            }
            if (settings.soundSetting == UNNotificationSettingEnabled) {
                currentGrantedOptions |= UNAuthorizationOptionSound;
            }
            if (settings.alertSetting == UNNotificationSettingEnabled) {
                currentGrantedOptions |= UNAuthorizationOptionAlert;
            }
            if (@available(iOS 12.0, *)) {
                if (settings.criticalAlertSetting == UNNotificationSettingEnabled) {
                    currentGrantedOptions |= UNAuthorizationOptionCriticalAlert;
                }
            }

            // Compare the requested with granted permissions. Find which are missing.
            UNAuthorizationOptions newAuthorizationOptions = authorizationOptions & ~currentGrantedOptions;

            // Request for the permissions that were not already requested for.
            if (newAuthorizationOptions != UNAuthorizationOptionNone) {
                [weakCenter requestAuthorizationWithOptions:newAuthorizationOptions completionHandler:^(BOOL granted, NSError * _Nullable error) {
                    if (error) {
                        NSLog(@"[PushPlugin] Error during authorization request: %@", error.localizedDescription);
                    }

                    if (granted) {
                        NSLog(@"[PushPlugin] New notification permissions granted.");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[UIApplication sharedApplication] registerForRemoteNotifications];
                        });
                    } else {
                        NSLog(@"[PushPlugin] User denied new notification permissions.");
                    }
                }];
            } else {
                NSLog(@"[PushPlugin] All requested permissions were processed.");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[UIApplication sharedApplication] registerForRemoteNotifications];
                });
            }
        }
    }];
}

- (void)checkUserHasRemoteNotificationsEnabledWithCompletionHandler:(nonnull void (^)(BOOL))completionHandler {
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {

        switch (settings.authorizationStatus)
        {
            case UNAuthorizationStatusDenied:
            case UNAuthorizationStatusNotDetermined:
                completionHandler(NO);
                break;

            case UNAuthorizationStatusAuthorized:
            case UNAuthorizationStatusEphemeral:
            case UNAuthorizationStatusProvisional:
                completionHandler(YES);
                break;
        }
    }];
}

- (BOOL)isDuplicateNotification:(UNNotification *)notification {
    BOOL isDuplicate = NO;
    if (self.previousNotification) {
        // Extract relevant data from the current notification
        NSDate *currentNotificationDate = notification.date;
        NSDictionary *currentPayload = notification.request.content.userInfo;
        // Extract relevant data from the previous notification
        NSDate *previousNotificationDate = self.previousNotification.date;
        NSDictionary *previousPayload = self.previousNotification.request.content.userInfo;
        // Compare the date timestamp
        BOOL isSameDate = [currentNotificationDate isEqualToDate:previousNotificationDate];
        // Compare the payload content
        BOOL isSamePayload = [currentPayload isEqualToDictionary:previousPayload];
        isDuplicate = isSameDate && isSamePayload;
    }
    return isDuplicate;
}

- (void)dealloc {
    self.previousNotification = nil;
    self.launchNotification = nil;
    self.coldstart = nil;
}

@end
