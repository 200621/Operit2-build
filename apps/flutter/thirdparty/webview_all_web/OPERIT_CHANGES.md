# Operit integration

Based on webview_all_web 1.2.1, retaining its upstream license.

Page zoom uses a clipped HTML viewport containing an inversely sized iframe with
an origin-aligned CSS scale. The controller does not evaluate page JavaScript or
access the iframe document, so this works for cross-origin navigation and pages
with JavaScript disabled. The wrapper and iframe elements are retained across
zoom updates and navigation. Application zoom stays in Flutter/DOM composition
and is not applied again to the iframe's page-zoom factor.
