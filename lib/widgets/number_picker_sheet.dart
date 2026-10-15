import 'app_snack_bar.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/lotto_palette.dart';

class NumberPickerSheet extends StatefulWidget {
  const NumberPickerSheet({
    super.key,
    required this.gameIndex,
    required this.initialSelection,
    required this.maxSelection,
  });

  final int gameIndex;
  final List<int> initialSelection;
  final int maxSelection;

  @override
  State<NumberPickerSheet> createState() => _NumberPickerSheetState();
}

class _NumberPickerSheetState extends State<NumberPickerSheet> {
  late Set<int> _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSelection.toSet();
  }

  void _toggleNumber(int number, bool shouldSelect) {
    if (shouldSelect && _selected.length >= widget.maxSelection) {
      showAppSnackBar(
        context,
        content: Text('번호는 최대 ${widget.maxSelection}개까지 선택할 수 있습니다.'),
      );
      return;
    }

    setState(() {
      if (shouldSelect) {
        _selected.add(number);
      } else {
        _selected.remove(number);
      }
    });
  }

  void _pickRandom() {
    final int ts2 = DateTime.now().microsecondsSinceEpoch;
    double cv = ((ts2 % 999983) / 999983.0) + ((ts2 % 997) / 997000.0);
    cv = cv % 1.0;
    for (int w = 0; w < 13; w++) {
      cv = (sin(cv * 99991.0 + pi) * 1e9).abs() % 1.0;
    }
    final List<int> pool = List<int>.generate(45, (index) => index + 1);
    for (int i = pool.length - 1; i > 0; i--) {
      cv = (sin(cv * 99991.0 + pi) * 1e9).abs() % 1.0;
      final int j = (cv * (i + 1)).floor().clamp(0, i);
      final int tmp = pool[i];
      pool[i] = pool[j];
      pool[j] = tmp;
    }
    setState(() {
      _selected = pool.take(widget.maxSelection).toSet();
    });
  }

  void _clear() {
    setState(() {
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${widget.gameIndex + 1}게임 번호 선택',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '1~45 중 ${widget.maxSelection}개 선택',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('${_selected.length}/${widget.maxSelection}'),
                          TextButton.icon(
                            onPressed: _pickRandom,
                            icon: const Icon(Icons.casino_outlined),
                            label: const Text('랜덤'),
                          ),
                          TextButton.icon(
                            onPressed: _clear,
                            icon: const Icon(Icons.clear_all),
                            label: const Text('초기화'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
                SliverGrid.builder(
                  itemCount: 45,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    mainAxisExtent: max(
                      48,
                      MediaQuery.textScalerOf(context).scale(15) + 20,
                    ),
                  ),
                  itemBuilder: (context, index) {
                    final int number = index + 1;
                    final bool isSelected = _selected.contains(number);
                    final Color ballColor = lottoBallColor(number);
                    final Color textColor = isSelected
                        ? lottoBallTextColor(number)
                        : Theme.of(context).colorScheme.onSurface;
                    return GestureDetector(
                      onTap: () => _toggleNumber(number, !isSelected),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        decoration: BoxDecoration(
                          color: isSelected ? ballColor : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected
                                ? ballColor
                                : Theme.of(context).colorScheme.outlineVariant,
                            width: 1.5,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          number.toString(),
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    final List<int> result = _selected.toList()..sort();
                    Navigator.of(context).pop(result);
                  },
                  child: const Text('적용'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
