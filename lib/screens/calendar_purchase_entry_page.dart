import 'package:flutter/material.dart';
import '../models/purchase_date.dart';
import '../services/purchase_insights_controller.dart';
import '../widgets/number_picker_sheet.dart';
import '../widgets/mini_lotto_ball.dart';
import '../widgets/app_snack_bar.dart';

class CalendarPurchaseEntryPage extends StatefulWidget {
  const CalendarPurchaseEntryPage({
    super.key,
    required this.day,
    required this.controller,
  });
  final DateTime day;
  final PurchaseInsightsController controller;
  @override
  State<CalendarPurchaseEntryPage> createState() =>
      _CalendarPurchaseEntryPageState();
}

class _CalendarPurchaseEntryPageState extends State<CalendarPurchaseEntryPage> {
  late final int _minRound =
      (widget.day.difference(DateTime.utc(2002, 12, 7)).inDays / 7).ceil() + 1;
  late int _round = _minRound;
  final _games = <List<int>>[[]];
  bool _saving = false;
  Future<void> _pick(int index) async {
    final selected = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => NumberPickerSheet(
        gameIndex: index,
        initialSelection: _games[index],
        maxSelection: 6,
      ),
    );
    if (selected != null && mounted) {
      setState(() => _games[index] = selected..sort());
    }
  }

  Future<void> _save() async {
    if (_saving || _games.any((g) => g.length != 6)) return;
    setState(() => _saving = true);
    try {
      await widget.controller.addPurchase(
        _games.map((g) => List<int>.of(g)).toList(),
        _round,
        widget.day,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          content: const Text('구매내역을 저장하지 못했어요. 다시 시도해주세요.'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      appBar: AppBar(title: const Text('구매내역 등록')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '구매일 ${purchaseDateKey(widget.day)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              IconButton(
                tooltip: '이전 회차',
                onPressed: !_saving && _round > _minRound
                    ? () => setState(() => _round--)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      '$_round회',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '${purchaseDateKey(DateTime.utc(2002, 12, 7).add(Duration(days: (_round - 1) * 7)))} 추첨',
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '다음 회차',
                onPressed: !_saving && _round < _minRound + 2
                    ? () => setState(() => _round++)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _games.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('${i + 1}게임')),
                        if (_games.length > 1)
                          IconButton(
                            tooltip: '게임 제거',
                            onPressed: _saving
                                ? null
                                : () => setState(() => _games.removeAt(i)),
                            icon: const Icon(Icons.close),
                          ),
                      ],
                    ),
                    if (_games[i].isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final n in _games[i]) MiniLottoBall(number: n),
                        ],
                      ),
                    TextButton.icon(
                      onPressed: _saving ? null : () => _pick(i),
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(_games[i].isEmpty ? '번호 선택' : '번호 수정'),
                    ),
                  ],
                ),
              ),
            ),
          if (_games.length < 5)
            TextButton.icon(
              onPressed: _saving ? null : () => setState(() => _games.add([])),
              icon: const Icon(Icons.add),
              label: const Text('게임 추가'),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving || _games.any((g) => g.length != 6)
                ? null
                : _save,
            child: Text(_saving ? '저장 중…' : '${_games.length}게임 구매 등록'),
          ),
        ],
      ),
    ),
  );
}
