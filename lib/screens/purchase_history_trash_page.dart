import '../widgets/app_snack_bar.dart';
import 'package:flutter/material.dart';
import '../core/formatters.dart';
import '../models/purchase_record.dart';
import '../widgets/mini_lotto_ball.dart';

class PurchaseHistoryTrashPage extends StatefulWidget {
  const PurchaseHistoryTrashPage({
    super.key,
    required this.loadRecords,
    required this.restoreRecord,
  });
  final Future<List<PurchaseRecord>> Function() loadRecords;
  final Future<void> Function(int) restoreRecord;
  @override
  State<PurchaseHistoryTrashPage> createState() =>
      _PurchaseHistoryTrashPageState();
}

class _PurchaseHistoryTrashPageState extends State<PurchaseHistoryTrashPage> {
  List<PurchaseRecord>? _records;
  final _busy = <int>{};
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sets = await widget.loadRecords();
      if (mounted) {
        setState(() {
          _records = sets;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _restore(PurchaseRecord set) async {
    if (_busy.contains(set.id)) return;
    setState(() => _busy.add(set.id));
    try {
      await widget.restoreRecord(set.id);
      await _load();
      if (mounted) {
        showAppSnackBar(context, content: Text('구매내역을 복원했습니다.'));
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, content: Text('복원하지 못했어요. 다시 시도해주세요.'));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(set.id));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('구매내역 휴지통')),
    body: _failed
        ? Center(
            child: TextButton(onPressed: _load, child: const Text('다시 불러오기')),
          )
        : _records == null
        ? const Center(child: CircularProgressIndicator())
        : _records!.isEmpty
        ? const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.delete_outline, size: 48),
                SizedBox(height: 12),
                Text('휴지통이 비어 있습니다'),
              ],
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '삭제한 구매내역을 복원할 수 있어요. 회차와 결과 확인 상태도 유지됩니다.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              for (final set in _records!)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${set.round}회 · ${set.games.length}게임 · ${set.source == 'qr' ? 'QR' : '직접입력'}',
                        ),
                        Text(
                          '추첨일 ${set.drawDate} · 등록 ${formatDateTime(set.createdAt)}',
                        ),
                        if (set.isResultChecked) const Text('결과 확인 완료'),
                        const SizedBox(height: 12),
                        for (final game in set.games)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final number in game)
                                  MiniLottoBall(number: number),
                              ],
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.tonalIcon(
                            onPressed: _busy.contains(set.id)
                                ? null
                                : () => _restore(set),
                            icon: _busy.contains(set.id)
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.restore),
                            label: const Text('복원'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
  );
}
