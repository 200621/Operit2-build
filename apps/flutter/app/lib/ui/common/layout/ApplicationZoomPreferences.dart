// ignore_for_file: file_names

import '../../../core/bridge/ProxyCoreRuntimeBridge.dart';
import '../../../core/proxy/generated/CoreProxyClients.g.dart';
import 'ApplicationZoom.dart';

/// Stores the user-selected application zoom through the shared Core host API.
class ApplicationZoomPreferences {
  /// Creates the interface zoom preference store.
  const ApplicationZoomPreferences({
    GeneratedCoreProxyClients clients = const GeneratedCoreProxyClients(
      ProxyCoreRuntimeBridge(),
    ),
  }) : _clients = clients;

  static const String _fileName = 'application_zoom.preferences.json';
  static const String _zoomKey = 'zoom';

  final GeneratedCoreProxyClients _clients;

  /// Reads the saved zoom level or the initial setting for a new installation.
  Future<double> load() async {
    final values = await _clients.preferencesPreferenceStorageManager
        .getPreferences(fileName: _fileName, keys: <String>[_zoomKey]);
    return _decodeZoom(values);
  }

  /// Observes interface zoom changes committed locally or synchronized from peers.
  Stream<double> watch() {
    return _clients.preferencesPreferenceStorageManager
        .preferencesFlow(fileName: _fileName)
        .map(_decodeZoom)
        .distinct();
  }

  /// Decodes one zoom snapshot with the same validation used for startup reads.
  double _decodeZoom(Map<String, String> values) {
    final encoded = values[_zoomKey];
    if (encoded == null) {
      return 1.0;
    }
    final zoom = double.parse(encoded);
    if (!ApplicationZoom.levels.contains(zoom)) {
      throw FormatException('Invalid application zoom: $encoded');
    }
    return zoom;
  }

  /// Persists one of the supported interface zoom levels.
  Future<void> save(double zoom) {
    if (!ApplicationZoom.levels.contains(zoom)) {
      throw ArgumentError.value(zoom, 'zoom', 'Unknown zoom level');
    }
    return _clients.preferencesPreferenceStorageManager.setPreferences(
      fileName: _fileName,
      values: <String, String>{_zoomKey: zoom.toString()},
    );
  }
}
