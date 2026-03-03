# RmlUi on iPhone

Runs [RmlUi](https://github.com/mikke89/RmlUi) (v6.3) on iPhone using a custom Metal renderer and iOS backend. No third-party UI framework — just RmlUi, Metal, and UIKit.

![Discord-style demo UI with scrollable guild sidebar and channel list](screenshot.png)

## What's in the box

| Path | Purpose |
|---|---|
| `Backends/RmlUi_Renderer_Metal.mm` | `RenderInterface` — Metal pipelines, geometry, scissor, stencil clip masks, gradients |
| `Backends/RmlUi_Platform_iOS.mm` | `SystemInterface` — timer, logging |
| `Backends/RmlUi_Backend_iOS_Metal.mm` | Glue namespace `Backend::` used by the view controller |
| `Shaders/RmlUi.metal` | Reference copy of the MSL shaders (embedded as source in the renderer) |
| `App/RmlViewController.mm` | `MTKView` delegate, touch input, scroll + momentum, keyboard handling |
| `App/Assets/demo.rml` | Discord-style demo document |

## Features implemented

- **Colored and textured geometry** — `RenderGeometry` with vertex buffer + two PSOs (color / texture)
- **Fonts** — FreeType via vcpkg, LatoLatin bundled
- **Scissor clipping** — `EnableScissorRegion` / `SetScissorRegion` with Metal validation–safe clamping
- **CSS transforms** — uniform `float4x4` passed per draw call
- **Stencil clip masks** — `EnableClipMask` / `RenderToClipMask` using `MTLPixelFormatDepth32Float_Stencil8`
- **Gradients** — `linear-gradient`, `radial-gradient`, `conic-gradient`, repeating variants via `RenderShader`
- **Touch input** — tap vs. scroll discrimination (10 pt threshold), per-column scroll routing
- **Scroll momentum** — EMA velocity tracking, `0.998/ms` friction, 1500 pt/s cap, 30 pt/s stop threshold
- **Text input** — `RmlKeyInput` UIView proxy with `UIKeyInput`; keyboard appears/disappears based on focused `<input>` element each frame
- **Keyboard avoidance** — view translates up (no resize, no viewport change) when focused input is in the lower half of the screen

## Requirements

- macOS with Xcode 15+
- iOS 15.0+ device or simulator (arm64)
- CMake 3.21+
- Git (for submodules)

## Build

### 1. Clone with submodules

```bash
git clone --recurse-submodules <repo-url>
cd rmlui-iphone
```

### 2. Bootstrap vcpkg (one-time)

```bash
./vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

vcpkg will install FreeType automatically when CMake runs (manifest mode via `vcpkg.json`).

### 3. Generate Xcode project

**Device:**
```bash
cmake -G Xcode -S . -B build \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
```

**Simulator:**
```bash
cmake -G Xcode -S . -B build \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DVCPKG_TARGET_TRIPLET=arm64-ios-simulator
```

### 4. Set signing team

Create `local.cmake` in the project root (it is gitignored):

```cmake
set(APPLE_DEVELOPMENT_TEAM "XXXXXXXXXX")  # your 10-character team ID
```

Or set the environment variable `APPLE_DEVELOPMENT_TEAM` before running CMake.

### 5. Open and run

```bash
open build/RmlUiIPhone.xcodeproj
```

Select your device, then **Product → Run** (⌘R).

## Architecture notes

### Coordinate system

The RmlUi context is created in **physical pixels** (`UIScreen.mainScreen.nativeBounds`). `SetDensityIndependentPixelRatio` lets RmlUi express `dp` units in the document. Touch coordinates from UIKit (logical points) are multiplied by `_dp_ratio` before being passed to `ProcessMouseMove`.

### Metal pipeline

- Two color PSOs: `rmlui_fragment_color` (untextured) and `rmlui_fragment_texture`
- One stencil PSO: color-write disabled, for clip mask writes
- One gradient PSO: `rmlui_fragment_gradient` with 352-byte uniform struct
- Premultiplied alpha blend: `src = One`, `dst = OneMinusSrcAlpha`
- Projection: orthographic, origin top-left, +Y down — matches RmlUi's coordinate system
- MSL shaders are embedded as a source string and compiled at startup via `newLibraryWithSource:`

### Scissor safety

`SetScissorRegion` clamps both origin and extent against the viewport. `Backend::SetViewport` is called from the actual render-pass colour-attachment texture dimensions (not `drawableSize`) immediately before `BeginFrame` each frame, so it always matches the Metal render target even during UIKit frame transitions (keyboard animation, rotation).

### Stencil clip masks

- `dss_normal` — depth/stencil test disabled (normal rendering)
- `dss_write` — write stencil ref, test always passes (set clip region)
- `dss_write_incr` — increment-clamp (intersect clip regions)
- `dss_test` — test equal to current ref (render inside clip)

The stencil reference increments per clip layer; no mid-pass clears are needed.
