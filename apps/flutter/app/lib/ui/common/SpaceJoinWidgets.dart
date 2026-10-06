// ignore_for_file: file_names
import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/proxy/generated/CoreProxyClients.g.dart';
import '../../core/proxy/generated/CoreProxyModels.g.dart' as generated;
import '../../l10n/generated/app_localizations.dart';

bool spaceJoinIsActive(generated.SpaceJoinStatus status) => switch (status) {
  generated.SpaceJoinStatus.pending ||
  generated.SpaceJoinStatus.approving ||
  generated.SpaceJoinStatus.approved => true,
  _ => false,
};

String spaceJoinStatusText(
  generated.SpaceJoinRequest request,
  AppLocalizations l10n,
) => switch (request.status) {
  generated.SpaceJoinStatus.pending =>
    request.reviewerDeviceId == null
        ? l10n.spaceJoinWaitingReviewer
        : l10n.spaceJoinPending,
  generated.SpaceJoinStatus.approving => l10n.spaceJoinApproving,
  generated.SpaceJoinStatus.approved => l10n.spaceJoinApproved,
  generated.SpaceJoinStatus.rejected => l10n.spaceJoinRejected,
  generated.SpaceJoinStatus.cancelled => l10n.spaceJoinCancelled,
  generated.SpaceJoinStatus.expired => l10n.spaceJoinExpired,
  generated.SpaceJoinStatus.joined => l10n.spaceJoinJoined,
};

/// Open before the network request. Submitting/offline/waiting all have a real
/// dialog; a normal pending response must never flow into a page's error label.
Future<generated.CoreSpace?> showSpaceJoinRequest(
  BuildContext context, {
  required GeneratedCoreProxyClients clients,
  required String deviceId,
  required String deviceName,
}) => showDialog<generated.CoreSpace>(
  context: context,
  builder: (_) => SpaceJoinProgressDialog(
    clients: clients,
    deviceId: deviceId,
    deviceName: deviceName,
  ),
);

Future<generated.CoreSpace?> showSpaceJoinProgress(
  BuildContext context, {
  required GeneratedCoreProxyClients clients,
  required generated.SpaceJoinRequest request,
}) => showDialog<generated.CoreSpace>(
  context: context,
  builder: (_) => SpaceJoinProgressDialog(clients: clients, request: request),
);

class SpaceJoinProgressDialog extends StatefulWidget {
  const SpaceJoinProgressDialog({
    super.key,
    required this.clients,
    this.request,
    this.deviceId,
    this.deviceName,
  }) : assert(request != null || deviceId != null);
  final GeneratedCoreProxyClients clients;
  final generated.SpaceJoinRequest? request;
  final String? deviceId, deviceName;
  @override
  State<SpaceJoinProgressDialog> createState() =>
      _SpaceJoinProgressDialogState();
}

