/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "AppDelegate.h"
#import "FBAudioBroadcastPickerViewController.h"

@interface AppDelegate ()
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  // GADS audio path: when WDA launches IntegrationApp with this flag (via
  // POST /gads/audio/prepare), swap the storyboard root for a screen that
  // hosts the system broadcast picker. PRD §D4.
  if ([NSProcessInfo.processInfo.arguments containsObject:FBAudioBroadcastPickerLaunchArgument]) {
    if (self.window == nil) {
      self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }
    self.window.rootViewController = [[FBAudioBroadcastPickerViewController alloc] init];
    [self.window makeKeyAndVisible];
  }
  return YES;
}

@end
