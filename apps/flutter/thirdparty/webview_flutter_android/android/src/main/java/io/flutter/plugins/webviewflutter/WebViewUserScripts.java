package io.flutter.plugins.webviewflutter;

import android.webkit.WebView;
import androidx.webkit.ScriptHandler;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.WeakHashMap;

/** Owns native document-start script handles separately from WebView resource loading. */
final class WebViewUserScripts implements MethodChannel.MethodCallHandler {
  private final MethodChannel channel;
  private final ProxyApiRegistrar registrar;
  private final Map<WebView, Map<String, ScriptHandler>> scripts = new WeakHashMap<>();
  private long nextIdentifier = 0;

  /** Registers the per-engine user-script API on Flutter's platform thread. */
  WebViewUserScripts(BinaryMessenger messenger, ProxyApiRegistrar registrar) {
    this.registrar = registrar;
    channel = new MethodChannel(messenger, "operit/webview_user_scripts");
    channel.setMethodCallHandler(this);
  }

  /** Registers and removes scripts using the same AndroidX API as the Kotlin app. */
  @Override
  public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    if (!call.method.equals("add") && !call.method.equals("remove") && !call.method.equals("removeAll")) {
      result.notImplemented();
      return;
    }
    try {
      Number viewIdentifier = call.argument("viewIdentifier");
      if (viewIdentifier == null) throw new IllegalArgumentException("Missing viewIdentifier");
      WebView view = registrar.getInstanceManager().getInstance(viewIdentifier.longValue());
      if (view == null) throw new IllegalArgumentException("Unknown WebView");
      switch (call.method) {
        case "add": {
          if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            throw new UnsupportedOperationException("DOCUMENT_START_SCRIPT is not supported by this WebView provider");
          }
          String source = call.argument("source");
          if (source == null) throw new IllegalArgumentException("Missing source");
          ScriptHandler handler = WebViewCompat.addDocumentStartJavaScript(view, source, Collections.singleton("*"));
          String identifier = "operit-user-script-" + (++nextIdentifier);
          scripts.computeIfAbsent(view, ignored -> new HashMap<>()).put(identifier, handler);
          result.success(identifier);
          return;
        }
        case "remove": {
          String identifier = call.argument("identifier");
          Map<String, ScriptHandler> owned = scripts.get(view);
          if (owned == null || identifier == null) throw new IllegalArgumentException("Unknown script handle");
          ScriptHandler handler = owned.remove(identifier);
          if (handler == null) throw new IllegalArgumentException("Unknown script handle");
          handler.remove();
          if (owned.isEmpty()) scripts.remove(view);
          result.success(null);
          return;
        }
        case "removeAll": {
          Map<String, ScriptHandler> owned = scripts.remove(view);
          if (owned != null) owned.values().forEach(ScriptHandler::remove);
          result.success(null);
          return;
        }
      }
    } catch (RuntimeException error) {
      result.error("user_script_operation_failed", error.getMessage(), null);
    }
  }

  /** Removes all native handlers before detaching the Flutter engine. */
  void dispose() {
    channel.setMethodCallHandler(null);
    scripts.values().forEach(owned -> owned.values().forEach(ScriptHandler::remove));
    scripts.clear();
  }
}
