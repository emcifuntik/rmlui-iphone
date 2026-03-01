#pragma once
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>

/**
 * Main view controller. Hosts an MTKView and drives the RmlUi render loop.
 */
@interface RmlViewController : UIViewController <MTKViewDelegate>
@end
