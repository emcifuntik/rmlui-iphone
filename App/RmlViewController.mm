#import "RmlViewController.h"

// RmlUi backends
#import "../Backends/RmlUi_Backend_iOS_Metal.h"

// RmlUi core
#include <RmlUi/Core/Core.h>
#include <RmlUi/Core/Context.h>
#include <RmlUi/Core/ElementDocument.h>
#include <RmlUi/Core/Input.h>

// ---- Helpers -------------------------------------------------------------------------

/// Map a UITouch to a 2-D point in the MTKView's coordinate space (points, not pixels).
static Rml::Vector2f TouchPoint(UITouch* touch, UIView* view)
{
    CGPoint p = [touch locationInView:view];
    return {(float)p.x, (float)p.y};
}

// ---- View Controller -----------------------------------------------------------------

@interface RmlViewController () {
    MTKView*              _view;
    id<MTLCommandQueue>   _command_queue;
    Rml::Context*         _context;
    CGFloat               _dp_ratio;
}
@end

@implementation RmlViewController

- (void)loadView
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _view = [[MTKView alloc] initWithFrame:UIScreen.mainScreen.bounds device:device];
    _view.colorPixelFormat     = MTLPixelFormatBGRA8Unorm;
    _view.clearColor           = MTLClearColorMake(0.1, 0.1, 0.15, 1.0);
    _view.delegate             = self;
    _view.preferredFramesPerSecond = 60;
    self.view = _view;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    // Initialise backend (creates Metal resources)
    Backend::Initialize(_view.device, _view);
    _command_queue = [_view.device newCommandQueue];

    // Install interfaces and start RmlUi
    Rml::SetSystemInterface(Backend::GetSystemInterface());
    Rml::SetRenderInterface(Backend::GetRenderInterface());
    Rml::Initialise();

    // Viewport — use UIScreen.nativeBounds for guaranteed physical pixels.
    // _view.drawableSize at viewDidLoad time may still be in points (not yet scaled).
    _dp_ratio = UIScreen.mainScreen.scale;
    CGSize native = UIScreen.mainScreen.nativeBounds.size;
    int phys_w = (int)native.width;
    int phys_h = (int)native.height;
    Backend::SetViewport(phys_w, phys_h);

    // Create context in physical pixels; dp_ratio lets RmlUi express sizes in dp units.
    _context = Rml::CreateContext("main", Rml::Vector2i(phys_w, phys_h));
    _context->SetDensityIndependentPixelRatio((float)_dp_ratio);

    // Load font(s) — copy LatoLatin-Regular.ttf into your Xcode target's "Copy Bundle Resources"
    NSString* font_path = [[NSBundle mainBundle] pathForResource:@"LatoLatin-Regular"
                                                           ofType:@"ttf"];
    if (font_path)
        Rml::LoadFontFace(font_path.UTF8String);
    else
        NSLog(@"[RmlUi] Warning: LatoLatin-Regular.ttf not found in bundle.");

    // Load the demo document
    NSString* doc_path = [[NSBundle mainBundle] pathForResource:@"demo" ofType:@"rml"];
    if (doc_path) {
        Rml::ElementDocument* doc = _context->LoadDocument(doc_path.UTF8String);
        if (doc) doc->Show();
    } else {
        NSLog(@"[RmlUi] Warning: demo.rml not found in bundle — loading inline fallback.");
        [self loadFallbackDocument];
    }
}

- (void)loadFallbackDocument
{
    // Inline RML so the app renders something even without asset files.
    // Bright colors so rendering is visible regardless of font loading.
    const char* rml = R"rml(
<rml>
<head>
  <style>
    body {
      background-color: #ff0000;
      margin: 0dp;
      padding: 0dp;
    }
    div {
      background-color: #00cc00;
      width: 200dp;
      height: 200dp;
      margin: 60dp;
    }
    div div {
      background-color: #0066ff;
      width: 80dp;
      height: 80dp;
      margin: 60dp;
    }
  </style>
</head>
<body>
  <div>
    <div/>
  </div>
</body>
</rml>
)rml";
    Rml::ElementDocument* doc = _context->LoadDocumentFromMemory(rml);
    if (doc) doc->Show();
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (_context) {
        Rml::RemoveContext(_context->GetName());
        _context = nullptr;
    }
    Rml::Shutdown();
    Backend::Shutdown();
}

// ---- MTKViewDelegate -----------------------------------------------------------------

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size
{
    Backend::SetViewport((int)size.width, (int)size.height);
    if (_context)
        _context->SetDimensions(Rml::Vector2i((int)size.width, (int)size.height));
}

- (void)drawInMTKView:(MTKView*)view
{
    if (!_context) return;

    id<MTLCommandBuffer> cmd = [_command_queue commandBuffer];
    MTLRenderPassDescriptor* pass = view.currentRenderPassDescriptor;
    if (!pass || !cmd) return;

    // Clear is configured via MTKView.clearColor; the pass already has load action = Clear.
    Backend::BeginFrame(cmd, pass);

    _context->Update();
    _context->Render();

    Backend::EndFrame();

    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

// ---- Touch input ---------------------------------------------------------------------

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (!_context) return;
    for (UITouch* touch in touches) {
        Rml::Vector2f pt = TouchPoint(touch, _view);
        // Scale from points to physical pixels
        pt.x *= (float)_dp_ratio;
        pt.y *= (float)_dp_ratio;
        _context->ProcessMouseMove((int)pt.x, (int)pt.y, 0);
        _context->ProcessMouseButtonDown(0, 0);
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (!_context) return;
    for (UITouch* touch in touches) {
        Rml::Vector2f pt = TouchPoint(touch, _view);
        pt.x *= (float)_dp_ratio;
        pt.y *= (float)_dp_ratio;
        _context->ProcessMouseMove((int)pt.x, (int)pt.y, 0);
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (!_context) return;
    for (UITouch* touch in touches) {
        Rml::Vector2f pt = TouchPoint(touch, _view);
        pt.x *= (float)_dp_ratio;
        pt.y *= (float)_dp_ratio;
        _context->ProcessMouseMove((int)pt.x, (int)pt.y, 0);
        _context->ProcessMouseButtonUp(0, 0);
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self touchesEnded:touches withEvent:event];
}

@end
