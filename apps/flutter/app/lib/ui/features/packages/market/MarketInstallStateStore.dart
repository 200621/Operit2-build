// ignore_for_file: file_names

import 'package:flutter/material.dart';

import '../../../../core/proxy/generated/CoreProxyClients.g.dart';
import '../../../../core/proxy/generated/CoreProxyModels.g.dart';
import '../../../main/navigation/ToolPkgCatalogChangeBus.dart';

enum MarketLocalInstallState { notInstalled, installed, updateAvailable }

/// One shared state per Core connection, not one optimistic flag per screen.
/// Markers live in Core so state survives app restarts and remote clients.
class MarketInstallStateStore extends ChangeNotifier {
  MarketInstallStateStore._(this.clients);

  static final Expando<MarketInstallStateStore> _stores =
      Expando<MarketInstallStateStore>();

  static MarketInstallStateStore of(GeneratedCoreProxyClients clients) =>
      _stores[clients.bridge] ??= MarketInstallStateStore._(clients);

  final GeneratedCoreProxyClients clients;
  Map<String, String> _installedVersions = <String, String>{};
  Map<String, PublishablePackageSource> _localPackages =
      <String, PublishablePackageSource>{};
  final Set<String> _busyEntries = <String>{};
  int _refreshGeneration = 0;

  bool isInstalling(String entryId) => _busyEntries.contains(entryId);

  MarketLocalInstallState stateFor(MarketEntrySummary entry) =>
      resolveMarketLocalInstallState(
        entry,
        installedVersionId: _installedVersions[entry.id],
        localPackage:
            _localPackages[entry.latestVersion?.runtimePackageId ??
                entry.artifact?.runtimePackageId],
      );

  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    try {
      final versions = await clients.application.getInstalledMarketVersions();
      final packages = await clients.application
          .packageManager()
          .getPublishablePackageSources();
      if (generation != _refreshGeneration) return;
      _installedVersions = versions;
      _localPackages = <String, PublishablePackageSource>{
        for (final package in packages) package.packageName: package,
      };
      notifyListeners();
    } catch (error, stackTrace) {
      // Do not turn a background status check into a mysterious bottom popup.
      debugPrint(
        'Failed to load market installation state: $error\n$stackTrace',
      );
    }
  }

  Future<void> install(MarketEntrySummary entry, {String? versionId}) async {
    if (!_busyEntries.add(entry.id)) return;
    notifyListeners();
    try {
      final installedVersion = await clients.application.installMarketEntry(
        entryId: entry.id,
        versionId: versionId,
      );
      // A refresh started before installation must not overwrite its new marker.
      _refreshGeneration += 1;
      _installedVersions[entry.id] = installedVersion;
      ToolPkgCatalogChangeBus.notifyCatalogChanged();
    } finally {
      _busyEntries.remove(entry.id);
      notifyListeners();
    }
  }
}

/// Match Kotlin's entryId/versionId markers. Legacy artifact installations without
/// markers are identified by their real runtime package, not by marketplace title.
MarketLocalInstallState resolveMarketLocalInstallState(
  MarketEntrySummary entry, {
  String? installedVersionId,
  PublishablePackageSource? localPackage,
}) {
  if (installedVersionId != null && installedVersionId.trim().isNotEmpty) {
    final latestId = entry.latestVersion?.id.trim() ?? '';
    return latestId.isEmpty || latestId == installedVersionId
        ? MarketLocalInstallState.installed
        : MarketLocalInstallState.updateAvailable;
  }
  if ((entry.type == 'script' || entry.type == 'package') &&
      localPackage != null) {
    final installedVersion = _normalizeVersion(localPackage.inferredVersion);
    final latestVersion = _normalizeVersion(entry.latestVersion?.version);
    return installedVersion.isNotEmpty &&
            latestVersion.isNotEmpty &&
            installedVersion != latestVersion
        ? MarketLocalInstallState.updateAvailable
        : MarketLocalInstallState.installed;
  }
  return MarketLocalInstallState.notInstalled;
}

String _normalizeVersion(String? value) =>
    (value ?? '').trim().replaceFirst(RegExp(r'^[vV]'), '');

extension MarketLocalInstallStatePresentation on MarketLocalInstallState {
  String actionLabel(MarketEntrySummary entry) => switch (this) {
    MarketLocalInstallState.installed => '已安装',
    MarketLocalInstallState.updateAvailable => '更新',
    MarketLocalInstallState.notInstalled =>
      entry.type == 'script' || entry.type == 'package' ? '下载' : '安装',
  };

  String? get badgeLabel => switch (this) {
    MarketLocalInstallState.installed => '已安装',
    MarketLocalInstallState.updateAvailable => '可更新',
    MarketLocalInstallState.notInstalled => null,
  };

  IconData get actionIcon => switch (this) {
    MarketLocalInstallState.installed => Icons.check,
    MarketLocalInstallState.updateAvailable => Icons.system_update_alt,
    MarketLocalInstallState.notInstalled => Icons.download_outlined,
  };
}
