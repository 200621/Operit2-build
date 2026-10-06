// ignore_for_file: file_names

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/bridge/OperitRuntimeBridge.dart';
import '../../../core/bridge/ProxyCoreRuntimeBridge.dart';
import '../../../core/logging/ClientLogger.dart';
import '../../../core/proxy/generated/CoreProxyClients.g.dart';
import '../../../core/proxy/generated/CoreProxyModels.g.dart' as core_proxy;
import '../../../data/preferences/UserPreferencesManager.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../common/CharacterAvatar.dart';
import '../../features/chat/components/NewChatIntro.dart';
import '../../features/chat/viewmodel/ChatSelectionTransition.dart';
import '../navigation/AppNavigationModels.dart';
import '../layout/SidebarDockController.dart';
import '../layout/NavigationLayoutMetrics.dart';
import '../screens/ScreenRouteRegistry.dart';
import '../../theme/OperitTheme.dart';
import '../../window/DetachedChatWindowLauncher.dart';
import '../../window/OperitWindowPlatform.dart';
import 'CollapsedDrawerContent.dart';
import 'DrawerContentDialogs.dart';
import 'NavigationDrawerAppearance.dart';

class DrawerContent extends StatefulWidget {
  const DrawerContent({
    super.key,
    required this.navigationEntries,
    required this.pluginEntries,
    required this.selectedRouteId,
    required this.appearance,
    required this.histories,
    required this.activeStreamingChatIds,
    required this.characterGroupNamesById,
    required this.characterCardAvatarUrisByName,
    required this.currentChatId,
    required this.errorMessage,
    required this.loading,
    required this.onNavigationEntrySelected,
    required this.onConversationActivated,
    this.bridge = const ProxyCoreRuntimeBridge(),
  });

  final List<NavigationEntrySpec> navigationEntries;
  final List<NavigationEntrySpec> pluginEntries;
  final String selectedRouteId;
  final NavigationDrawerAppearance appearance;
  final List<core_proxy.ChatHistoryListItem> histories;
  final Set<String> activeStreamingChatIds;
  final Map<String, String> characterGroupNamesById;
  final Map<String, String> characterCardAvatarUrisByName;
  final String? currentChatId;
  final String? errorMessage;
  final bool loading;
  final ValueChanged<NavigationEntrySpec> onNavigationEntrySelected;
  final VoidCallback onConversationActivated;
  final OperitRuntimeBridge bridge;

  @override
  State<DrawerContent> createState() => _DrawerContentState();
}

class _DrawerContentState extends State<DrawerContent> {
  static const int _collapsedHistoryLimit = 4;
  static const double _contentEndPadding = 12;
  static final Set<String> _rememberedCollapsedCharacterSections = <String>{};
  static final Set<String> _rememberedCollapsedGroupSections = <String>{};

  final ScrollController _historyScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _collapsedCharacterSections = Set<String>.of(
    _rememberedCollapsedCharacterSections,
  );
  final Set<String> _collapsedGroupSections = Set<String>.of(
    _rememberedCollapsedGroupSections,
  );
  String? _errorMessage;
  List<core_proxy.ChatHistoryListItem>? _pendingOrderedHistories;
  int _historyRenderLimit = _collapsedHistoryLimit;
  bool _searchExpanded = false;
  StreamSubscription<String?>? _groupingModeSubscription;
  late final Future<void> _groupingModeLoadFuture;
  _HistoryGroupingMode _groupingMode = _HistoryGroupingMode.character;

  GeneratedChatRuntimeHolderMainCoreProxy get _chatCoreProxy =>
      GeneratedCoreProxyClients(widget.bridge).chatRuntimeHolderMain;

  UserPreferencesManager get _preferences =>
      UserPreferencesManager(clients: GeneratedCoreProxyClients(widget.bridge));

  List<core_proxy.ChatHistoryListItem> get _histories =>
      _pendingOrderedHistories ?? widget.histories;

