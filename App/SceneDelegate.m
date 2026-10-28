// Derived from FreeRDP's SceneDelegate, copyright 2013 Thincast Technologies GmbH.
// Author: Martin Fleisz. Modifications for MiptRDP.
// This file is subject to the Mozilla Public License 2.0, https://mozilla.org/MPL/2.0/.
#import "SceneDelegate.h"
#import "MiptApp.h"
@implementation SceneDelegate
@synthesize window = _window;
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    _window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    _window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _window.tintColor = [UIColor colorWithRed:.35 green:.64 blue:1 alpha:1];
    MiptHomeController *home = [[[MiptHomeController alloc] initWithStyle:UITableViewStyleInsetGrouped] autorelease];
    UINavigationController *nav = [[[UINavigationController alloc] initWithRootViewController:home] autorelease];
    nav.navigationBar.prefersLargeTitles = YES;
    _window.rootViewController = nav;
    [_window makeKeyAndVisible];
}
- (void)dealloc { [_window release]; [super dealloc]; }
@end
