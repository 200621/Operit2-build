# Operit integration

Based on webview_all_ohos 1.4.0, retaining its upstream license.

The main ArkWeb view and popup view bind `darkMode` to `operitWebViewDark` in
AppStorage. The host theme channel updates that value from Flutter's resolved
brightness. Forced page recoloring is disabled; websites receive the browser's
native color preference. No page JavaScript is needed and navigation is retained.

`webview_platform_interface` is resolved through the shared local interface package.
OHOS Dart checks require the Flutter OHOS SDK, whose services library defines
OhosViewController and OhosViewSurface.

Application zoom stays in Flutter's OHOS platform-view composition, where input
coordinates follow the paint transform. Page zoom uses `operit/webview_zoom` and
page-wide CSS zoom on ArkWeb SDKs without an absolute native page-zoom API. The
main-frame document-start script is retained independently from user scripts,
so navigation and user-script removal do not reset page zoom. Website-provided
root CSS zoom is preserved and restored when page zoom returns to 1x. This path
uses ArkWeb script execution; the application's browser enables JavaScript.
