#import "RmlViewController.h"
#import <QuartzCore/CABase.h>   // CACurrentMediaTime()

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

// ---- Keyboard host -------------------------------------------------------------------
//
// A zero-size UIView that holds first-responder status so UIKit shows / hides
// the software keyboard.  All key events are forwarded to the RmlUi context.

@interface RmlKeyInput : UIView <UIKeyInput>
@property (nonatomic, assign) Rml::Context* rmlContext;
@end

@implementation RmlKeyInput

- (BOOL)canBecomeFirstResponder { return YES; }

// Always return YES so the Delete key is never disabled.
- (BOOL)hasText { return YES; }

- (void)insertText:(NSString*)text
{
    if (!_rmlContext) return;
    if ([text isEqualToString:@"\n"]) {
        // Return key — send to RmlUi and dismiss keyboard.
        _rmlContext->ProcessKeyDown(Rml::Input::KI_RETURN, 0);
        _rmlContext->ProcessKeyUp(Rml::Input::KI_RETURN, 0);
        [self resignFirstResponder];
        return;
    }
    if (text.length > 0)
        _rmlContext->ProcessTextInput(Rml::String(text.UTF8String));
}

- (void)deleteBackward
{
    if (!_rmlContext) return;
    _rmlContext->ProcessKeyDown(Rml::Input::KI_BACK, 0);
    _rmlContext->ProcessKeyUp(Rml::Input::KI_BACK, 0);
}

// Suppress autocorrect / capitalisation / spellcheck on this raw input proxy.
- (UITextAutocorrectionType)autocorrectionType  { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextSpellCheckingType)spellCheckingType     { return UITextSpellCheckingTypeNo; }

@end

// ---- View Controller -----------------------------------------------------------------

@interface RmlViewController () {
    MTKView*                _view;
    id<MTLCommandQueue>     _command_queue;
    Rml::Context*           _context;
    Rml::ElementDocument*   _document;
    Rml::Element*           _guild_panel;    // #guilds  — left scroll column
    Rml::Element*           _channel_panel;  // #channels — right scroll column
    Rml::Element*           _scroll_target;  // which column the current touch is scrolling
    CGFloat                 _dp_ratio;
    // Touch state — distinguishes taps from scroll gestures
    CGPoint               _touch_start;      // UIKit logical points at touch-down
    CGPoint               _touch_last;       // UIKit logical points from previous touchesMoved
    BOOL                  _is_scrolling;
    // Momentum / inertia state
    float                 _velocity_y;       // logical points per second (positive = scroll down)
    BOOL                  _momentum_active;
    double                _last_move_time;   // timestamp of previous touchesMoved call
    double                _last_frame_time;  // timestamp of previous drawInMTKView call
    // Keyboard input proxy
    RmlKeyInput*          _key_input;
}
@end

@implementation RmlViewController

- (void)loadView
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _view = [[MTKView alloc] initWithFrame:UIScreen.mainScreen.bounds device:device];
    _view.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
    _view.depthStencilPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    _view.clearColor              = MTLClearColorMake(0.1, 0.1, 0.15, 1.0);
    _view.clearStencil            = 0;
    _view.delegate                = self;
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

    // Keyboard proxy — a 1×1 view hidden above the screen; becomes first responder
    // when an RmlUi <input> element is focused to summon/dismiss the software keyboard.
    _key_input = [[RmlKeyInput alloc] initWithFrame:CGRectMake(0, -2, 1, 1)];
    _key_input.rmlContext = _context;
    [_view addSubview:_key_input];

    // Keyboard avoidance — resize MTKView + RmlUi context when keyboard appears/disappears.
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(keyboardWillShow:)
        name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(keyboardWillHide:)
        name:UIKeyboardWillHideNotification object:nil];

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
        _document = _context->LoadDocument(doc_path.UTF8String);
        if (_document) {
            _document->Show();
            _guild_panel   = _document->GetElementById("guilds");
            _channel_panel = _document->GetElementById("channels");
        }
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