  String? get _visibleErrorMessage => _errorMessage ?? widget.errorMessage;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _groupingModeLoadFuture = _loadGroupingMode();
    unawaited(_reportGroupingModeLoad());
  }

  /// Observes the persisted grouping mode and awaits its initial snapshot.
  Future<void> _loadGroupingMode() async {
    final loaded = Completer<void>();
    _groupingModeSubscription = _preferences
        .chatHistoryGroupingModeFlow()
        .listen(
          (mode) {
            _applyPersistedGroupingMode(mode);
            if (!loaded.isCompleted) {
              loaded.complete();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!loaded.isCompleted) {
              loaded.completeError(error, stackTrace);
              return;
            }
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stackTrace,
                library: 'sidebar grouping preferences',
                context: ErrorDescription(
                  'while observing conversation grouping',
                ),
              ),
            );
          },
        );
    await loaded.future;
  }

  /// Applies committed grouping changes to the drawer's live conversation state.
  void _applyPersistedGroupingMode(String? persistedMode) {
    if (!mounted) {
      return;
    }
    final groupingMode = switch (persistedMode) {
      null || UserPreferencesManager.CHAT_HISTORY_GROUPING_CHARACTER =>
        _HistoryGroupingMode.character,
      UserPreferencesManager.CHAT_HISTORY_GROUPING_WORKSPACE =>
        _HistoryGroupingMode.workspace,
      _ => throw FormatException(
        'Unsupported persisted sidebar grouping mode: $persistedMode',
      ),
    };
    if (_groupingMode == groupingMode) {
      return;
    }
    setState(() {
      _groupingMode = groupingMode;
    });
  }

  /// Reports a sidebar grouping preference load failure without losing its cause.
  Future<void> _reportGroupingModeLoad() async {
    try {
      await _groupingModeLoadFuture;
    } catch (error, stackTrace) {
      debugPrint('Failed to load sidebar grouping mode: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  @override
  void didUpdateWidget(covariant DrawerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousList = _pendingOrderedHistories ?? oldWidget.histories;
    if (previousList.isNotEmpty &&
        widget.histories.length == previousList.length + 1) {
      final previousIds = previousList.map((item) => item.id).toSet();
      core_proxy.ChatHistoryListItem? added;
      for (final item in widget.histories) {
        if (!previousIds.contains(item.id)) {
          added = item;
          break;
        }
      }
      if (added != null) {
        final addedSectionKey = _characterSectionKey(added);
        final addedGroupKey = _groupSectionKey(addedSectionKey, added);
        final anchorIndex = previousList.indexWhere((item) {
          final sectionKey = _characterSectionKey(item);
          return sectionKey == addedSectionKey &&
              _groupSectionKey(sectionKey, item) == addedGroupKey;
        });
        if (anchorIndex != -1) {
          final groupItems = previousList.where((item) {
            final sectionKey = _characterSectionKey(item);
            return sectionKey == addedSectionKey &&
                _groupSectionKey(sectionKey, item) == addedGroupKey;
          }).toList(growable: false);
          final groupPinned =
              groupItems.isNotEmpty && groupItems.every((item) => item.pinned);
          final latestById = <String, core_proxy.ChatHistoryListItem>{
            for (final item in widget.histories) item.id: item,
          };
          final reordered = <core_proxy.ChatHistoryListItem>[];
          for (var i = 0; i < previousList.length; i += 1) {
            if (i == anchorIndex) {
              reordered.add(added);
            }
            final latest = latestById[previousList[i].id];
            if (latest != null) {
              reordered.add(latest);
            }
          }
          unawaited(
            _preserveGroupPositionForNewChat(reordered, added, groupPinned),
          );
          return;
        }
      }
    }
    final pending = _pendingOrderedHistories;
    if (pending != null &&
        (pending.length != widget.histories.length ||
            _sameHistoryOrder(pending, widget.histories))) {
      _pendingOrderedHistories = null;
    }
    if (oldWidget.errorMessage != widget.errorMessage &&
        _errorMessage != null) {
      _errorMessage = null;
    }
  }

  Future<void> _preserveGroupPositionForNewChat(
    List<core_proxy.ChatHistoryListItem> reordered,
    core_proxy.ChatHistoryListItem added,
    bool groupPinned,
  ) async {
    final updatedHistories = <core_proxy.ChatHistoryListItem>[];
    for (var index = 0; index < reordered.length; index += 1) {
      final history = reordered[index];
      final isAdded = history.id == added.id;
      updatedHistories.add(
        core_proxy.ChatHistoryListItem(
          id: history.id,
          title: history.title,
          updatedAt: history.updatedAt,
          group: history.group,
          displayOrder: index,
          workspaceId: history.workspaceId,
          workspaceName: history.workspaceName,
          characterCardName: history.characterCardName,
          characterGroupId: history.characterGroupId,
          locked: history.locked,
          pinned: isAdded && groupPinned ? true : history.pinned,
        ),
      );
    }
    _pendingOrderedHistories = updatedHistories;
    final updatedAdded = updatedHistories.firstWhere(
      (item) => item.id == added.id,
    );
    try {
      await _chatCoreProxy.updateChatOrderAndGroup(
        reorderedHistories: updatedHistories,
        movedItem: updatedAdded,
        targetGroup: added.group,
      );
      if (groupPinned && !added.pinned) {
        await _chatCoreProxy.updateChatPinned(
          chatId: added.id,
          pinned: true,
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to preserve group order for new chat: $error\n$stackTrace');
    }
  }

  @override
  void dispose() {
    unawaited(_groupingModeSubscription?.cancel());
    _groupingModeSubscription = null;
    _historyScrollController.dispose();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  bool _sameHistoryOrder(
    List<core_proxy.ChatHistoryListItem> left,
    List<core_proxy.ChatHistoryListItem> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      final leftItem = left[index];
      final rightItem = right[index];
      if (leftItem.id != rightItem.id ||
          leftItem.group != rightItem.group ||
          leftItem.displayOrder != rightItem.displayOrder ||
          leftItem.pinned != rightItem.pinned) {
        return false;
      }
    }
    return true;
  }

  void _onSearchChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _openPackageManager() {
    for (final entry in widget.navigationEntries) {
      if (entry.entryId == 'main.package_manager') {
        widget.onNavigationEntrySelected(entry);
        return;
      }
    }
    throw StateError('Unknown navigation entry: main.package_manager');
  }

  void _openSettings() {
    for (final entry in widget.navigationEntries) {
      if (entry.entryId == 'main.settings') {
        widget.onNavigationEntrySelected(entry);
        return;
      }
    }
    throw StateError('Unknown navigation entry: main.settings');
  }

  void _toggleSearchExpanded() {
    setState(() {
      _searchExpanded = !_searchExpanded;
    });
  }

  /// Switches and persists the conversation list grouping mode.
  void _toggleGroupingMode() {
    final nextMode = _groupingMode == _HistoryGroupingMode.character
        ? _HistoryGroupingMode.workspace
        : _HistoryGroupingMode.character;
    setState(() {
      _groupingMode = nextMode;
    });
    unawaited(_persistGroupingMode(nextMode));
  }

  /// Persists a changed sidebar grouping mode and exposes storage errors.
  Future<void> _persistGroupingMode(_HistoryGroupingMode groupingMode) async {
    final mode = switch (groupingMode) {
      _HistoryGroupingMode.character =>
        UserPreferencesManager.CHAT_HISTORY_GROUPING_CHARACTER,
      _HistoryGroupingMode.workspace =>
        UserPreferencesManager.CHAT_HISTORY_GROUPING_WORKSPACE,
    };
    try {
      await _preferences.saveChatHistoryGroupingMode(mode);
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to persist sidebar grouping mode: $error\n$stackTrace',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  /// Creates a conversation using the active sidebar grouping mode.
  Future<void> _createConversation() async {
    setState(() {
      _errorMessage = null;
    });
    try {
      await _groupingModeLoadFuture;
      // Arm before creating so the intro overlay sees the flag when the new
      // chat id arrives; disarmed again if creation fails.
      newChatIntroArmed.value = true;
      await _chatCoreProxy.createNewChat(
        characterCardName: null,
        group: null,
        inheritGroupFromCurrent:
            _groupingMode == _HistoryGroupingMode.workspace,
        setAsCurrentChat: true,
        characterGroupId: null,
      );
      widget.onConversationActivated();
    } catch (error, stackTrace) {
      newChatIntroArmed.value = false;
      debugPrint('Failed to create chat: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _showCreateGroupDialog() async {
    final groupName = await showDialog<String>(
      context: context,
      builder: (context) {
        return const CreateGroupDialog();
      },
    );
    final normalizedGroupName = groupName?.trim();
    if (normalizedGroupName == null || normalizedGroupName.isEmpty) {
      return;
    }
    await _createGroup(normalizedGroupName);
  }

  Future<void> _createGroup(String groupName) async {
    setState(() {
      _errorMessage = null;
    });
    newChatIntroArmed.value = true;
    try {
      final binding = await _activePromptBindingForCreate();
      await GeneratedCoreProxyClients(
        widget.bridge,
      ).chatRuntimeHolderMain.createNewChat(
        characterCardName: binding.characterCardName,
        group: groupName,
        inheritGroupFromCurrent: false,
        setAsCurrentChat: true,
        characterGroupId: binding.characterGroupId,
      );
      widget.onConversationActivated();
    } catch (error, stackTrace) {
      newChatIntroArmed.value = false;
      debugPrint('Failed to create group: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<_ChatBindingForCreate> _activePromptBindingForCreate() async {
    final clients = GeneratedCoreProxyClients(widget.bridge);
    final prompt = await clients.preferencesActivePromptManager
        .getActivePrompt();
    if (prompt.tag == 'CharacterGroup' && prompt.id.trim().isNotEmpty) {
      return _ChatBindingForCreate(
        characterCardName: null,
        characterGroupId: prompt.id.trim(),
      );
    }
    if (prompt.tag == 'CharacterCard' && prompt.id.trim().isNotEmpty) {
      final id = prompt.id.trim();
      final clients = GeneratedCoreProxyClients(widget.bridge);
      final card = await clients.preferencesCharacterCardManager
          .getCharacterCard(id: id);
      return _ChatBindingForCreate(
        characterCardName: card.name,
        characterGroupId: null,
      );
    }
    throw StateError('Unknown active prompt: $prompt');
  }

  Future<void> _switchConversation(
    core_proxy.ChatHistoryListItem history,
  ) async {
    final switchStartedAt = Stopwatch()..start();
    setState(() {
      _errorMessage = null;
    });
    try {
      if (history.id != widget.currentChatId) {
        ChatSelectionTransition.begin(history.id);
      }
      widget.onConversationActivated();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return;
      }
      await _chatCoreProxy.switchChat(chatId: history.id);
      ClientLogger.i(
        'chat_switch.command_completed chatId=${history.id} elapsedMs=${switchStartedAt.elapsedMilliseconds}',
        tag: 'ChatSwitchTrace',
      );
    } catch (error, stackTrace) {
      ChatSelectionTransition.complete(history.id);
      debugPrint('Failed to switch chat: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _showRenameConversationDialog(
    core_proxy.ChatHistoryListItem history,
  ) async {
    final title = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) {
        return RenameConversationDialog(history: history);
      },
    );
    if (!mounted || title == null) {
      return;
    }
    await _updateConversationTitle(history, title);
  }

  Future<void> _showDeleteConversationDialog(
    core_proxy.ChatHistoryListItem history,
  ) async {
    if (history.locked) {
      await _deleteConversation(history);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) {
        return DeleteConversationDialog(history: history);
      },
    );
    if (!mounted || confirmed != true) {
      return;
    }
    await _deleteConversation(history);
  }

  Future<void> _createConversationInGroup(_HistoryGroupSection group) async {
    if (group.histories.isEmpty) {
      return;
    }
    final template = group.histories.first;
    final rawGroup = template.group?.trim();
    final targetGroup = (rawGroup == null || rawGroup.isEmpty) ? null : rawGroup;
    setState(() {
      _errorMessage = null;
      if (_collapsedGroupSections.remove(group.key)) {
        _rememberExpansionState();
      }
    });
    newChatIntroArmed.value = true;
    try {
      await _chatCoreProxy.createNewChat(
        characterCardName: template.characterCardName,
        group: targetGroup,
        inheritGroupFromCurrent: false,
        setAsCurrentChat: true,
        characterGroupId: template.characterGroupId,
      );
      widget.onConversationActivated();
    } catch (error, stackTrace) {
      newChatIntroArmed.value = false;
      debugPrint('Failed to create chat in group: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _showRenameGroupDialog(_HistoryGroupSection group) async {
    final newName = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) => RenameGroupDialog(initialName: group.label),
    );
    final normalized = newName?.trim();
    if (!mounted || normalized == null || normalized.isEmpty || normalized == group.label) {
      return;
    }
    await _renameGroup(group, normalized);
  }

  Future<void> _renameGroup(
    _HistoryGroupSection group,
    String newGroupName,
  ) async {
    if (group.histories.isEmpty) {
      return;
    }
    final groupIds = group.histories.map((item) => item.id).toSet();
    setState(() {
      _errorMessage = null;
      final first = group.histories.first;
      final sectionKey = _characterSectionKey(first);
      final newGroupKey = 'group::$sectionKey::$newGroupName';
      if (_collapsedGroupSections.remove(group.key)) {
        _collapsedGroupSections.add(newGroupKey);
        _rememberExpansionState();
      }
    });
    try {
      var currentList = List<core_proxy.ChatHistoryListItem>.of(_histories);
      for (final target in group.histories) {
        final updated = <core_proxy.ChatHistoryListItem>[];
        for (var i = 0; i < currentList.length; i += 1) {
          final item = currentList[i];
          updated.add(
            core_proxy.ChatHistoryListItem(
              id: item.id,
              title: item.title,
              updatedAt: item.updatedAt,
              group: groupIds.contains(item.id) ? newGroupName : item.group,
              displayOrder: i,
              workspaceId: item.workspaceId,
              workspaceName: item.workspaceName,
              characterCardName: item.characterCardName,
              characterGroupId: item.characterGroupId,
              locked: item.locked,
              pinned: item.pinned,
            ),
          );
        }
        currentList = updated;
        final moved = updated.firstWhere((item) => item.id == target.id);
        if (mounted) {
          setState(() {
            _pendingOrderedHistories = updated;
          });
        }
        await _chatCoreProxy.updateChatOrderAndGroup(
          reorderedHistories: updated,
          movedItem: moved,
          targetGroup: newGroupName,
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to rename group: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _toggleGroupPinned(_HistoryGroupSection group) async {
    if (group.histories.isEmpty) {
      return;
    }
    final nextPinned = !group.isPinned;
    final groupIds = group.histories.map((item) => item.id).toSet();
    final sectionKey = _characterSectionKey(group.histories.first);
    setState(() {
      _errorMessage = null;
    });
    try {
      if (nextPinned) {
        final reordered = <core_proxy.ChatHistoryListItem>[];
        var inserted = false;
        for (final item in _histories) {
          if (!inserted && _characterSectionKey(item) == sectionKey) {
            for (final groupItem in _histories) {
              if (groupIds.contains(groupItem.id)) {
                reordered.add(groupItem);
              }
            }
            inserted = true;
          }
          if (!groupIds.contains(item.id)) {
            reordered.add(item);
          }
        }
        final firstMoved = group.histories.first;
        await _updateConversationOrder(
          reordered,
          firstMoved,
          firstMoved.group,
          optimistic: true,
        );
      }
      for (final item in group.histories) {
        if (item.pinned != nextPinned) {
          await _chatCoreProxy.updateChatPinned(
            chatId: item.id,
            pinned: nextPinned,
          );
        }
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to update group pinned state: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _showDeleteGroupDialog(_HistoryGroupSection group) async {
    if (group.histories.isEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => DeleteGroupDialog(
        groupName: group.label,
        count: group.historyCount,
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }
    await _deleteGroup(group);
  }

  Future<void> _deleteGroup(_HistoryGroupSection group) async {
    setState(() {
      _errorMessage = null;
    });
    try {
      var hasLocked = false;
      for (final item in group.histories) {
        if (item.locked) {
          hasLocked = true;
          continue;
        }
        final deleted = await _chatCoreProxy.deleteChatHistory(chatId: item.id);
        if (!deleted) {
          hasLocked = true;
        }
      }
      if (hasLocked && mounted) {
        final l10n = AppLocalizations.of(context)!;
        setState(() {
          _errorMessage = l10n.chatLockedCannotDelete;
        });
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to delete group: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  /// Shows conversation actions enabled within the current character section.
  Future<void> _showConversationActionDialog(
    core_proxy.ChatHistoryListItem history,
  ) async {
    final canMoveUp = _canMoveConversationRelative(history, -1);
    final canMoveDown = _canMoveConversationRelative(history, 1);
    final action = await showDialog<ConversationAction>(
      context: context,
      useRootNavigator: true,
      builder: (context) {
        return ConversationActionDialog(
          history: history,
          canOpenInWindow: operitSupportsDesktopMultiWindow,
          canMoveUp: canMoveUp,
          canMoveDown: canMoveDown,
        );
      },
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case ConversationAction.openInWindow:
        await DetachedChatWindowLauncher.openChat(
          chatId: history.id,
          title: history.title,
          themePreferenceSnapshot: OperitTheme.of(
            context,
          ).themePreferenceSnapshot,
        );
      case ConversationAction.rename:
        await _showRenameConversationDialog(history);
      case ConversationAction.moveUp:
        await _moveConversationRelative(history, -1);
      case ConversationAction.moveDown:
        await _moveConversationRelative(history, 1);
      case ConversationAction.togglePinned:
        await _updateConversationPinned(history);
      case ConversationAction.toggleLocked:
        await _updateConversationLocked(history);
      case ConversationAction.delete:
        await _showDeleteConversationDialog(history);
    }
  }

  /// Deletes a conversation and reports a policy refusal in the drawer.
  Future<void> _deleteConversation(
    core_proxy.ChatHistoryListItem history,
  ) async {
    setState(() {
      _errorMessage = null;
    });
    try {
      final deleted = await _chatCoreProxy.deleteChatHistory(
        chatId: history.id,
      );
      if (deleted || !mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _errorMessage = l10n.chatLockedCannotDelete;
      });
    } catch (error, stackTrace) {
      debugPrint('Failed to delete chat history: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _updateConversationTitle(
    core_proxy.ChatHistoryListItem history,
    String title,
  ) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty || normalizedTitle == history.title) {
      return;
    }
    setState(() {
      _errorMessage = null;
    });
    try {
      await _chatCoreProxy.updateChatTitle(
        chatId: history.id,
        title: normalizedTitle,
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to update chat title: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _updateConversationPinned(
    core_proxy.ChatHistoryListItem history,
  ) async {
    setState(() {
      _errorMessage = null;
    });
    try {
      await _chatCoreProxy.updateChatPinned(
        chatId: history.id,
        pinned: !history.pinned,
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to update chat pinned state: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _updateConversationLocked(
    core_proxy.ChatHistoryListItem history,
  ) async {
    setState(() {
      _errorMessage = null;
    });
    try {
      await _chatCoreProxy.updateChatLocked(
        chatId: history.id,
        locked: !history.locked,
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to update chat locked state: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  /// Moves a conversation by one position within its character section.
  Future<void> _moveConversationRelative(
    core_proxy.ChatHistoryListItem history,
    int delta,
  ) async {
    final currentIndex = _histories.indexWhere((item) => item.id == history.id);
    final targetIndex = currentIndex + delta;
    if (!_canMoveConversationRelative(history, delta)) {
      return;
    }
    final reordered = List<core_proxy.ChatHistoryListItem>.of(_histories);
    final moved = reordered.removeAt(currentIndex);
    reordered.insert(targetIndex, moved);
    await _updateConversationOrder(
      reordered,
      moved,
      moved.group,
      optimistic: true,
    );
  }

  /// Moves a conversation to another position within its character section.
  Future<void> _moveConversationTo(
    core_proxy.ChatHistoryListItem moved,
    core_proxy.ChatHistoryListItem target,
  ) async {
    if (moved.id == target.id || !_isInSameCharacterSection(moved, target)) {
      return;
    }
    final reordered = List<core_proxy.ChatHistoryListItem>.of(_histories);
    final fromIndex = reordered.indexWhere((item) => item.id == moved.id);
    final toIndex = reordered.indexWhere((item) => item.id == target.id);
    if (fromIndex < 0 || toIndex < 0) {
      return;
    }
    final removed = reordered.removeAt(fromIndex);
    final insertIndex = toIndex > reordered.length ? reordered.length : toIndex;
    reordered.insert(insertIndex, removed);
    await _updateConversationOrder(
      reordered,
      removed,
      target.group,
      optimistic: true,
    );
  }

  /// Determines whether the conversation can move without leaving its character section.
  bool _canMoveConversationRelative(
    core_proxy.ChatHistoryListItem history,
    int delta,
  ) {
    final currentIndex = _histories.indexWhere((item) => item.id == history.id);
    final targetIndex = currentIndex + delta;
    return currentIndex >= 0 &&
        targetIndex >= 0 &&
        targetIndex < _histories.length &&
        _isInSameCharacterSection(history, _histories[targetIndex]);
  }

  /// Returns whether two conversations belong to the same character section.
  bool _isInSameCharacterSection(
    core_proxy.ChatHistoryListItem first,
    core_proxy.ChatHistoryListItem second,
  ) {
    return _characterSectionKey(first) == _characterSectionKey(second);
  }

  Future<void> _updateConversationOrder(
    List<core_proxy.ChatHistoryListItem> reordered,
    core_proxy.ChatHistoryListItem moved,
    String? targetGroup, {
    required bool optimistic,
  }) async {
    final updatedHistories = <core_proxy.ChatHistoryListItem>[];
    for (var index = 0; index < reordered.length; index += 1) {
      final history = reordered[index];
      updatedHistories.add(
        core_proxy.ChatHistoryListItem(
          id: history.id,
          title: history.title,
          updatedAt: history.updatedAt,
          group: history.id == moved.id ? targetGroup : history.group,
          displayOrder: index,
          workspaceId: history.workspaceId,
          workspaceName: history.workspaceName,
          characterCardName: history.characterCardName,
          characterGroupId: history.characterGroupId,
          locked: history.locked,
          pinned: history.pinned,
        ),
      );
    }
    final updatedMoved = updatedHistories.firstWhere(
      (history) => history.id == moved.id,
    );
    if (optimistic) {
      setState(() {
        _pendingOrderedHistories = updatedHistories;
      });
    }
    try {
      await _chatCoreProxy.updateChatOrderAndGroup(
        reorderedHistories: updatedHistories,
        movedItem: updatedMoved,
        targetGroup: targetGroup,
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to update chat order: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  List<core_proxy.ChatHistoryListItem> get _visibleHistories {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return List<core_proxy.ChatHistoryListItem>.unmodifiable(_histories);
    }
    return _histories
        .where((history) => _historyMatchesQuery(history, query))
        .toList(growable: false);
  }

  bool _historyMatchesQuery(
    core_proxy.ChatHistoryListItem history,
    String query,
  ) {
    return history.title.toLowerCase().contains(query) ||
        _bindingLabel(history).toLowerCase().contains(query) ||
        _groupLabel(history).toLowerCase().contains(query);
  }

  List<_CharacterHistorySection> _buildCharacterSections(
    List<core_proxy.ChatHistoryListItem> histories,
  ) {
    final sections = <_CharacterHistorySection>[];
    final sectionIndexes = <String, int>{};
    for (final history in histories) {
      final sectionKey = _characterSectionKey(history);
      final sectionIndex = sectionIndexes[sectionKey];
      final groupKey = _groupSectionKey(sectionKey, history);
      final groupLabel = _groupLabel(history);
      if (sectionIndex == null) {
        sectionIndexes[sectionKey] = sections.length;
        sections.add(
          _CharacterHistorySection(
            key: sectionKey,
            label: _bindingLabel(history),
            kind: _bindingKind(history),
            avatarUri: _characterAvatarUri(history),
            groups: <_HistoryGroupSection>[
              _HistoryGroupSection(
                key: groupKey,
                label: groupLabel,
                histories: <core_proxy.ChatHistoryListItem>[history],
              ),
            ],
          ),
        );
        continue;
      }

      final section = sections[sectionIndex];
      final groupIndex = section.groups.indexWhere(
        (group) => group.key == groupKey,
      );
      if (groupIndex == -1) {
        section.groups.add(
          _HistoryGroupSection(
            key: groupKey,
            label: groupLabel,
            histories: <core_proxy.ChatHistoryListItem>[history],
          ),
        );
      } else {
        section.groups[groupIndex].histories.add(history);
      }
    }
    return sections;
  }

  _VisibleHistoryPlan _buildVisibleHistoryPlan(
    List<_CharacterHistorySection> sections,
    int renderLimit,
  ) {
    var remaining = renderLimit;
    var hiddenCount = 0;
    final plannedSections = <_CharacterHistorySection>[];

    for (final section in sections) {
      if (_collapsedCharacterSections.contains(section.key)) {
        plannedSections.add(section);
        continue;
      }

      final plannedGroups = <_HistoryGroupSection>[];
      for (final group in section.groups) {
        if (_collapsedGroupSections.contains(group.key)) {
          plannedGroups.add(group);
          continue;
        }

        final visibleCount = math.min(remaining, group.histories.length);
        final visibleHistories = group.histories
            .take(visibleCount)
            .toList(growable: false);
        hiddenCount += group.histories.length - visibleCount;
        remaining -= visibleCount;
        plannedGroups.add(
          _HistoryGroupSection(
            key: group.key,
            label: group.label,
            histories: visibleHistories,
            historyCount: group.historyCount,
          ),
        );
      }

      plannedSections.add(
        _CharacterHistorySection(
          key: section.key,
          label: section.label,
          kind: section.kind,
          avatarUri: section.avatarUri,
          groups: plannedGroups,
        ),
      );
    }

    return _VisibleHistoryPlan(
      sections: plannedSections,
      hiddenCount: hiddenCount,
    );
  }

  /// Builds the key used to place a conversation in a top-level section.
  String _characterSectionKey(core_proxy.ChatHistoryListItem history) {
    if (_groupingMode == _HistoryGroupingMode.workspace) {
      final workspaceId = history.workspaceId?.trim();
      return workspaceId == null || workspaceId.isEmpty
          ? 'workspace:unbound'
          : 'workspace:$workspaceId';
    }
    final characterGroupId = history.characterGroupId?.trim();
    if (characterGroupId != null && characterGroupId.isNotEmpty) {
      return 'character-group:$characterGroupId';
    }
    final name = history.characterCardName?.trim();
    return name == null || name.isEmpty
        ? 'character:unbound'
        : 'character:$name';
  }

  /// Resolves the visual section kind for the active history grouping.
  _HistoryBindingKind _bindingKind(core_proxy.ChatHistoryListItem history) {
    if (_groupingMode == _HistoryGroupingMode.workspace) {
      return _HistoryBindingKind.workspace;
    }
    final characterGroupId = history.characterGroupId?.trim();
    if (characterGroupId != null && characterGroupId.isNotEmpty) {
      return _HistoryBindingKind.characterGroup;
    }
    final name = history.characterCardName?.trim();
    return name == null || name.isEmpty
        ? _HistoryBindingKind.unbound
        : _HistoryBindingKind.characterCard;
  }

  String _bindingLabel(core_proxy.ChatHistoryListItem history) {
    if (_groupingMode == _HistoryGroupingMode.workspace) {
      final workspaceName = history.workspaceName?.trim();
      return workspaceName == null || workspaceName.isEmpty
          ? '未绑定工作区'
          : workspaceName;
    }
    final characterGroupId = history.characterGroupId?.trim();
    if (characterGroupId != null && characterGroupId.isNotEmpty) {
      return widget.characterGroupNamesById[characterGroupId] ??
          _shortIdentifier(characterGroupId);
    }
    final name = history.characterCardName?.trim();
    return name == null || name.isEmpty ? '未绑定' : name;
  }

  /// Resolves the runtime avatar path for a character-card history section.
  String? _characterAvatarUri(core_proxy.ChatHistoryListItem history) {
    if (_bindingKind(history) != _HistoryBindingKind.characterCard) {
      return null;
    }
    final name = history.characterCardName!.trim();
    return widget.characterCardAvatarUrisByName[name];
  }

  String _groupSectionKey(
    String sectionKey,
    core_proxy.ChatHistoryListItem history,
  ) {
    final group = history.group?.trim();
    final groupPart = group == null || group.isEmpty ? 'ungrouped' : group;
    return 'group::$sectionKey::$groupPart';
  }

  String _groupLabel(core_proxy.ChatHistoryListItem history) {
    final group = history.group?.trim();
    return group == null || group.isEmpty ? '未分组' : group;
  }

  void _toggleCharacterSection(String sectionKey) {
    setState(() {
      if (_collapsedCharacterSections.contains(sectionKey)) {
        _collapsedCharacterSections.remove(sectionKey);
      } else {
        _collapsedCharacterSections.add(sectionKey);
      }
      _rememberExpansionState();
    });
  }

  void _toggleGroupSection(String sectionKey) {
    setState(() {
      if (_collapsedGroupSections.contains(sectionKey)) {
        _collapsedGroupSections.remove(sectionKey);
      } else {
        _collapsedGroupSections.add(sectionKey);
      }
      _rememberExpansionState();
    });
  }

  void _showMoreHistories(int hiddenCount) {
    setState(() {
      _historyRenderLimit += hiddenCount;
    });
  }

  void _rememberExpansionState() {
    _rememberedCollapsedCharacterSections
      ..clear()
      ..addAll(_collapsedCharacterSections);
    _rememberedCollapsedGroupSections
      ..clear()
      ..addAll(_collapsedGroupSections);
  }

  List<_HistoryListEntry> _buildHistoryEntries(
    List<_CharacterHistorySection> sections,
  ) {
    final entries = <_HistoryListEntry>[];
    for (final section in sections) {
      entries.add(_CharacterHeaderEntry(section));
      if (_collapsedCharacterSections.contains(section.key)) {
        continue;
      }
      for (final group in section.groups) {
        entries.add(_GroupHeaderEntry(group));
        if (_collapsedGroupSections.contains(group.key)) {
          continue;
        }
        for (final history in group.histories) {
          entries.add(_HistoryRowEntry(history));
        }
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final visibleHistories = _visibleHistories;
    final errorMessage = _visibleErrorMessage;
    final showInitialLoading =
        widget.loading && _histories.isEmpty && errorMessage == null;
    final searching = _searchController.text.trim().isNotEmpty;
    final allCharacterSections = _buildCharacterSections(visibleHistories);
    final historyPlan = searching
        ? _VisibleHistoryPlan(sections: allCharacterSections, hiddenCount: 0)
        : _buildVisibleHistoryPlan(allCharacterSections, _historyRenderLimit);
    final characterSections = historyPlan.sections;
    final hiddenHistoryCount = historyPlan.hiddenCount;
    final historyEntries = _buildHistoryEntries(characterSections);
    final aiChatRouteId = ScreenRouteRegistry.routeIdOf(
      ScreenRouteRegistry.aiChat,
    );
    final packageManagerRouteId = ScreenRouteRegistry.routeIdOf(
      ScreenRouteRegistry.packageManager,
    );
    final settingsRouteId = ScreenRouteRegistry.routeIdOf(
      ScreenRouteRegistry.settings,
    );
    final conversationSelectionEnabled =
        widget.selectedRouteId == aiChatRouteId;
    final themeController = OperitTheme.of(context);
    final darkThemeActive = themeController.isDark(context);
    return Column(
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              CustomScrollView(
                key: const PageStorageKey<String>('drawer-history-scroll'),
                controller: _historyScrollController,
                primary: false,
                slivers: <Widget>[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      0,
                      26,
                      _contentEndPadding,
                      0,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: SidebarInfoCard(
                        brandName: 'Operit',
                        appearance: widget.appearance,
                        trailing: _SegmentedModeSwitch(
                          groupingMode: _groupingMode,
                          onToggle: _toggleGroupingMode,
                        ),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 14,
                        end: _contentEndPadding,
                        bottom: 8,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: _UnifiedCreateBar(
                              onCreateConversation: _createConversation,
                              onCreateGroup: _showCreateGroupDialog,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _ToolbarIconButton(
                            icon: _searchExpanded
                                ? Icons.search_off_rounded
                                : Icons.search_rounded,
                            tooltip: _searchExpanded ? '收起搜索' : '搜索对话',
                            appearance: widget.appearance,
                            active: _searchExpanded ||
                                _searchController.text.trim().isNotEmpty,
                            onClick: _toggleSearchExpanded,
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: _searchExpanded
                          ? Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: 12,
                                end: _contentEndPadding,
                                bottom: 12,
                              ),
                              child: ConversationSearchField(
                                controller: _searchController,
                                appearance: widget.appearance,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  if (errorMessage != null)
                    SliverToBoxAdapter(
                      child: SidebarStatusText(
                        text: errorMessage,
                        appearance: widget.appearance,
                      ),
                    ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final entry = historyEntries[index];
                      return switch (entry) {
                        _CharacterHeaderEntry(:final section) =>
                          _CharacterSectionHeader(
                            label: section.label,
                            kind: section.kind,
                            avatarUri: section.avatarUri,
                            count: section.historyCount,
                            expanded: !_collapsedCharacterSections.contains(
                              section.key,
                            ),
                            appearance: widget.appearance,
                            onToggleExpanded: () =>
                                _toggleCharacterSection(section.key),
                          ),
                        _GroupHeaderEntry(:final group) => _GroupSectionHeader(
                          label: group.label,
                          pinned: group.isPinned,
                          workspaceStyle:
                              _groupingMode == _HistoryGroupingMode.workspace,
                          expanded: !_collapsedGroupSections.contains(
                            group.key,
                          ),
                          appearance: widget.appearance,
                          onToggleExpanded: () =>
                              _toggleGroupSection(group.key),
                          onCreateChat: () => _createConversationInGroup(group),
                          onRename: () => _showRenameGroupDialog(group),
                          onTogglePinned: () => _toggleGroupPinned(group),
                          onDelete: () => _showDeleteGroupDialog(group),
                          canAcceptDrop: (moved) =>
                              group.histories.isNotEmpty &&
                              _isInSameCharacterSection(
                                moved,
                                group.histories.first,
                              ),
                          onMoveToGroup: (moved) {
                            if (group.histories.isNotEmpty) {
                              _moveConversationTo(
                                moved,
                                group.histories.first,
                              );
                            }
                          },
                        ),
                        _HistoryRowEntry(:final history) =>
                          ConversationDrawerItem(
                            history: history,
                            title: history.title,
                            selected:
                                conversationSelectionEnabled &&
                                widget.currentChatId == history.id,
                            isRunning: widget.activeStreamingChatIds.contains(
                              history.id,
                            ),
                            appearance: widget.appearance,
                            nested: true,
                            workspaceStyle:
                                _groupingMode == _HistoryGroupingMode.workspace,
                            onClick: () => _switchConversation(history),
                            onRename: () {
                              _showRenameConversationDialog(history);
                            },
                            onTogglePinned: () {
                              _updateConversationPinned(history);
                            },
                            onToggleLocked: () {
                              _updateConversationLocked(history);
                            },
                            onDelete: () {
                              _showDeleteConversationDialog(history);
                            },
                            onLongPress: () {
                              _showConversationActionDialog(history);
                            },
                            canDetach: operitSupportsDesktopMultiWindow,
                            onDetach: () {
                              DetachedChatWindowLauncher.openChat(
                                chatId: history.id,
                                title: history.title,
                                themePreferenceSnapshot: OperitTheme.of(
                                  context,
                                ).themePreferenceSnapshot,
                              ).catchError((
                                Object error,
                                StackTrace stackTrace,
                              ) {
                                debugPrint(
                                  'Failed to open detached chat window: $error\n$stackTrace',
                                );
                                return null;
                              });
                            },
                            onMoveTo: (moved) =>
                                _moveConversationTo(moved, history),
                            canAcceptDrop: (moved) =>
                                _isInSameCharacterSection(moved, history),
                          ),
                      };
                    }, childCount: historyEntries.length),
                  ),
                  if (!searching && hiddenHistoryCount > 0)
                    SliverToBoxAdapter(
                      child: _HistoryLimitButton(
                        icon: Icons.expand_more,
                        label: '展开更多 $hiddenHistoryCount',
                        appearance: widget.appearance,
                        onClick: () => _showMoreHistories(hiddenHistoryCount),
                      ),
                    ),
                  if (widget.pluginEntries.isNotEmpty) ...<Widget>[
                    const SliverToBoxAdapter(child: SizedBox(height: 10)),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: 28,
                          end: _contentEndPadding,
                          bottom: 2,
                        ),
                        child: Text(
                          '插件',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: widget.appearance.titleColor.withValues(
                                  alpha: 0.82,
                                ),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 6)),
                    SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final entry = widget.pluginEntries[index];
                        return PluginNavigationDrawerItem(
                          entry: entry,
                          selected: widget.selectedRouteId == entry.routeId,
                          appearance: widget.appearance,
                          onClick: () =>
                              widget.onNavigationEntrySelected(entry),
                        );
                      }, childCount: widget.pluginEntries.length),
                    ),
                    SliverToBoxAdapter(
                      child: SidebarDockEndDropTarget(
                        controller:
                            MediaQuery.sizeOf(context).width >=
                                navigationTabletBreakpoint
                            ? SidebarDockScope.maybeOf(context)
                            : null,
                        location: SidebarDockLocation.primary,
                        height: 18,
                      ),
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],
              ),
              if (showInitialLoading)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: CircularProgressIndicator(
                        color: widget.appearance.statusAvailableColor,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
          child: Row(
            children: <Widget>[
              Expanded(
                child: BottomSidebarAction(
                  icon: Icons.inventory_2_outlined,
                  label: '包管理',
                  appearance: widget.appearance,
                  selected: widget.selectedRouteId == packageManagerRouteId,
                  onClick: _openPackageManager,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: BottomSidebarAction(
                  icon: Icons.settings_outlined,
                  label: '设置',
                  appearance: widget.appearance,
                  selected: widget.selectedRouteId == settingsRouteId,
                  onClick: _openSettings,
                ),
              ),
              const SizedBox(width: 8),
              Builder(
                builder: (buttonContext) {
                  return _BottomThemeToggleButton(
                    appearance: widget.appearance,
                    darkThemeActive: darkThemeActive,
                    onToggle: () => themeController.toggle(buttonContext),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CharacterHistorySection {
  _CharacterHistorySection({
    required this.key,
    required this.label,
    required this.kind,
    required this.avatarUri,
    required this.groups,
  });

  final String key;
  final String label;
  final _HistoryBindingKind kind;
  final String? avatarUri;
  final List<_HistoryGroupSection> groups;

  int get historyCount {
    var count = 0;
    for (final group in groups) {
      count += group.historyCount;
    }
    return count;
  }
}

enum _HistoryGroupingMode { character, workspace }

enum _HistoryBindingKind { workspace, characterCard, characterGroup, unbound }

class _HistoryGroupSection {
  _HistoryGroupSection({
    required this.key,
    required this.label,
    required this.histories,
    int? historyCount,
  }) : _historyCount = historyCount;

  final String key;
  final String label;
  final List<core_proxy.ChatHistoryListItem> histories;
  final int? _historyCount;

  int get historyCount => _historyCount ?? histories.length;

  bool get isPinned =>
      histories.isNotEmpty && histories.every((item) => item.pinned);
}

class _VisibleHistoryPlan {
  const _VisibleHistoryPlan({
    required this.sections,
    required this.hiddenCount,
  });

  final List<_CharacterHistorySection> sections;
  final int hiddenCount;
}

sealed class _HistoryListEntry {
  const _HistoryListEntry();
}

class _CharacterHeaderEntry extends _HistoryListEntry {
  const _CharacterHeaderEntry(this.section);

  final _CharacterHistorySection section;
}

class _GroupHeaderEntry extends _HistoryListEntry {
  const _GroupHeaderEntry(this.group);

  final _HistoryGroupSection group;
}

class _HistoryRowEntry extends _HistoryListEntry {
  const _HistoryRowEntry(this.history);

  final core_proxy.ChatHistoryListItem history;
}

class _ChatBindingForCreate {
  const _ChatBindingForCreate({
    required this.characterCardName,
    required this.characterGroupId,
  });

  final String? characterCardName;
  final String? characterGroupId;
}

String _shortIdentifier(String value) {
  final text = value.trim();
  if (text.length <= 12) {
    return text;
  }
  return '${text.substring(0, 8)}...${text.substring(text.length - 4)}';
}

class _CharacterSectionHeader extends StatelessWidget {
  const _CharacterSectionHeader({
    required this.label,
    required this.kind,
    required this.avatarUri,
    required this.count,
    required this.expanded,
    required this.appearance,
    required this.onToggleExpanded,
  });

  final String label;
  final _HistoryBindingKind kind;
  final String? avatarUri;
  final int count;
  final bool expanded;
  final NavigationDrawerAppearance appearance;
  final VoidCallback onToggleExpanded;

  /// Builds the top-level history section header.
  @override
  Widget build(BuildContext context) {
    final workspaceStyle = kind == _HistoryBindingKind.workspace;
    if (workspaceStyle) {
      return Padding(
        padding: const EdgeInsetsDirectional.only(
          start: 18,
          end: 12,
          top: 8,
          bottom: 4,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onToggleExpanded,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(2, 3, 4, 3),
            child: Row(
              children: <Widget>[
                Container(
                  width: 3,
                  height: 17,
                  decoration: BoxDecoration(
                    color: appearance.statusAvailableColor.withValues(
                      alpha: 0.62,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 9),
                Icon(
                  Icons.work_outline,
                  size: 15,
                  color: appearance.itemColor.withValues(alpha: 0.82),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: appearance.titleColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _HistoryCountBadge(count: count, appearance: appearance),
                const SizedBox(width: 6),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: appearance.itemColor.withValues(alpha: 0.70),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final avatarContainerColor = appearance.buttonContainerColor;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: 20,
        end: 12,
        top: 10,
        bottom: 5,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onToggleExpanded,
        child: Row(
          children: <Widget>[
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: avatarContainerColor,
              ),
              alignment: Alignment.center,
              child: kind == _HistoryBindingKind.characterCard
                  ? ClipOval(
                      child: CharacterAvatarImage(
                        avatarUri: avatarUri,
                        fit: BoxFit.cover,
                      ),
                    )
                  : Icon(
                      switch (kind) {
                        _HistoryBindingKind.workspace =>
                          Icons.workspaces_outline,
                        _HistoryBindingKind.characterGroup =>
                          Icons.groups_outlined,
                        _HistoryBindingKind.unbound =>
                          Icons.account_tree_outlined,
                        _HistoryBindingKind.characterCard =>
                          Icons.person_outline,
                      },
                      size: 14,
                      color: appearance.itemColor,
                    ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: appearance.titleColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              count.toString(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: appearance.itemColor.withValues(alpha: 0.64),
                fontWeight: FontWeight.w700,
              ),
            ),
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsetsDirectional.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[
                      appearance.dividerColor,
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 23,
              color: appearance.itemColor.withValues(alpha: 0.78),
            ),
          ],
        ),
      ),
    );
  }
}

enum _GroupQuickAction { createChat, rename, togglePinned, delete }

class _GroupSectionHeader extends StatefulWidget {
  /// Creates a collapsible group header for history entries.
  const _GroupSectionHeader({
    required this.label,
    required this.pinned,
    required this.workspaceStyle,
    required this.expanded,
    required this.appearance,
    required this.onToggleExpanded,
    required this.onCreateChat,
    required this.onRename,
    required this.onTogglePinned,
    required this.onDelete,
    required this.canAcceptDrop,
    required this.onMoveToGroup,
  });

  final String label;
  final bool pinned;
  final bool workspaceStyle;
  final bool expanded;
  final NavigationDrawerAppearance appearance;
  final VoidCallback onToggleExpanded;
  final VoidCallback onCreateChat;
  final VoidCallback onRename;
  final VoidCallback onTogglePinned;
  final VoidCallback onDelete;
  final bool Function(core_proxy.ChatHistoryListItem) canAcceptDrop;
  final ValueChanged<core_proxy.ChatHistoryListItem> onMoveToGroup;

  @override
  State<_GroupSectionHeader> createState() => _GroupSectionHeaderState();
}

class _GroupSectionHeaderState extends State<_GroupSectionHeader> {
  static const double _endPadding = 12;

  bool _hovered = false;
  bool _menuOpen = false;

  /// Builds a history group header in the current drawer style.
  @override
  Widget build(BuildContext context) {
    final appearance = widget.appearance;
    final workspaceStyle = widget.workspaceStyle;
    final expanded = widget.expanded;
    final platform = Theme.of(context).platform;
    final touchPlatform =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    final showActions = _hovered || _menuOpen || touchPlatform;

    return DragTarget<core_proxy.ChatHistoryListItem>(
      onWillAcceptWithDetails: (details) => widget.canAcceptDrop(details.data),
      onAcceptWithDetails: (details) => widget.onMoveToGroup(details.data),
      builder: (context, candidateData, rejectedData) {
        final dragHovering = candidateData.isNotEmpty;
        final border = dragHovering
            ? Border.all(
                color: appearance.statusAvailableColor.withValues(alpha: 0.55),
              )
            : null;

        if (workspaceStyle) {
          return MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: 44,
                end: _endPadding,
                top: 2,
                bottom: expanded ? 2 : 0,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: border,
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: widget.onToggleExpanded,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 6, 4),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.folder_outlined,
                            size: 14,
                            color: appearance.itemColor.withValues(alpha: 0.76),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: appearance.titleColor.withValues(
                                      alpha: 0.86,
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                          if (widget.pinned) ...<Widget>[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.push_pin_rounded,
                              size: 12,
                              color: appearance.itemColor.withValues(
                                alpha: 0.65,
                              ),
                            ),
                          ],
                          const SizedBox(width: 2),
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 140),
                            opacity: showActions ? 1.0 : 0.0,
                            child: IgnorePointer(
                              ignoring: !showActions,
                              child: _GroupMoreMenuButton(
                                pinned: widget.pinned,
                                appearance: appearance,
                                compact: true,
                                onCreateChat: widget.onCreateChat,
                              onRename: widget.onRename,
                                onTogglePinned: widget.onTogglePinned,
                                onDelete: widget.onDelete,
                                onMenuOpenChanged: (open) {
                                  if (mounted) {
                                    setState(() => _menuOpen = open);
                                  }
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            expanded ? Icons.expand_less : Icons.expand_more,
                            size: 17,
                            color: appearance.itemColor.withValues(alpha: 0.62),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: 46,
              end: _endPadding,
              top: 4,
              bottom: expanded ? 2 : 0,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: border,
              ),
              child: Material(
                color: appearance.buttonContainerColor,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: widget.onToggleExpanded,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 6),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.folder_outlined,
                          size: 16,
                          color: appearance.itemColor,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: appearance.titleColor,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                        if (widget.pinned) ...<Widget>[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.push_pin_rounded,
                            size: 12,
                            color: appearance.itemColor.withValues(alpha: 0.68),
                          ),
                        ],
                        const SizedBox(width: 2),
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 140),
                          opacity: showActions ? 1.0 : 0.0,
                          child: IgnorePointer(
                            ignoring: !showActions,
                            child: _GroupMoreMenuButton(
                              pinned: widget.pinned,
                              appearance: appearance,
                              onCreateChat: widget.onCreateChat,
                              onRename: widget.onRename,
                              onTogglePinned: widget.onTogglePinned,
                              onDelete: widget.onDelete,
                              onMenuOpenChanged: (open) {
                                if (mounted) {
                                  setState(() => _menuOpen = open);
                                }
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 20,
                          color: appearance.itemColor.withValues(alpha: 0.68),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GroupMoreMenuButton extends StatelessWidget {
  const _GroupMoreMenuButton({
    required this.pinned,
    required this.appearance,
    required this.onCreateChat,
    required this.onRename,
    required this.onTogglePinned,
    required this.onDelete,
    this.onMenuOpenChanged,
    this.compact = false,
  });

  final bool pinned;
  final NavigationDrawerAppearance appearance;
  final VoidCallback onCreateChat;
  final VoidCallback onRename;
  final VoidCallback onTogglePinned;
  final VoidCallback onDelete;
  final ValueChanged<bool>? onMenuOpenChanged;
  final bool compact;

  PopupMenuItem<_GroupQuickAction> _menuItem({
    required _GroupQuickAction value,
    required IconData icon,
    required String label,
    required Color iconColor,
    required Color textColor,
  }) {
    return PopupMenuItem<_GroupQuickAction>(
      value: value,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14.5, color: iconColor),
          const SizedBox(width: 9),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: textColor,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = appearance.itemColor.withValues(alpha: 0.78);
    final side = compact ? 20.0 : 22.0;
    final iconSize = compact ? 14.0 : 16.0;
    final itemIconColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.85);
    final itemTextColor = colorScheme.onSurface.withValues(alpha: 0.92);
    final dangerColor = colorScheme.error.withValues(alpha: 0.90);

    return SizedBox(
      width: side,
      height: side,
      child: PopupMenuButton<_GroupQuickAction>(
        tooltip: '分组操作',
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(6),
        color: Color.alphaBlend(
          colorScheme.surfaceContainerHighest.withValues(alpha: 0.75),
          colorScheme.surface,
        ),
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        offset: const Offset(0, 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        constraints: const BoxConstraints(minWidth: 118, maxWidth: 138),
        menuPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        onOpened: () => onMenuOpenChanged?.call(true),
        onCanceled: () => onMenuOpenChanged?.call(false),
        child: Center(
          child: Icon(Icons.more_horiz_rounded, size: iconSize, color: color),
        ),
        onSelected: (action) {
          onMenuOpenChanged?.call(false);
          switch (action) {
            case _GroupQuickAction.createChat:
              onCreateChat();
            case _GroupQuickAction.rename:
              onRename();
            case _GroupQuickAction.togglePinned:
              onTogglePinned();
            case _GroupQuickAction.delete:
              onDelete();
          }
        },
        itemBuilder: (context) => <PopupMenuEntry<_GroupQuickAction>>[
          _menuItem(
            value: _GroupQuickAction.createChat,
            icon: Icons.add_comment_outlined,
            label: '新建对话',
            iconColor: itemIconColor,
            textColor: itemTextColor,
          ),
          _menuItem(
            value: _GroupQuickAction.rename,
            icon: Icons.edit_outlined,
            label: '编辑名称',
            iconColor: itemIconColor,
            textColor: itemTextColor,
          ),
          _menuItem(
            value: _GroupQuickAction.togglePinned,
            icon: pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
            label: pinned ? '取消置顶' : '置顶',
            iconColor: itemIconColor,
            textColor: itemTextColor,
          ),
          const PopupMenuDivider(height: 8),
          _menuItem(
            value: _GroupQuickAction.delete,
            icon: Icons.delete_outline_rounded,
            label: '删除',
            iconColor: dangerColor,
            textColor: dangerColor,
          ),
        ],
      ),
    );
  }
}
class _HistoryCountBadge extends StatelessWidget {
  /// Creates a compact count badge for history section rows.
  const _HistoryCountBadge({required this.count, required this.appearance});

  final int count;
  final NavigationDrawerAppearance appearance;

  /// Builds a small outlined count badge.
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: appearance.dividerColor),
      ),
      alignment: Alignment.center,
      child: Text(
        count.toString(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: appearance.itemColor.withValues(alpha: 0.70),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SegmentedModeSwitch extends StatelessWidget {
  const _SegmentedModeSwitch({
    required this.groupingMode,
    required this.onToggle,
  });

  final _HistoryGroupingMode groupingMode;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isWorkspace = groupingMode == _HistoryGroupingMode.workspace;
    return Container(
      width: 98,
      height: 23,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = (constraints.maxWidth - 2) / 2;
          return Stack(
            children: <Widget>[
              AnimatedAlign(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                alignment: isWorkspace
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  width: tabWidth,
                  height: constraints.maxHeight,
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: isWorkspace ? onToggle : null,
                        child: Center(
                          child: Text(
                            '角色卡',
                            style: TextStyle(
                              fontSize: 10.5,
                              letterSpacing: -0.2,
                              fontWeight: !isWorkspace
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: !isWorkspace
                                  ? colorScheme.onSecondaryContainer
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: !isWorkspace ? onToggle : null,
                        child: Center(
                          child: Text(
                            '工作区',
                            style: TextStyle(
                              fontSize: 10.5,
                              letterSpacing: -0.2,
                              fontWeight: isWorkspace
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: isWorkspace
                                  ? colorScheme.onSecondaryContainer
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _UnifiedCreateBar extends StatelessWidget {
  const _UnifiedCreateBar({
    required this.onCreateConversation,
    required this.onCreateGroup,
  });

  final VoidCallback onCreateConversation;
  final VoidCallback onCreateGroup;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final contentColor = colorScheme.onPrimaryContainer;
    return SizedBox(
      height: 34,
      child: Material(
        color: colorScheme.primaryContainer,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: <Widget>[
            Expanded(
              child: InkWell(
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(17),
                ),
                hoverColor: contentColor.withValues(alpha: 0.08),
                focusColor: contentColor.withValues(alpha: 0.10),
                splashColor: contentColor.withValues(alpha: 0.10),
                highlightColor: contentColor.withValues(alpha: 0.10),
                onTap: onCreateConversation,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.add_rounded, size: 17, color: contentColor),
                      const SizedBox(width: 6),
                      Text(
                        '新建对话',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: contentColor,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              width: 1,
              height: 16,
              color: contentColor.withValues(alpha: 0.16),
            ),
            Tooltip(
              message: '新建分组',
              child: SizedBox(
                width: 38,
                height: 34,
                child: InkWell(
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(17),
                  ),
                  hoverColor: contentColor.withValues(alpha: 0.08),
                  focusColor: contentColor.withValues(alpha: 0.10),
                  splashColor: contentColor.withValues(alpha: 0.10),
                  highlightColor: contentColor.withValues(alpha: 0.10),
                  onTap: onCreateGroup,
                  child: Center(
                    child: Icon(
                      Icons.create_new_folder_outlined,
                      size: 16,
                      color: contentColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomThemeToggleButton extends StatelessWidget {
  const _BottomThemeToggleButton({
    required this.appearance,
    required this.darkThemeActive,
    required this.onToggle,
  });

  final NavigationDrawerAppearance appearance;
  final bool darkThemeActive;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(8);
    return Tooltip(
      message: darkThemeActive ? '切换白天模式' : '切换黑夜模式',
      child: SizedBox(
        width: 34,
        height: 34,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: appearance.buttonContainerColor.withValues(alpha: 0.55),
            borderRadius: shape,
            border: Border.all(
              color: appearance.dividerColor.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: shape,
            child: InkWell(
              borderRadius: shape,
              onTap: onToggle,
              child: Center(
                child: Icon(
                  darkThemeActive
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  size: 16,
                  color: appearance.itemColor.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.appearance,
    required this.onClick,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final NavigationDrawerAppearance appearance;
  final VoidCallback onClick;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 34,
        height: 34,
        child: Material(
          color: active
              ? appearance.selectedContainerColor.withValues(alpha: 0.35)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onClick,
            child: Center(
              child: Icon(
                icon,
                size: 17,
                color: active
                    ? appearance.statusAvailableColor
                    : appearance.itemColor.withValues(alpha: 0.78),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryLimitButton extends StatelessWidget {
  const _HistoryLimitButton({
    required this.icon,
    required this.label,
    required this.appearance,
    required this.onClick,
  });

  final IconData icon;
  final String label;
  final NavigationDrawerAppearance appearance;
  final VoidCallback onClick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 24, end: 12, top: 2),
      child: TextButton.icon(
        onPressed: onClick,
        icon: Icon(
          icon,
          size: 18,
          color: appearance.itemColor.withValues(alpha: 0.72),
        ),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          foregroundColor: appearance.itemColor.withValues(alpha: 0.72),
          textStyle: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
