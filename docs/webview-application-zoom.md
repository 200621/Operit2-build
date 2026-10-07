# WebView application and page zoom

The Flutter application supports Android, iOS, macOS, Windows, Linux, OHOS and
Web. Application zoom and each browser's page zoom remain independent. Visually,
content is scaled by their product; returning application zoom to 1x must not
reset the browser's selected page zoom.

## Rendering strategy

`WebViewScaleScope` supplies application zoom without changing the host DPR.
`PlatformWebViewController.requiresNativeApplicationZoom` selects the strategy
by backend capability, not by a macOS-only branch in the shared widget.

| Backend | Application zoom | Page zoom | Input mapping |
| --- | --- | --- | --- |
| macOS / WKWebView | Unscaled native viewport + native content zoom | WKWebView pageZoom (legacy magnification fallback) | AppKit uses a translation-only native frame |
| Linux / WebKitGTK | Unscaled native viewport + native content zoom | WebKitGTK zoom level | GTK receives a translation-only frame; no unsupported scale hiding |
| iOS / WKWebView | Flutter/UIKit composition | WKWebView pageZoom | Existing UIKit platform-view mapping |
| Android / WebView | Flutter platform-view composition | Existing WebView zoom API | Existing platform-view input mapping |
| Windows / WebView2 | Flutter/native composition | WebView2 zoom factor | Pointer forwarding uses Flutter-local coordinates |
| OHOS / ArkWeb | Flutter/OHOS platform-view composition | Main-frame CSS zoom via a per-engine bridge | Existing platform-view input mapping |
| Web / iframe | Flutter/DOM composition | Clipped, inversely sized and scaled iframe | Browser DOM transforms map pointer input, including cross-origin frames |

Native-overlay backends cancel the application paint scale around the viewport,
lay out the viewport at its displayed size, and send
`applicationZoom * pageZoom` to the native page API. `NativeWebViewZoom` retains
both factors, validates input and serializes native updates. The same widget
structure is retained at every scale to avoid recreating the platform view.

Composited backends retain application paint scaling. Sending the application
factor to their page APIs as well would scale content twice, so their capability
flag stays false. The iframe page-zoom implementation does not inspect its
embedded document and works with cross-origin content and JavaScript disabled.

Older ArkWeb SDKs lack an absolute native browser-zoom API. The OHOS page-zoom
bridge therefore uses page-wide CSS zoom with the application's JavaScript-enabled
browser. It retains a main-frame document-start script separately from user
scripts, applies zoom to the current document, and restores preexisting inline
root zoom when reset. Application zoom itself does not require page JavaScript.

## Validation

Verified on the development host with the project's OHOS-capable Flutter SDK:
application/widget/channel regression tests, Chrome browser tests, common
wrapper tests, Linux and Windows adapter tests, shared zoom unit tests and Node
script/contract tests. Targeted Dart analysis reports no issues. Chrome widget
tests explicitly invoke the registered production DOM factory because the
Flutter widget-test engine mocks platform-view creation.


- Widget tests cover supported platform strategies, zoom 0.7–1.5, host DPR 1/2,
  local pointer coordinates and retaining platform-view state.
- AppKit and GTK channel tests assert the product sent to the backend and the
  native frame geometry; GTK must stay visible at non-1x application zoom.
- Chrome browser tests cover iframe page zoom and independent application zoom.
- Shared native-zoom tests cover custom initial zoom, invalid values, overflow,
  request ordering and recovery after a native error.
- OHOS script tests execute the generated JavaScript and check frame filtering,
  deferred document-root creation, absolute zoom and restoring existing CSS.

Channel and widget tests do not replace on-device interaction tests. Windows,
Android, iOS, Linux and OHOS native rendering/IME/gesture verification should be
run on their target devices, particularly after updating an engine or SDK.
