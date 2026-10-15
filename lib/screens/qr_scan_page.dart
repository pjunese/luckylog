import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/scanned_ticket.dart';
import '../services/qr_scan_queue.dart';
import '../widgets/qr_camera.dart';
import 'qr_result_webview_page.dart';

/// Returns a batch only after the user explicitly registers it. With [onSave],
/// a failed durable save keeps the queue open for retry.
class QRScanPage extends StatefulWidget {
  const QRScanPage({
    super.key,
    this.knownFingerprints = const {},
    this.onSave,
    this.camera,
    this.pickImages,
    this.openResult,
  });

  final Set<String> knownFingerprints;
  final Future<void> Function(List<ScannedTicket>)? onSave;
  final QrCamera? camera;
  final Future<List<String>> Function()? pickImages;
  final Future<void> Function(BuildContext, Uri)? openResult;

  @override
  State<QRScanPage> createState() => _QRScanPageState();
}

class _QRScanPageState extends State<QRScanPage> with WidgetsBindingObserver {
  late final QrCamera _camera;
  late final QrScanQueue _queue;
  Future<void> _cameraTail = Future<void>.value();
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  bool _disposed = false;
  bool _picking = false;
  bool _saving = false;
  bool _viewingResult = false;
  bool _confirmingExit = false;
  bool _allowPop = false;
  int _photoGeneration = 0;
  Set<String> _lastCameraRead = {};
  String _notice = '카메라로 연속 스캔하거나 사진을 선택하세요.';
  bool _noticeIsError = false;
  bool _cameraFailureAnnounced = false;
  Uri? _lookupUri;

