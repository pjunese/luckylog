import '../widgets/app_snack_bar.dart';
import 'package:flutter/material.dart';
import '../core/formatters.dart';
import '../models/number_set.dart';
import '../widgets/mini_lotto_ball.dart';

class NumberSetTrashPage extends StatefulWidget {
  const NumberSetTrashPage({
    super.key,
    required this.loadSets,
    required this.restoreSet,
  });
  final Future<List<NumberSet>> Function() loadSets;
  final Future<void> Function(int) restoreSet;
  @override
  State<NumberSetTrashPage> createState() => _NumberSetTrashPageState();
}

class _NumberSetTrashPageState extends State<NumberSetTrashPage> {
  List<NumberSet>? _sets;
  final _busy = <int>{};
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sets = await widget.loadSets();
      if (mounted) {
        setState(() {
          _sets = sets;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _restore(NumberSet set) async {
    if (_busy.contains(set.id)) return;
    setState(() => _busy.add(set.id));
    try {
      await widget.restoreSet(set.id);
      await _load();
      if (mounted) {
        showAppSnackBar(context, content: Text('번호세트를 보관함으로 복원했습니다.'));
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
    appBar: AppBar(title: const Text('번호세트 휴지통')),
    body: _failed
        ? Center(
            child: TextButton(onPressed: _load, child: const Text('다시 불러오기')),
          )
        : _sets == null
        ? const Center(child: CircularProgressIndicator())
        : _sets!.isEmpty
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
                '삭제한 번호세트를 다시 보관함으로 가져올 수 있어요.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              for (final set in _sets!)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${set.games.length}게임 · ${formatDateTime(set.createdAt)}',
                        ),
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