// ---- Keyboard avoidance --------------------------------------------------------------

- (void)keyboardWillShow:(NSNotification*)note
{
    CGRect kb     = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect screen = UIScreen.mainScreen.bounds;
    NSTimeInterval dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];

    // Only shift if the focused input is in the lower half of the screen; inputs
    // already in the upper half stay put so the view doesn't move unnecessarily.
    CGFloat shift_y = 0;
    if (_context) {
        Rml::Element* focused = _context->GetFocusElement();
        if (focused) {
            // Element bottom in physical px → UIKit logical points.
            float bottom_pt = (focused->GetAbsoluteTop() + focused->GetClientHeight())
                              / (float)_dp_ratio;
            if (bottom_pt > screen.size.height / 2.0f)
                shift_y = -kb.size.height;
        }
    }

    // Translate the whole MTKView up — no resize, no viewport change, no scissor issues.
    [UIView animateWithDuration:dur animations:^{
        self->_view.frame = CGRectMake(0, shift_y, screen.size.width, screen.size.height);
    }];
}

- (void)keyboardWillHide:(NSNotification*)note
{
    CGRect screen = UIScreen.mainScreen.bounds;
    NSTimeInterval dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:dur animations:^{
        self->_view.frame = screen;
    }];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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

    // Apply scroll momentum before RmlUi update so the element tree sees the new position.
    if (_momentum_active && _scroll_target) {
        double now = CACurrentMediaTime();
        float  dt  = (float)(now - _last_frame_time);
        _last_frame_time = now;
        if (dt > 0.0f && dt < 0.1f) {
            float delta_px = _velocity_y * dt * (float)_dp_ratio;
            _scroll_target->SetScrollTop(_scroll_target->GetScrollTop() + delta_px);
            // iOS "normal" deceleration rate: 0.998 per millisecond.
            _velocity_y *= powf(0.998f, dt * 1000.0f);
            if (fabsf(_velocity_y) < 30.0f) {
                _velocity_y      = 0.0f;
                _momentum_active = NO;
            }
        }
    }

    // Show or hide the software keyboard based on which element has RmlUi focus.
    // NOTE: resignFirstResponder fires UIKeyboardWillHideNotification synchronously,
    // which calls keyboardWillHide: → Backend::SetViewport(fullscreen).  The viewport
    // re-sync below (from the actual texture) must come AFTER this poll to win.
    if (_key_input) {
        Rml::Element* focused = _context->GetFocusElement();
        BOOL want_keyboard = (focused != nullptr && focused->GetTagName() == "input");
        if (want_keyboard && !_key_input.isFirstResponder)
            [_key_input becomeFirstResponder];
        else if (!want_keyboard && _key_input.isFirstResponder)
            [_key_input resignFirstResponder];
    }

    // Sync the scissor-clamp viewport to the ACTUAL Metal texture for this pass.
    // This must be the LAST thing before BeginFrame — becomeFirstResponder and
    // resignFirstResponder above can fire UIKeyboardWillShow/HideNotification
    // synchronously, which calls keyboardWillShow/Hide: → Backend::SetViewport with
    // a stale (UIKit-logical) size.  Reading the colour-attachment texture gives the
    // exact dimensions Metal validates scissor rects against.
    {
        id<MTLTexture> colorTex = pass.colorAttachments[0].texture;
        if (colorTex)
            Backend::SetViewport((int)colorTex.width, (int)colorTex.height);
    }

    // Clear is configured via MTKView.clearColor; the pass already has load action = Clear.
    Backend::BeginFrame(cmd, pass);

    _context->Update();
    _context->Render();

    Backend::EndFrame();

    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

// ---- Touch input ---------------------------------------------------------------------