  bool get _busy => _picking || _saving || _viewingResult || _confirmingExit;
  bool get _shouldRunCamera =>
      !_disposed &&
      !_allowPop &&
      !_busy &&
      _lifecycle == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _camera = widget.camera ?? DeviceQrCamera();
    _queue = QrScanQueue(knownFingerprints: widget.knownFingerprints);
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_syncCamera());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    unawaited(_syncCamera());
  }

  Future<void> _syncCamera() {
    _cameraTail = _cameraTail.then((_) async {
      if (_disposed) return;
      try {
        if (_shouldRunCamera) {
          await _camera.start();
        } else {
          await _camera.stop();
        }
      } catch (_) {
        if (!mounted || _disposed || _cameraFailureAnnounced) return;
        _cameraFailureAnnounced = true;
        setState(() {
          _notice = '카메라를 사용할 수 없어요. 사진에서 QR을 읽을 수 있습니다.';
          _noticeIsError = true;
        });
      }
    });
    return _cameraTail;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_photoGeneration;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      _cameraTail.then((_) => _camera.dispose()).catchError((Object _) {}),
    );
    super.dispose();
  }

  void _onCameraDetect(List<String> rawValues) {
    if (!mounted || !_shouldRunCamera) return;
    final values = rawValues.where((raw) => raw.trim().isNotEmpty).toSet();
    // A stationary QR should not repeatedly announce itself or immediately
    // reappear after the user removes it from the queue.
    if (values.isEmpty) {
      _lastCameraRead = {};
      return;
    }
    if (setEquals(values, _lastCameraRead)) return;
    _lastCameraRead = values;
    _accept(values);
  }

  void _accept(Iterable<String> values) {
    if (!mounted) return;
    final feedback = values.map(_queue.add).toList();
    if (feedback.isEmpty) return;
    final added = feedback
        .where((item) => item.outcome == QrScanOutcome.added)
        .length;
    final fallback = feedback
        .where((item) => item.lookupUri != null)
        .firstOrNull;
    final last = feedback.last;
    setState(() {
      _lookupUri = fallback?.lookupUri;
      _notice = added > 1
          ? '$added장을 대기 목록에 추가했어요.'
          : added == 1
          ? feedback
                .firstWhere((item) => item.outcome == QrScanOutcome.added)
                .message
          : last.message;
      _noticeIsError =
          added == 0 &&
          feedback.any((item) => item.outcome != QrScanOutcome.queuedDuplicate);
    });
  }

  Future<void> _pickPhotos() async {
    if (_busy || _allowPop) return;
    final generation = ++_photoGeneration;
    setState(() {
      _picking = true;
      _lookupUri = null;
    });
    await _syncCamera();
    if (!mounted || generation != _photoGeneration) return;
    var added = 0;
    var repeated = 0;
    var unreadable = 0;
    Uri? lookup;
    try {
      final paths = widget.pickImages != null
          ? await widget.pickImages!()
          : (await ImagePicker().pickMultiImage(
              requestFullMetadata: false,
            )).map((image) => image.path).toList();
      for (var index = 0; index < paths.length; index++) {
        if (!mounted || generation != _photoGeneration) return;
        setState(() => _notice = '사진 ${index + 1}/${paths.length} 분석 중…');
        List<String> values;
        try {
          values = await _camera.analyzeImage(paths[index]);
        } catch (_) {
          unreadable++;
          continue;
        }
        if (!mounted || generation != _photoGeneration) return;
        if (values.isEmpty) unreadable++;
        for (final raw in values) {
          final feedback = _queue.add(raw);
          switch (feedback.outcome) {
            case QrScanOutcome.added:
              added++;
            case QrScanOutcome.queuedDuplicate:
            case QrScanOutcome.knownDuplicate:
              repeated++;
            case QrScanOutcome.lookupOnly:
              lookup ??= feedback.lookupUri;
              unreadable++;
            case QrScanOutcome.invalid:
              unreadable++;
          }
        }
        setState(() {});
      }
      if (!mounted || generation != _photoGeneration) return;
      if (paths.isNotEmpty) {
        setState(() {
          final details = [
            '$added장 추가',
            if (repeated > 0) '중복 $repeated건 제외',
            if (unreadable > 0) '$unreadable건 확인 필요',
          ];
          _notice = details.join(' · ');
          _noticeIsError = added == 0;
          _lookupUri = lookup;
        });
      }
    } catch (_) {
      if (mounted && generation == _photoGeneration) {
        setState(() {
          _notice = '사진을 읽지 못했어요. 사진 접근 권한을 확인하고 다시 선택해 주세요.';
          _noticeIsError = true;
        });
      }
    } finally {
      if (mounted && generation == _photoGeneration) {
        setState(() => _picking = false);
        await _syncCamera();
      }
    }
  }

  Future<void> _viewResult(Uri uri) async {
    if (_busy || _allowPop) return;
    setState(() => _viewingResult = true);
    await _syncCamera();
    if (!mounted) return;
    try {
      if (widget.openResult != null) {
        await widget.openResult!(context, uri);
      } else {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => QRResultWebViewPage(initialUri: uri),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _notice = '결과 페이지를 열지 못했어요. 복권 등록은 계속할 수 있습니다.';
          _noticeIsError = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _viewingResult = false);
        await _syncCamera();
      }
    }
  }

  Future<void> _save() async {
    if (_busy || _queue.isEmpty || _allowPop) return;
    final tickets = _queue.tickets;
    setState(() => _saving = true);
    await _syncCamera();
    if (!mounted) return;
    try {
      await widget.onSave?.call(tickets);
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop<List<ScannedTicket>>(tickets);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = '등록하지 못했어요. 목록은 그대로 있습니다. 다시 등록해 주세요.';
        _noticeIsError = true;
      });
      await _syncCamera();
    }
  }

  Future<void> _requestLeave() async {
    if (_saving || _confirmingExit || _viewingResult || _allowPop) return;
    if (_queue.isEmpty && !_picking) {
      setState(() => _allowPop = true);
      await _syncCamera();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _confirmingExit = true);
    await _syncCamera();
    if (!mounted) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('등록을 마칠까요?'),
        content: Text(
          _queue.isEmpty
              ? '사진 분석을 중단하고 나갑니다.'
              : '대기 중인 ${_queue.length}장은 아직 저장되지 않았습니다. 목록을 비우고 나갈까요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('계속 스캔'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _confirmingExit = false);
    if (discard == true) {
      ++_photoGeneration;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    } else {
      await _syncCamera();
    }
  }

  void _remove(ScannedTicket ticket) {
    if (_busy) return;
    setState(() {
      _queue.remove(ticket.fingerprint);
      _notice = '대기 목록에서 제외했어요. 다음 복권을 비춰 주세요.';
      _noticeIsError = false;
      _lookupUri = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope<List<ScannedTicket>>(
      canPop: _allowPop || (_queue.isEmpty && !_busy),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestLeave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('QR 등록'),
          leading: IconButton(
            tooltip: '뒤로',
            onPressed: _saving ? null : _requestLeave,
            icon: const Icon(Icons.arrow_back),
          ),
          actions: [
            IconButton(
              tooltip: '사진 여러 장에서 QR 읽기',
              onPressed: _busy ? null : _pickPhotos,
              icon: const Icon(Icons.photo_library_outlined),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cameraHeight = math.min(
                220.0,
                math.max(110.0, constraints.maxHeight * .30),
              );
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        SizedBox(
                          height: cameraHeight,
                          width: double.infinity,
                          child: ClipRect(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _camera.buildPreview(context, _onCameraDetect),
                                IgnorePointer(
                                  child: Center(
                                    child: Container(
                                      width: cameraHeight * .68,
                                      height: cameraHeight * .68,
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.white.withValues(
                                            alpha: .85,
                                          ),
                                          width: 2,
                                        ),
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                    ),
                                  ),
                                ),
                                if (_picking || _saving)
                                  const ColoredBox(
                                    color: Color(0x99162523),
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Semantics(
                            liveRegion: true,
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _noticeIsError
                                    ? colors.errorContainer
                                    : colors.secondaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _notice,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: _noticeIsError
                                              ? colors.onErrorContainer
                                              : colors.onSecondaryContainer,
                                        ),
                                  ),
                                  if (_lookupUri != null)
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _viewResult(_lookupUri!),
                                      child: const Text('동행복권에서 결과 보기'),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '등록 대기 ${_queue.length}장',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              Text(
                                '${_queue.gameCount}게임',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_queue.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(
                              Icons.receipt_long_outlined,
                              size: 36,
                              color: colors.outline,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '읽은 복권이 여기에 모입니다',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '번호가 같은 다른 복권도 각각 등록할 수 있어요.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      sliver: SliverList.builder(
                        itemCount: _queue.length,
                        itemBuilder: (context, index) =>
                            _ticketRow(_queue.tickets[index]),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(
              children: [
                IconButton.filledTonal(
                  tooltip: '사진 여러 장에서 QR 읽기',
                  onPressed: _busy ? null : _pickPhotos,
                  icon: const Icon(Icons.photo_library_outlined),
                  style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const Key('qr-save'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 52),
                    ),
                    onPressed: _busy || _queue.isEmpty ? null : _save,
                    child: Text(
                      _saving
                          ? '등록 중…'
                          : _picking
                          ? '사진 분석 중…'
                          : '${_queue.length}장 등록',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _ticketRow(ScannedTicket ticket) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey(ticket.fingerprint),
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${ticket.round}회 · ${ticket.games.length}게임',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    ticket.games.first.join(' · '),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (ticket.games.length > 1)
                    Text(
                      '외 ${ticket.games.length - 1}게임',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Column(
              children: [
                IconButton(
                  tooltip: '${ticket.round}회 복권을 대기 목록에서 제외',
                  onPressed: _busy ? null : () => _remove(ticket),
                  icon: const Icon(Icons.close, size: 20),
                ),
                IconButton(
                  tooltip: '${ticket.round}회 동행복권 결과 보기',
                  onPressed: _busy ? null : () => _viewResult(ticket.uri),
                  icon: const Icon(Icons.open_in_new, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
