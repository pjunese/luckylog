import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/lotto_palette.dart';
import '../db/lotto_database.dart';
import '../models/draw_result.dart';
import '../models/number_set.dart';
import '../models/purchase_record.dart';
import 'draw_history_tab.dart';
import '../widgets/mini_lotto_ball.dart';
import '../widgets/number_picker_sheet.dart';

class NumberSetVaultTab extends StatefulWidget {
  const NumberSetVaultTab({
    super.key,
    required this.savedSets,
    required this.purchaseHistory,
    required this.onSaveSet,
    required this.onDeleteSet,
    required this.onTogglePurchased,
    required this.onAddPurchaseHistory,
    required this.onDeletePurchaseHistory,
  });

  final List<NumberSet> savedSets;
  final List<PurchaseRecord> purchaseHistory;
  final Future<void> Function(List<List<int>>) onSaveSet;
  final Future<void> Function(int) onDeleteSet;
  final Future<void> Function(int, bool) onTogglePurchased;
  final Future<void> Function(List<List<int>>, int, String)
  onAddPurchaseHistory;
  final Future<void> Function(int) onDeletePurchaseHistory;

  @override
  State<NumberSetVaultTab> createState() => NumberSetVaultTabState();
}

class NumberSetVaultTabState extends State<NumberSetVaultTab>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;
  static const int _maxGames = 5;
  static const int _numbersPerGame = 6;
  int _gameCount = 1;
  final List<List<int>> _selectedNumbers = List<List<int>>.generate(
    _maxGames,
    (_) => <int>[],
  );

  // round → DrawResult 캐시 (구매내역 당첨결과 표시용)
  final Map<int, DrawResult> _drawCache = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController!.addListener(() {
      FocusManager.instance.primaryFocus?.unfocus();
    });
    _loadDrawCache();
  }

  @override
  void didUpdateWidget(NumberSetVaultTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 구매내역이 변경되면 새 회차 캐시 로드
    if (oldWidget.purchaseHistory != widget.purchaseHistory) {
      _loadDrawCache();
    }
  }

  void jumpToTab(int index) {
    _tabController?.animateTo(index);
  }

  Future<void> _loadDrawCache() async {
    final rounds = widget.purchaseHistory.map((r) => r.round).toSet();
    for (final round in rounds) {
      if (_drawCache.containsKey(round)) continue;
      final row = await LottoDatabase.instance.getDrawResult(round);
      if (row != null && mounted) {
        setState(() {
          _drawCache[round] = DrawResult(
            round: round,
            winningNumbers: [
              row['num1'] as int,
              row['num2'] as int,
              row['num3'] as int,
              row['num4'] as int,
              row['num5'] as int,
              row['num6'] as int,
            ],
            bonusNumber: row['bonus'] as int,
            drawDate: '',
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  void _changeGameCount(int gameCount) =>
      setState(() => _gameCount = gameCount);

  Future<void> _openNumberPicker(int gameIndex) async {
    final List<int>? picked = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.86,
        child: NumberPickerSheet(
          gameIndex: gameIndex,
          initialSelection: _selectedNumbers[gameIndex],
          maxSelection: _numbersPerGame,
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _selectedNumbers[gameIndex] = picked..sort());
  }

  void _clearAll() {
    setState(() {
      for (int i = 0; i < _maxGames; i++) {
        _selectedNumbers[i] = <int>[];
      }
      _gameCount = 1;
    });
  }

  Future<void> _saveNumberSet() async {
    for (int i = 0; i < _gameCount; i++) {
      if (_selectedNumbers[i].length != _numbersPerGame) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${i + 1}게임 번호를 6개 선택해 주세요.')));
        return;
      }
    }
    final List<List<int>> games = List<List<int>>.generate(
      _gameCount,
      (i) => List<int>.from(_selectedNumbers[i])..sort(),
    );
    await widget.onSaveSet(games);
    _clearAll();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${games.length}게임 번호세트를 저장했습니다.')),
      );
    }
  }

  Future<int?> _showRoundPicker() async {
    final int latestRound = await LottoDatabase.instance.getLatestRound();
    if (!mounted) return null;
    // 미래 2회차까지 선택 가능 (이번 주/다음 주 구매 대비)
    const int futureRounds = 2;
    final int maxRound = latestRound + futureRounds;
    int selectedRound = latestRound + 1; // 기본값: 다가오는 회차
    return showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SizedBox(
        height: 320,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Text(
                    '구매 회차 선택',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('취소'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, selectedRound),
                    child: const Text(
                      '확인',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: CupertinoPicker(
                scrollController: FixedExtentScrollController(initialItem: 0),
                itemExtent: 44,
                onSelectedItemChanged: (i) => selectedRound = maxRound - i,
                children: List.generate((maxRound).clamp(1, 200), (i) {
                  final int r = maxRound - i;
                  final bool isFuture = r > latestRound;
                  return Center(
                    child: Text(
                      '$r회  ·  ${LottoDatabase.drawDateFromRound(r)}${isFuture ? '  🎯' : ''}',
                      style: TextStyle(
                        fontSize: 15,
                        color: isFuture ? const Color(0xFF2A75F3) : null,
                        fontWeight: isFuture
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleTogglePurchased(NumberSet set, bool value) async {
    if (!value) {
      await widget.onTogglePurchased(set.id, false);
      return;
    }
    final int? round = await _showRoundPicker();
    if (round == null || !mounted) return;
    await widget.onTogglePurchased(set.id, true);
    await widget.onAddPurchaseHistory(set.games, round, 'manual');
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('구매내역에 저장됐습니다.')));
      _tabController?.animateTo(1);
    }
  }

  Future<void> _addManualPurchase() async {
    final List<List<int>>? games = await showModalBottomSheet<List<List<int>>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.92,
        child: _ManualPurchaseNumberSheet(
          maxGames: _maxGames,
          numbersPerGame: _numbersPerGame,
        ),
      ),
    );
    if (games == null || !mounted) return;
    final int? round = await _showRoundPicker();
    if (round == null || !mounted) return;
    await widget.onAddPurchaseHistory(games, round, 'manual');
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('구매내역에 저장됐습니다.')));
    }
  }

  Future<void> _addFromSavedSets() async {
    final List<List<int>>? selected =
        await showModalBottomSheet<List<List<int>>>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => FractionallySizedBox(
            heightFactor: 0.85,
            child: _SelectFromSavedSetsSheet(
              savedSets: widget.savedSets,
              maxGames: _maxGames,
            ),
          ),
        );
    if (selected == null || selected.isEmpty || !mounted) return;
    final int? round = await _showRoundPicker();
    if (round == null || !mounted) return;
    await widget.onAddPurchaseHistory(selected, round, 'manual');
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('구매내역에 저장됐습니다.')));
    }
  }

  /// 게임 번호 + 당첨결과로 등수 문자열 반환. 낙첨이면 null.
  String? _calcPrize(List<int> game, DrawResult draw) {
    final matched = game.where((n) => draw.winningNumbers.contains(n)).length;
    final hasBonus = game.contains(draw.bonusNumber);
    if (matched == 6) return '1등';
    if (matched == 5 && hasBonus) return '2등';
    if (matched == 5) return '3등';
    if (matched == 4) return '4등';
    if (matched == 3) return '5등';
    return null; // 낙첨
  }

  Color _prizeBadgeColor(String prize) {
    switch (prize) {
      case '1등':
        return const Color(0xFFE53935);
      case '2등':
        return const Color(0xFFE67E22);
      case '3등':
        return const Color(0xFF8E24AA);
      case '4등':
        return const Color(0xFF1E88E5);
      case '5등':
        return const Color(0xFF43A047);
      default:
        return Colors.grey;
    }
  }

  Future<void> _confirmDeleteHistory(int id) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('구매내역 삭제'),
        content: const Text('이 구매내역을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.onDeletePurchaseHistory(id);
  }

  @override
  Widget build(BuildContext context) {
    if (_tabController == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            controller: _tabController!,
            isScrollable: true,
            tabs: [
              Tab(
                child: Text('내 번호 (${widget.savedSets.length})', maxLines: 1),
              ),
              Tab(
                child: Text(
                  '구매내역 (${widget.purchaseHistory.length})',
                  maxLines: 1,
                ),
              ),
              const Tab(child: Text('당첨결과', maxLines: 1)),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController!,
            children: [
              _buildMyNumbers(),
              _buildPurchaseHistory(),
              const DrawHistoryTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMyNumbers() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '번호세트 만들기',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 8),
                Text('번호를 미리 저장하고 구매완료 시 구매내역으로 이동할 수 있습니다.'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '게임 수',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: List<ButtonSegment<int>>.generate(
                    _maxGames,
                    (i) => ButtonSegment<int>(
                      value: i + 1,
                      label: Text(
                        '${i + 1}게임',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                      ),
                    ),
                  ),
                  selected: <int>{_gameCount},
                  onSelectionChanged: (Set<int> s) => _changeGameCount(s.first),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        ...List<Widget>.generate(_gameCount, (index) {
          final List<int> numbers = List<int>.from(_selectedNumbers[index])
            ..sort();
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${index + 1}게임',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        FilledButton.tonalIcon(
                          onPressed: () => _openNumberPicker(index),
                          icon: const Icon(Icons.format_list_numbered),
                          label: const Text('번호 선택'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (numbers.isEmpty)
                      Text(
                        '아직 선택된 번호가 없습니다.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: numbers
                            .map(
                              (n) => CircleAvatar(
                                radius: 16,
                                backgroundColor: lottoBallColor(n),
                                child: Text(
                                  '$n',
                                  style: TextStyle(
                                    color: lottoBallTextColor(n),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: numbers.length / _numbersPerGame,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    const SizedBox(height: 6),
                    Text('${numbers.length}/$_numbersPerGame 선택 완료'),
                  ],
                ),
              ),
            ),
          );
        }),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _clearAll,
                icon: const Icon(Icons.refresh),
                label: const Text('초기화'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _saveNumberSet,
                icon: const Icon(Icons.save_outlined),
                label: const Text('세트 저장'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          '보관함 (${widget.savedSets.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (widget.savedSets.isEmpty)
          const _FeatureCard(
            title: '보관함이 비어 있습니다',
            description: '번호세트를 저장하면 구매완료 토글로 구매내역 연동이 가능합니다.',
            icon: Icons.inbox_outlined,
          )
        else
          ...widget.savedSets.asMap().entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '번호세트 #${entry.key + 1}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: () => widget.onDeleteSet(entry.value.id),
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '삭제',
                          ),
                        ],
                      ),
                      Text(
                        '생성: ${formatDateTime(entry.value.createdAt)} · ${entry.value.games.length}게임',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...entry.value.games.asMap().entries.map(
                        (g) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              Text('${g.key + 1}게임'),
                              ...g.value.map(
                                (n) => CircleAvatar(
                                  radius: 12,
                                  backgroundColor: lottoBallColor(n),
                                  child: Text(
                                    '$n',
                                    style: TextStyle(
                                      color: lottoBallTextColor(n),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('구매 완료'),
                        subtitle: const Text('켜면 회차를 선택 후 구매내역으로 이동합니다.'),
                        value: entry.value.isPurchased,
                        onChanged: (v) =>
                            _handleTogglePurchased(entry.value, v),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPurchaseHistory() {
    return Stack(
      children: [
        widget.purchaseHistory.isEmpty
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      size: 56,
                      color: Colors.grey,
                    ),
                    SizedBox(height: 12),
                    Text(
                      '구매내역이 없습니다',
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'QR 스캔이나 직접 추가로 저장하세요.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
                itemCount: widget.purchaseHistory.length,
                itemBuilder: (ctx, index) {
                  final PurchaseRecord record =
                      widget.purchaseHistory[widget.purchaseHistory.length -
                          1 -
                          index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '${record.round}회',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  record.drawDate,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                    fontSize: 13,
                                  ),
                                ),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: record.source == 'qr'
                                        ? Colors.blue.shade50
                                        : Colors.green.shade50,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    record.source == 'qr' ? 'QR' : '직접입력',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: record.source == 'qr'
                                          ? Colors.blue.shade700
                                          : Colors.green.shade700,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () =>
                                      _confirmDeleteHistory(record.id),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                  ),
                                  tooltip: '삭제',
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ...record.games.asMap().entries.map((g) {
                              final draw = _drawCache[record.round];
                              final prize = draw != null
                                  ? _calcPrize(g.value, draw)
                                  : null;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 42,
                                      child: Text(
                                        '${g.key + 1}게임',
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Wrap(
                                        spacing: 5,
                                        runSpacing: 4,
                                        children: g.value.map((n) {
                                          final hit =
                                              draw != null &&
                                              draw.winningNumbers.contains(n);
                                          final bonus =
                                              draw != null &&
                                              n == draw.bonusNumber;
                                          return Container(
                                            width: 26,
                                            height: 26,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: hit || bonus
                                                  ? lottoBallColor(n)
                                                  : lottoBallColor(
                                                      n,
                                                    ).withValues(alpha: 0.25),
                                              border: bonus
                                                  ? Border.all(
                                                      color: Colors.orange,
                                                      width: 2,
                                                    )
                                                  : null,
                                            ),
                                            child: Center(
                                              child: Text(
                                                '$n',
                                                style: TextStyle(
                                                  color: hit || bonus
                                                      ? lottoBallTextColor(n)
                                                      : Colors.grey.shade500,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                    if (prize != null)
                                      Container(
                                        margin: const EdgeInsets.only(left: 6),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: _prizeBadgeColor(prize),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: Text(
                                          prize,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      )
                                    else if (draw == null)
                                      const SizedBox(width: 0),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
        Positioned(
          bottom: 16,
          right: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.extended(
                heroTag: 'addFromSets',
                onPressed: widget.savedSets.isEmpty ? null : _addFromSavedSets,
                icon: const Icon(Icons.playlist_add),
                label: const Text('내 번호에서 선택'),
                backgroundColor: widget.savedSets.isEmpty ? Colors.grey : null,
              ),
              const SizedBox(height: 10),
              FloatingActionButton.extended(
                heroTag: 'addPurchase',
                onPressed: _addManualPurchase,
                icon: const Icon(Icons.edit),
                label: const Text('직접 입력'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ManualPurchaseNumberSheet extends StatefulWidget {
  const _ManualPurchaseNumberSheet({
    required this.maxGames,
    required this.numbersPerGame,
  });

  final int maxGames;
  final int numbersPerGame;

  @override
  State<_ManualPurchaseNumberSheet> createState() =>
      _ManualPurchaseNumberSheetState();
}

class _ManualPurchaseNumberSheetState
    extends State<_ManualPurchaseNumberSheet> {
  int _gameCount = 1;
  late final List<List<int>> _selectedNumbers;

  @override
  void initState() {
    super.initState();
    _selectedNumbers = List<List<int>>.generate(
      widget.maxGames,
      (_) => <int>[],
    );
  }

  Future<void> _openPicker(int index) async {
    final List<int>? picked = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.86,
        child: NumberPickerSheet(
          gameIndex: index,
          initialSelection: _selectedNumbers[index],
          maxSelection: widget.numbersPerGame,
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _selectedNumbers[index] = picked..sort());
  }

  void _confirm() {
    for (int i = 0; i < _gameCount; i++) {
      if (_selectedNumbers[i].length != widget.numbersPerGame) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${i + 1}게임 번호를 ${widget.numbersPerGame}개 선택해 주세요.'),
          ),
        );
        return;
      }
    }
    final List<List<int>> games = List<List<int>>.generate(
      _gameCount,
      (i) => List<int>.from(_selectedNumbers[i])..sort(),
    );
    Navigator.of(context).pop(games);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '번호 직접 입력',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: List<ButtonSegment<int>>.generate(
              widget.maxGames,
              (i) => ButtonSegment<int>(
                value: i + 1,
                label: Text(
                  '${i + 1}게임',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                ),
              ),
            ),
            selected: <int>{_gameCount},
            onSelectionChanged: (Set<int> s) =>
                setState(() => _gameCount = s.first),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: List<Widget>.generate(_gameCount, (index) {
                final List<int> nums = List<int>.from(_selectedNumbers[index])
                  ..sort();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      title: Text('${index + 1}게임'),
                      subtitle: nums.isEmpty
                          ? Text(
                              '번호를 선택하세요',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: nums
                                    .map(
                                      (n) => CircleAvatar(
                                        radius: 13,
                                        backgroundColor: lottoBallColor(n),
                                        child: Text(
                                          '$n',
                                          style: TextStyle(
                                            color: lottoBallTextColor(n),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                      trailing: FilledButton.tonal(
                        onPressed: () => _openPicker(index),
                        child: const Text('선택'),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _confirm,
              child: const Text('다음: 회차 선택'),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// 저장된 번호세트에서 선택해 구매내역 추가
// ─────────────────────────────────────────
class _SelectFromSavedSetsSheet extends StatefulWidget {
  const _SelectFromSavedSetsSheet({
    required this.savedSets,
    required this.maxGames,
  });
  final List<NumberSet> savedSets;
  final int maxGames;

  @override
  State<_SelectFromSavedSetsSheet> createState() =>
      _SelectFromSavedSetsSheetState();
}

class _SelectFromSavedSetsSheetState extends State<_SelectFromSavedSetsSheet> {
  // 선택된 게임들: (setIndex, gameIndex) → List<int>
  final List<List<int>> _selectedGames = [];

  bool _isSelected(int setIdx, int gameIdx) {
    final List<int> game = widget.savedSets[setIdx].games[gameIdx];
    return _selectedGames.any((g) => _listEquals(g, game));
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _toggleGame(int setIdx, int gameIdx) {
    final List<int> game = List<int>.from(
      widget.savedSets[setIdx].games[gameIdx],
    );
    final int existing = _selectedGames.indexWhere((g) => _listEquals(g, game));
    setState(() {
      if (existing >= 0) {
        _selectedGames.removeAt(existing);
      } else if (_selectedGames.length < widget.maxGames) {
        _selectedGames.add(game);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '내 번호에서 선택',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${_selectedGames.length}/${widget.maxGames}게임 선택됨',
                      style: TextStyle(
                        fontSize: 13,
                        color: _selectedGames.isEmpty
                            ? Colors.grey
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: _selectedGames.isEmpty
                    ? null
                    : () => Navigator.pop(context, _selectedGames),
                child: const Text(
                  '확인',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: widget.savedSets.length,
            itemBuilder: (context, setIdx) {
              final NumberSet set = widget.savedSets[setIdx];
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '번호세트 ${setIdx + 1}  ·  ${set.games.length}게임',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...List.generate(set.games.length, (gameIdx) {
                        final bool selected = _isSelected(setIdx, gameIdx);
                        final bool maxReached =
                            _selectedGames.length >= widget.maxGames;
                        return GestureDetector(
                          onTap: (selected || !maxReached)
                              ? () => _toggleGame(setIdx, gameIdx)
                              : null,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(10),
                              border: selected
                                  ? Border.all(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      width: 1.5,
                                    )
                                  : null,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  String.fromCharCode(65 + gameIdx),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    color: selected
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.grey,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: set.games[gameIdx]
                                        .map((n) => MiniLottoBall(number: n))
                                        .toList(),
                                  ),
                                ),
                                if (selected)
                                  Icon(
                                    Icons.check_circle,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 20,
                                  ),
                                if (!selected && maxReached)
                                  const Icon(
                                    Icons.block,
                                    color: Colors.grey,
                                    size: 20,
                                  ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.title,
    required this.description,
    required this.icon,
  });

  final String title;
  final String description;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(description),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