// Convert logical-point UIKit coordinate to physical pixels for RmlUi.
- (Rml::Vector2f)physFromPt:(CGPoint)p
{
    return { (float)(p.x * _dp_ratio), (float)(p.y * _dp_ratio) };
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (!_context || touches.count == 0) return;
    UITouch* touch = touches.anyObject;
    _touch_start     = [touch locationInView:_view];
    _touch_last      = _touch_start;
    _is_scrolling    = NO;
    _momentum_active = NO;   // finger down cancels any running momentum
    _velocity_y      = 0.0f;
    _last_move_time  = CACurrentMediaTime();
    // Guild sidebar is 72dp wide; 1dp ≈ 1 UIKit logical point, so x < 72pt → sidebar.
    _scroll_target = (_touch_start.x < 72.0) ? _guild_panel : _channel_panel;
    // Move cursor to touch position; defer button-down until we know it's a tap.
    Rml::Vector2f pt = [self physFromPt:_touch_start];
    _context->ProcessMouseMove((int)pt.x, (int)pt.y, 0);
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (!_context || touches.count == 0) return;
    UITouch* touch = touches.anyObject;
    CGPoint cur = [touch locationInView:_view];

    // Incremental delta in logical points (UIKit space).
    float dx_pt = (float)(cur.x - _touch_last.x);
    float dy_pt = (float)(cur.y - _touch_last.y);
    _touch_last = cur;

    // Enter scroll mode once finger travels > 10 logical points from start.
    if (!_is_scrolling) {
        float dist_x = (float)(cur.x - _touch_start.x);
        float dist_y = (float)(cur.y - _touch_start.y);
        if (dist_x * dist_x + dist_y * dist_y > 10.0f * 10.0f)
            _is_scrolling = YES;
    }

    Rml::Vector2f pt = [self physFromPt:cur];
    _context->ProcessMouseMove((int)pt.x, (int)pt.y, 0);

    if (_is_scrolling && _scroll_target) {
        // Scroll the column the touch started in.
        // Context is in physical pixels; multiply UIKit logical-point delta by dp_ratio.
        float scale = (float)_dp_ratio;
        _scroll_target->SetScrollTop(_scroll_target->GetScrollTop() - dy_pt * scale);

        // Track velocity for momentum: EMA of (delta / dt) in logical pts/sec.
        double now = CACurrentMediaTime();
        double dt  = now - _last_move_time;
        _last_move_time = now;
        if (dt > 0.0 && dt < 0.1) {
            float sample = -dy_pt / (float)dt;          // positive = scroll down
            _velocity_y = 0.6f * _velocity_y + 0.4f * sample;
            // Cap peak velocity so a hard flick doesn't scroll the entire document at once.
            static const float kMaxVelocity = 1500.0f;  // logical pts/sec
            if (_velocity_y >  kMaxVelocity) _velocity_y =  kMaxVelocity;
            if (_velocity_y < -kMaxVelocity) _velocity_y = -kMaxVelocity;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (!_context || touches.count == 0) return;
    UITouch* touch = touches.anyObject;
    CGPoint cur = [touch locationInView:_view];

    Rml::Vector2f pt = [self physFromPt:cur];
    _context->ProcessMouseMove((int)pt.x, (int)pt.y, 0);

    if (!_is_scrolling) {
        // Short tap — click at the original touch-down position for accurate hit testing.
        Rml::Vector2f spt = [self physFromPt:_touch_start];
        _context->ProcessMouseMove((int)spt.x, (int)spt.y, 0);
        _context->ProcessMouseButtonDown(0, 0);
        _context->ProcessMouseButtonUp(0, 0);
        _velocity_y = 0.0f;
    } else if (fabsf(_velocity_y) > 50.0f) {
        // Launch momentum — threshold filters out accidental low-speed lifts.
        _momentum_active = YES;
        _last_frame_time = CACurrentMediaTime();
    }
    _is_scrolling = NO;
    // Touch screen has no persistent cursor — clear hover state so no element stays highlighted.
    _context->ProcessMouseLeave();
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    // Discard the gesture without generating a click.
    _is_scrolling = NO;
    _context->ProcessMouseLeave();
}

@end