class _SpaceJoinProgressDialogState extends State<SpaceJoinProgressDialog> {
  generated.SpaceJoinRequest? _request;
  Timer? _timer;
  bool _busy = false;
  bool _polling = false;
  bool _cancelling = false;
  int _responseEpoch = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    _request = widget.request;
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refresh()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_request == null ? _submit() : _refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Submits a request and reports transport errors separately from reviewer assignment.
  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final l10n = AppLocalizations.of(context)!;
    try {
      final request = await widget.clients.server.runtimeRemoteLinkService
          .requestDeviceSpaceJoin(deviceId: widget.deviceId!);
      if (!mounted) return;
      setState(() => _request = request);
      await _completeIfJoined(request);
    } catch (error) {
      // Submission may have been persisted before the reply was lost. Recover
      // that request instead of creating another one or displaying COMMAND_ERROR.
      try {
        final saved = await widget.clients.server.runtimeRemoteLinkService
            .outgoingDeviceSpaceJoins();
        final matches = saved.where(
          (r) =>
              r.targetDeviceId == widget.deviceId &&
              spaceJoinIsActive(r.status),
        );
        if (mounted) {
          setState(() {
            if (matches.isNotEmpty) _request = matches.last;
            _error = '${l10n.spaceJoinSubmitFailed}\n$error';
          });
        }
      } catch (_) {
        if (mounted) setState(() => _error = l10n.spaceJoinSubmitFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeIfJoined(generated.SpaceJoinRequest request) async {
    if (request.status != generated.SpaceJoinStatus.joined) return;
    final space = await widget.clients.server.runtimeRemoteLinkService
        .deviceSpace();
    if (mounted) Navigator.pop(context, space);
  }

  /// Keeps cancellation independent of polling and discards responses superseded by user action.
  Future<void> _refresh({bool cancel = false}) async {
    final previous = _request;
    if (_busy ||
        _cancelling ||
        previous == null ||
        (!cancel && (_polling || !spaceJoinIsActive(previous.status)))) {
      return;
    }
    if (cancel) {
      _responseEpoch++;
      setState(() => _cancelling = true);
    } else {
      _polling = true;
    }
    final epoch = _responseEpoch;
    try {
      final service = widget.clients.server.runtimeRemoteLinkService;
      final request = cancel
          ? await service.cancelDeviceSpaceJoin(requestId: previous.requestId)
          : await service.refreshDeviceSpaceJoin(requestId: previous.requestId);
      if (!mounted || epoch != _responseEpoch) return;
      setState(() {
        _request = request;
        _error = null;
      });
      await _completeIfJoined(request);
    } catch (error) {
      if (mounted && epoch == _responseEpoch) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (cancel) {
        if (mounted) setState(() => _cancelling = false);
      } else {
        _polling = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final request = _request;
    final colors = Theme.of(context).colorScheme;
    final waiting = request == null || spaceJoinIsActive(request.status);
    return AlertDialog(
      icon: Icon(
        waiting ? Icons.hourglass_top_rounded : Icons.fact_check_outlined,
      ),
      title: Text(l10n.spaceJoinProgressTitle),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              request?.spaceName ?? widget.deviceName ?? '',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (request?.reviewerDeviceId != null) ...[
                    Row(
                      children: [
                        const Icon(Icons.person_outline, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.spaceJoinReviewer(
                              request!.reviewerName ??
                                  request.reviewerDeviceId!,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Icon(
                        waiting ? Icons.schedule : Icons.info_outline,
                        size: 20,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          request == null
                              ? (_busy
                                    ? l10n.spaceJoinSending
                                    : l10n.spaceJoinSubmitFailed)
                              : (request.status ==
                                            generated.SpaceJoinStatus.pending &&
                                        request.reviewerDeviceId == null &&
                                        _error != null
                                    ? l10n.spaceJoinSubmitFailed
                                    : spaceJoinStatusText(request, l10n)),
                          style: TextStyle(
                            color: colors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (waiting) ...[
              const SizedBox(height: 12),
              Text(
                l10n.spaceJoinNoDataYet,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: [
        if (request == null && !_busy)
          FilledButton(onPressed: _submit, child: Text(l10n.spaceJoinSubmit)),
        if (request?.status == generated.SpaceJoinStatus.pending)
          TextButton(
            onPressed: _cancelling ? null : () => _refresh(cancel: true),
            child: Text(l10n.spaceJoinCancel),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(waiting ? l10n.spaceJoinKeepWaiting : l10n.ok),
        ),
      ],
    );
  }
}

/// Only canonical assignments with canApprove=true can open this dialog.
Future<void> showSpaceJoinApproval(
  BuildContext context, {
  required GeneratedCoreProxyClients clients,
  required generated.SpaceJoinRequest request,
}) async {
  if (!request.canApprove || request.reviewerDeviceId == null) return;
  await showDialog<void>(
    context: context,
    builder: (_) => SpaceJoinApprovalDialog(clients: clients, request: request),
  );
}

class SpaceJoinApprovalDialog extends StatefulWidget {
  const SpaceJoinApprovalDialog({
    super.key,
    required this.clients,
    required this.request,
  });
  final GeneratedCoreProxyClients clients;
  final generated.SpaceJoinRequest request;
  @override
  State<SpaceJoinApprovalDialog> createState() =>
      _SpaceJoinApprovalDialogState();
}

class _SpaceJoinApprovalDialogState extends State<SpaceJoinApprovalDialog> {
  Timer? _timer;
  bool _busy = false;
  bool _polling = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_verify()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_busy || _polling) return;
    _polling = true;
    try {
      final requests = await widget.clients.server.runtimeRemoteLinkService
          .incomingDeviceSpaceJoins();
      final valid = requests.any(
        (r) =>
            r.requestId == widget.request.requestId &&
            r.canApprove &&
            r.assignmentVersion == widget.request.assignmentVersion,
      );
      if (mounted && !valid) Navigator.pop(context);
    } catch (_) {
      /* Keep the dialog on transient disconnect; backend rechecks on decision. */
    } finally {
      _polling = false;
    }
  }

  Future<void> _decide(bool approve) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.clients.server.runtimeRemoteLinkService
          .decideDeviceSpaceJoin(
            requestId: widget.request.requestId,
            assignmentVersion: widget.request.assignmentVersion,
            approve: approve,
          );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final request = widget.request;
    final claimed = request.status == generated.SpaceJoinStatus.approving;
    return AlertDialog(
      title: Text(l10n.spaceJoinApprovalTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.spaceJoinApprovalDescription(
              request.applicantName,
              request.spaceName,
            ),
          ),
          if (claimed) ...[
            const SizedBox(height: 12),
            Text(l10n.spaceJoinApproving),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed:
              _busy ||
                  !request.canApprove ||
                  (claimed && request.decisionApprove != false)
              ? null
              : () => _decide(false),
          child: Text(l10n.spaceJoinReject),
        ),
        FilledButton(
          onPressed:
              _busy ||
                  !request.canApprove ||
                  (claimed && request.decisionApprove != true)
              ? null
              : () => _decide(true),
          child: Text(l10n.spaceJoinApprove),
        ),
      ],
    );
  }
}

/// Persistent entry point: background waiting, restart recovery, and postponed approvals.
class SpaceJoinRequestsPanel extends StatefulWidget {
  const SpaceJoinRequestsPanel({
    super.key,
    required this.clients,
    required this.onJoined,
  });
  final GeneratedCoreProxyClients clients;
  final Future<void> Function(generated.CoreSpace) onJoined;
  @override
  State<SpaceJoinRequestsPanel> createState() => _SpaceJoinRequestsPanelState();
}

class _SpaceJoinRequestsPanelState extends State<SpaceJoinRequestsPanel> {
  Timer? _timer;
  List<generated.SpaceJoinRequest> _outgoing = [], _incoming = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_load()),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    _busy = true;
    try {
      final service = widget.clients.server.runtimeRemoteLinkService;
      final outgoing = await service.outgoingDeviceSpaceJoins();
      final incoming = await service.incomingDeviceSpaceJoins();
      if (mounted) {
        setState(() {
          _outgoing = outgoing;
          _incoming = incoming;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _busy = false;
    }
  }

  Future<void> _open(generated.SpaceJoinRequest request, bool incoming) async {
    try {
      if (incoming) {
        if (!mounted) return;
        await showSpaceJoinApproval(
          context,
          clients: widget.clients,
          request: request,
        );
      } else {
        if (!mounted) return;
        final dialogContext = context;
        if (!dialogContext.mounted) return;
        final generated.CoreSpace? space;
        if (!spaceJoinIsActive(request.status) &&
            request.status != generated.SpaceJoinStatus.joined) {
          space = await showSpaceJoinRequest(
            dialogContext,
            clients: widget.clients,
            deviceId: request.targetDeviceId,
            deviceName: request.spaceName,
          );
        } else {
          space = await showSpaceJoinProgress(
            dialogContext,
            clients: widget.clients,
            request: request,
          );
        }
        if (mounted && space != null) await widget.onJoined(space);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
    await _load();
  }

  Widget _requests(
    List<generated.SpaceJoinRequest> requests,
    bool incoming,
    AppLocalizations l10n,
  ) {
    if (requests.isEmpty) {
      return Center(child: Text(l10n.deviceSpaceNoRequests));
    }
    return ListView.separated(
      itemCount: requests.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final request = requests[index];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 4,
          ),
          leading: Icon(
            incoming ? Icons.fact_check_outlined : Icons.schedule_rounded,
          ),
          title: Text(incoming ? request.applicantName : request.spaceName),
          subtitle: Text(
            [
              if (incoming) request.spaceName,
              if (!incoming && request.reviewerDeviceId != null)
                l10n.spaceJoinReviewer(
                  request.reviewerName ?? request.reviewerDeviceId!,
                ),
              spaceJoinStatusText(request, l10n),
            ].join('\n'),
          ),
          trailing: request.status == generated.SpaceJoinStatus.joined
              ? const Icon(Icons.check_circle_outline)
              : const Icon(Icons.chevron_right_rounded),
          onTap: request.status == generated.SpaceJoinStatus.joined
              ? null
              : () => _open(request, incoming),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: 440,
      height: (MediaQuery.sizeOf(context).height * .45).clamp(220.0, 380.0),
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            TabBar(
              tabs: [
                Tab(text: l10n.deviceSpaceMyRequests),
                Tab(text: l10n.deviceSpaceMyReviews),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(child: Text(l10n.spaceJoinRefreshingFailed)),
                    TextButton(onPressed: _load, child: Text(l10n.retry)),
                  ],
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  _requests(_outgoing.reversed.toList(), false, l10n),
                  _requests(_incoming, true, l10n),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
