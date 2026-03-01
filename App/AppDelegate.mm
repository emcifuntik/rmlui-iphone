#import "AppDelegate.h"
#import "RmlViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[RmlViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
