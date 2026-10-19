// ignore_for_file: file_names
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../core/bridge/PlatformCoreProxy.dart';
import '../../core/host/FileSaveService.dart';

typedef DataRescueRequest =
    Future<Object?> Function(Map<String, Object?> request);

/// Matches explicit maintenance launch contracts before any business startup work.
bool isDataRescueLaunch({
  required List<String> arguments,
  required String route,
  required Uri uri,
  bool hostRequested = false,
}) {
  return hostRequested ||
      arguments.any((argument) => argument == '--data-rescue') ||
      route == '/data-rescue' ||
      uri.queryParameters['mode'] == 'data-rescue';
}

/// Runs a fixed, standalone Flutter interface with no application services or plugin UI.
class DataRescueApp extends StatelessWidget {
  /// Creates the standalone maintenance app with an injectable offline request boundary.
  const DataRescueApp({
    super.key,
    this.request,
    this.canStopNormalProcess = false,
  });
  final DataRescueRequest? request;
  final bool canStopNormalProcess;

  /// Builds only framework widgets and a fixed theme independent of user preferences.
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Operit2 数据救援 / Data Rescue',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff245f9e)),
      useMaterial3: true,
    ),
    home: _DataRescueScreen(
      request: request ?? platformCoreProxy.dataRescue,
      canStopNormalProcess: canStopNormalProcess,
    ),
  );
}

class _DataRescueScreen extends StatefulWidget {
  /// Receives the independent Host request function without acquiring any business dependency.
  const _DataRescueScreen({
    required this.request,
    required this.canStopNormalProcess,
  });
  final DataRescueRequest request;
  final bool canStopNormalProcess;

  /// Creates the maintenance state owned by this standalone launch.
  @override
  State<_DataRescueScreen> createState() => _DataRescueScreenState();
}

class _DataRescueScreenState extends State<_DataRescueScreen> {
  final _runtime = TextEditingController();
  final _workspace = TextEditingController();
  final _cliConfig = TextEditingController();
  final _password = TextEditingController();
  Map<String, Object?>? _startup;
  Map<String, Object?>? _manifest;
  String? _archiveId;
  String? _error;
  String? _bootstrapError;
  String _status = '正在打开独立存储维护会话…';
  bool _busy = true;
  bool _configured = false;
  bool _closed = false;
  double? _progress;

