# Operit integration

Based on webview_flutter_wkwebview 3.25.1, retaining its upstream license.

The common `operit/webview_theme` channel updates native WKWebView appearance.
The weak browser registry applies the preference to existing and newly created
views on iOS and macOS. It does not override application/window appearance, so
Flutter continues observing system theme changes independently.

`WebKitWebViewController.setZoomFactor` is backed by the native
`WKWebView.pageZoom` property through the `operit/webview_zoom` channel, which
keeps page zoom available before navigation on macOS (with the legacy
`magnification` fallback on macOS 10.15) and iOS 14+.

On macOS, scroll position and scrollbar visibility use WebKit page JavaScript
and user scripts because `WKWebView` has no iOS-style `UIScrollView` bridge.

The application mounts macOS `AppKitView` browser surfaces directly in their
final workspace location. It does not transfer them from the offscreen owner
host or animate their enclosing workspace panel, since either operation can
produce a transient blank frame in AppKit.

Application interface zoom is carried by `WebViewScaleScope` in the common
`webview_all` wrapper. On macOS, the wrapper counter-scales the native viewport
and lays it out at its displayed size. This avoids passing application paint
scaling through the embedder's CALayer transform, which does not give AppKit
mouse events the corresponding NSView coordinate conversion. The host DPR is
unchanged. The wrapper also forwards application zoom to the WebKit controller,
which uses the shared `NativeWebViewZoom` to apply
`pageZoom = applicationZoom * pageZoomFactor`. The browser's chosen
page zoom is retained separately, so neither application zoom changes nor browser
zoom changes overwrite the other. Native updates are serialized to prevent a
registration retry from applying an outdated factor. The wrapper retains the same widget structure at 1x and other zoom levels so zoom
changes do not recreate the native view. Other platforms keep their existing
rendering path. The shared wrapper selects this behavior through the
`requiresNativeApplicationZoom` backend capability; iOS keeps its working
UIKit composition scale and does not apply application zoom a second time.