  /// Acquires exclusive storage access without initializing Core or reading a database.
  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  /// Releases only interface resources; the operating system owns process lease cleanup.
  @override
  void dispose() {
    _runtime.dispose();
    _workspace.dispose();
    _cliConfig.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Validates a structured response at the independent maintenance boundary.
  Future<Map<String, Object?>> _map(Map<String, Object?> request) async =>
      Map<String, Object?>.from((await widget.request(request))! as Map);

  /// Opens the raw startup record and reports malformed configuration without hiding it.
  Future<void> _open() async {
    await _run('正在获取独占存储访问权限，请关闭其他 Operit 窗口及后台会话…', () async {
      final startup = await _map({'operation': 'open'});
      final defaults = Map<String, Object?>.from(
        startup['defaultRoots']! as Map,
      );
      _runtime.text = defaults['runtimeRoot']! as String;
      _workspace.text = defaults['workspaceRoot']! as String;
      final encoded = startup['bootstrapBase64'] as String?;
      if (encoded != null) {
        try {
          final saved =
              jsonDecode(utf8.decode(base64Decode(encoded)))
                  as Map<String, Object?>;
          if (saved['confirmed'] == true) {
            _runtime.text = saved['runtimeRoot']! as String;
            _workspace.text = saved['workspaceRoot']! as String;
          }
        } catch (error) {
          _bootstrapError = '启动配置损坏：$error\n请手动核对下面的数据目录。备份会保留原始配置内容。';
        }
      }
      if (startup['recoveryRoots'] case final Map roots) {
        _runtime.text = roots['runtimeRoot']! as String;
        _workspace.text = roots['workspaceRoot']! as String;
        _cliConfig.text = roots['cliConfigRoot'] as String? ?? '';
      }
      _startup = startup;
      if (startup['recoveryError'] case final String message) {
        _bootstrapError =
            '${_bootstrapError == null ? '' : '${_bootstrapError!}\n'}$message';
      }
      _status = '维护会话已打开。请核对全部身份共用的数据根目录。';
    });
  }

  /// Requests the platform-owned normal process stop action before retrying the exclusive lease.
  Future<void> _stopNormalProcess() async {
    await _run('正在请求停止正常运行进程…', () async {
      await widget.request({'operation': 'stopNormalProcess'});
      await _open();
    });
  }

  /// Confirms complete base roots rather than selecting only the active identity directory.
  Future<void> _configure() async {
    await _run('正在确认数据目录…', () async {
      await widget.request({
        'operation': 'configure',
        'roots': {
          'runtimeRoot': _runtime.text.trim(),
          'workspaceRoot': _workspace.text.trim(),
          if (_cliConfig.text.trim().isNotEmpty)
            'cliConfigRoot': _cliConfig.text.trim(),
        },
      });
      _configured = true;
      _status = '数据目录已确认，可以导出或检查备份。';
    });
  }

  /// Runs a user-requested operation and displays its concrete diagnostic on failure.
  Future<void> _run(String status, Future<void> Function() action) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = status;
      _progress = null;
    });
    try {
      await action();
    } catch (error) {
      var diagnostic = '$error';
      if (_configured && !_closed) {
        try {
          final description = await _map({'operation': 'describe'});
          _startup = {
            ...?_startup,
            'commitPending': description['commitPending'] == true,
          };
        } catch (descriptionError) {
          diagnostic = '$diagnostic\n无法读取维护状态：$descriptionError';
        }
      }
      if (mounted) setState(() => _error = diagnostic);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  /// Saves a streamed, password-encrypted archive using the registered system file picker.
  Future<void> _export() async {
    await _run('正在打包并加密全部数据，请保持设备供电…', () async {
      Map<String, Object?>? archive;
      final name =
          'operit-data-rescue-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.zip';
      try {
        final saved = await FileSaveService.saveGeneratedFile(
          generate: () async {
            archive = await _map({
              'operation': 'export',
              'password': _password.text,
            });
            return XFile(
              archive!['fileReference']! as String,
              name: name,
              mimeType: 'application/zip',
              length: archive!['byteLength']! as int,
            );
          },
          name: name,
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Encrypted Operit data rescue',
              extensions: ['zip'],
              mimeTypes: ['application/zip'],
            ),
          ],
        );
        _status = saved == null ? '已取消保存。' : '备份已保存：$saved\n请将备份和密码保存到设备之外。';
      } finally {
        final id = archive?['archiveId'];
        if (id != null) {
          await widget.request({
            'operation': 'discardArchive',
            'archiveId': id,
          });
        }
      }
    });
  }

  /// Uploads bounded file chunks and authenticates every payload before enabling import.
  Future<void> _inspect() async {
    await _run('请选择备份文件…', () async {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Operit data rescue',
            extensions: ['zip'],
            mimeTypes: ['application/zip'],
          ),
        ],
      );
      if (file == null) {
        _status = '已取消选择。';
        return;
      }
      await _discardArchive();
      final length = await file.length();
      final upload = await _map({
        'operation': 'beginUpload',
        'byteLength': length,
      });
      _archiveId = upload['archiveId']! as String;
      var sent = 0;
      await for (final chunk in file.openRead()) {
        for (var offset = 0; offset < chunk.length; offset += 65536) {
          final end = (offset + 65536).clamp(0, chunk.length);
          final bytes = Uint8List.fromList(chunk.sublist(offset, end));
          await widget.request({
            'operation': 'uploadChunk',
            'archiveId': _archiveId,
            'bytes': base64Encode(bytes),
          });
          sent += bytes.length;
          if (mounted) {
            setState(() {
              _status = '正在暂存备份：$sent / $length 字节';
              _progress = sent / length;
            });
          }
        }
      }
      await widget.request({
        'operation': 'sealUpload',
        'archiveId': _archiveId,
      });
      if (mounted) {
        setState(() {
          _status = '正在校验密码、文件清单及全部文件完整性…';
          _progress = null;
        });
      }
      _manifest = await _map({
        'operation': 'inspect',
        'archiveId': _archiveId,
        'password': _password.text,
      });
      _status = '完整性校验通过。确认导入前，当前数据不会被替换。';
    });
  }

  /// Requires an explicit destructive-action confirmation before publishing a verified archive.
  Future<void> _restore() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认导入全部数据？'),
        content: const Text(
          '将切换到备份中的全部身份、配置、聊天、附件和工作区。原有数据会保留在维护目录中。导入后请退出维护界面，再启动软件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await _run('正在导入，请勿关闭程序或断电…', () async {
      final result = await _map({
        'operation': 'restore',
        'archiveId': _archiveId,
        'password': _password.text,
      });
      await _discardArchive();
      _manifest = null;
      _status = '导入完成。请关闭维护会话后重新启动软件。\n${jsonEncode(result)}';
    });
  }

  /// Explicitly completes an interrupted Host publication while normal startup stays blocked.
  Future<void> _resume() async {
    await _run('正在完成中断的导入…', () async {
      final result = await widget.request({'operation': 'resumeRestore'});
      _startup = {...?_startup, 'commitPending': false};
      _status = '中断的导入已完成。请关闭维护会话后重新启动软件。\n${jsonEncode(result)}';
    });
  }

  /// Releases a staged archive owned by this interface before replacing its selection.
  Future<void> _discardArchive() async {
    final id = _archiveId;
    if (id == null) return;
    await widget.request({'operation': 'discardArchive', 'archiveId': id});
    _archiveId = null;
    _manifest = null;
  }

  /// Closes maintenance access without entering normal application initialization.
  Future<void> _close() async {
    await _run('正在关闭维护会话…', () async {
      await _discardArchive();
      await widget.request({'operation': 'close'});
      _password.clear();
      _closed = true;
      _status = '维护会话已关闭。现在可以关闭此窗口并正常启动软件。';
    });
  }

  /// Builds an accessible, scrollable maintenance screen independent of custom user themes.
  @override
  Widget build(BuildContext context) {
    final ready = _configured && !_busy && !_closed;
    final pending = _startup?['commitPending'] == true;
    final editable = _startup?['rootsEditable'] != false;
    final files = _manifest?['files'] as List<Object?>?;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Operit2 数据救援 / Data Rescue'),
          automaticallyImplyLeading: false,
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  '独立数据维护',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  '此入口只访问存储，不启动 Core、插件、会话、同步任务或用户主题。请先关闭其他 Operit 窗口、后台服务及命令行进程。',
                ),
                const SizedBox(height: 16),
                const Text(
                  '备份包含全部身份的数据、工作区、启动配置及必要密钥，并使用密码加密。密码至少 12 个字符，无法重置。请把备份保存到其他设备。',
                ),
                const SizedBox(height: 20),
                if (_bootstrapError != null) ...[
                  SelectableText(
                    _bootstrapError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _runtime,
                  enabled: !_busy && !_configured && !_closed && editable,
                  decoration: const InputDecoration(
                    labelText: '数据根目录（包含全部 identities）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _workspace,
                  enabled: !_busy && !_configured && !_closed && editable,
                  decoration: const InputDecoration(
                    labelText: '工作区根目录',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                if (editable)
                  TextField(
                    controller: _cliConfig,
                    enabled: !_busy && !_configured && !_closed,
                    decoration: const InputDecoration(
                      labelText: 'CLI 配置目录（导入 CLI 备份时填写）',
                      helperText: '单独保存在 CLI 配置目录的数据也会纳入救援。',
                    ),
                  ),
                if (!_configured && _startup != null && !_closed)
                  FilledButton(
                    onPressed: _busy ? null : _configure,
                    child: const Text('确认数据目录'),
                  ),
                const SizedBox(height: 20),
                TextField(
                  controller: _password,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  enabled: !_busy && !_closed,
                  decoration: const InputDecoration(
                    labelText: '备份密码（至少 12 个字符）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: ready && !pending ? _export : null,
                      icon: const Icon(Icons.save_alt),
                      label: const Text('导出全部数据'),
                    ),
                    OutlinedButton.icon(
                      onPressed: ready && !pending ? _inspect : null,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('选择并检查备份'),
                    ),
                    if (files != null)
                      FilledButton.icon(
                        onPressed: ready ? _restore : null,
                        icon: const Icon(Icons.restore),
                        label: Text('导入已校验的 ${files.length} 个文件'),
                      ),
                    if (pending)
                      FilledButton(
                        onPressed: ready ? _resume : null,
                        child: const Text('完成中断的导入'),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                if (_busy) ...[
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 12),
                ],
                SelectableText(_status),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  SelectableText(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (_startup == null && !_busy)
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      OutlinedButton(
                        onPressed: _open,
                        child: const Text('重新打开维护会话'),
                      ),
                      if (widget.canStopNormalProcess)
                        OutlinedButton(
                          onPressed: _stopNormalProcess,
                          child: const Text('停止正常运行进程后重试'),
                        ),
                    ],
                  ),
                if (!_closed && _startup != null)
                  TextButton(
                    onPressed: _busy ? null : _close,
                    child: const Text('关闭维护会话'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
