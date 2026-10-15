import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/purchase_insights.dart';
import '../models/draw_result.dart';
import '../services/purchase_insights_controller.dart';
import '../services/share_service.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/monthly_record_card.dart';
import '../widgets/purchase_number_ball.dart';
import '../widgets/result_share_card.dart';

class PurchaseInsightsTab extends StatefulWidget {
  const PurchaseInsightsTab({super.key, required this.controller, this.now});
  final PurchaseInsightsController controller;
  final DateTime? now;
  @override
  State<PurchaseInsightsTab> createState() => _PurchaseInsightsTabState();
}

class _PurchaseInsightsTabState extends State<PurchaseInsightsTab> {
  InsightFrequency _frequency = InsightFrequency.month;
  late DateTime _anchor = koreanCalendarDay(widget.now);
  bool _winsOnly = false;
  final Set<String> _sharing = {};

  void _select(InsightPeriod period) => setState(() => _anchor = period.start);
  Future<void> _share(InsightGame game) async {
    final key = '${game.record.id}-${game.index}';
    final draw = widget.controller.value.draws[game.record.round];
    // An unknown variable prize must not be shared as a zero-won win.
    if (draw == null || game.amount == null || !_sharing.add(key)) return;
    setState(() {});
    try {
      final ok = await ShareService.shareWidget(
        widget: ResultShareCard(
          round: game.record.round,
          numbers: game.numbers,
          winningNumbers: draw.winningNumbers,
          bonusNumber: draw.bonusNumber,
          rankLabel: game.result!.rankLabel,
          amount: game.amount!,
          drawDate: PurchaseInsights.drawDay(
            game.record,
          ).toIso8601String().split('T').first,
        ),
        size: const Size(340, 300),
        fileName: 'luckylog_${game.record.round}회',
      );
      if (!ok && mounted) {
        showAppSnackBar(context, content: const Text('공유에 실패했어요. 다시 시도해주세요.'));
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, content: const Text('공유에 실패했어요. 다시 시도해주세요.'));
      }
    } finally {
      if (mounted) setState(() => _sharing.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      if (controller.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (controller.failed) {
        return Center(
          child: TextButton.icon(
            onPressed: () => controller.refresh(retryPrizes: true),
            icon: const Icon(Icons.refresh),
            label: const Text('기록 다시 불러오기'),
          ),
        );
      }
      return PurchaseInsightsView(
        insights: controller.value,
        frequency: _frequency,
        anchor: _anchor,
        today: koreanCalendarDay(widget.now),
        winsOnly: _winsOnly,
        onFrequencyChanged: (value) => setState(() => _frequency = value),
        onPeriodChanged: _select,
        onWinsOnlyChanged: (value) => setState(() => _winsOnly = value),
        onRefresh: () => controller.refresh(retryPrizes: true),
        onShare: _share,
        sharing: _sharing,
      );
    },
  );
}

/// Stateless view also used for deterministic accessibility and layout tests.
class PurchaseInsightsView extends StatelessWidget {
  const PurchaseInsightsView({
    super.key,
    required this.insights,
    required this.frequency,
    required this.anchor,
    required this.today,
    required this.winsOnly,
    required this.onFrequencyChanged,
    required this.onPeriodChanged,
    required this.onWinsOnlyChanged,
    required this.onRefresh,
    required this.onShare,
    this.sharing = const {},
  });
  final PurchaseInsights insights;
  final InsightFrequency frequency;
  final DateTime anchor;
  final DateTime today;
  final bool winsOnly;
  final ValueChanged<InsightFrequency> onFrequencyChanged;
  final ValueChanged<InsightPeriod> onPeriodChanged;
  final ValueChanged<bool> onWinsOnlyChanged;
  final Future<void> Function() onRefresh;
  final Future<void> Function(InsightGame) onShare;
  final Set<String> sharing;

  Future<void> _choosePeriod(
    BuildContext context,
    InsightPeriod current,
    InsightPeriod first,
    InsightPeriod last,
  ) async {
    final periods = <InsightPeriod>[];
    for (var p = last; !p.start.isBefore(first.start); p = p.shift(-1)) {
      periods.add(p);
    }
    final selected = await showModalBottomSheet<InsightPeriod>(
      context: context,
      useSafeArea: true,
      builder: (context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text('기간 선택', style: Theme.of(context).textTheme.titleLarge),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: periods.length,
              itemBuilder: (context, index) {
                final p = periods[index];
                return ListTile(
                  title: Text(p.label),
                  selected: p.key == current.key,
                  trailing: p.key == current.key
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(context, p),
                );
              },
            ),
          ),
        ],
      ),
    );
    if (selected != null) onPeriodChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final first = InsightPeriod(insights.earliestDay(today), frequency);
    final last = InsightPeriod(insights.latestDay(today), frequency);
    var period = InsightPeriod(anchor, frequency);
    if (period.start.isBefore(first.start)) period = first;
    if (period.start.isAfter(last.start)) period = last;
    final selected = period;
    final summary = insights.forPeriod(period);
    final rounds = summary.rounds
        .where(
          (r) =>
              !winsOnly ||
              summary.games.any((g) => g.record.round == r && g.isWin),
        )
        .toList();
    final trends = [
      for (var i = 5; i >= 0; i--) insights.forPeriod(period.shift(-i)),
    ];
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        key: const PageStorageKey('purchase-insights'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: 2 + (rounds.isEmpty ? 1 : rounds.length),
        itemBuilder: (context, index) {
          if (index == 1 + (rounds.isEmpty ? 1 : rounds.length)) {
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: ExpansionTile(
                key: PageStorageKey('record-trends-${frequency.name}'),
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '최근 ${frequency == InsightFrequency.month ? '6개월' : '6주'} 구매 추이',
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: const Text('기간별 구매금액 비교'),
                children: [
                  _SpendChart(
                    periods: trends,
                    selected: period,
                    first: first,
                    onSelected: onPeriodChanged,
                  ),
                ],
              ),
            );
          }
          if (index > 0) {
            if (rounds.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    Icon(
                      winsOnly
                          ? Icons.emoji_events_outlined
                          : Icons.receipt_long_outlined,
                      size: 36,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(winsOnly ? '이 기간의 당첨 기록이 없어요.' : '이 기간에 등록한 복권이 없어요.'),
                  ],
                ),
              );
            }
            final round = rounds[index - 1];
            final games = summary.games
                .where((g) => g.record.round == round && (!winsOnly || g.isWin))
                .toList();
            return _RoundRecordCard(
              key: ValueKey('${period.key}-$round-$winsOnly'),
              games: games,
              draw: insights.draws[round],
              onShare: onShare,
              sharing: sharing,
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<InsightFrequency>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: InsightFrequency.month,
                      label: Text('월별'),
                    ),
                    ButtonSegment(
                      value: InsightFrequency.week,
                      label: Text('주별'),
                    ),
                  ],
                  selected: {frequency},
                  onSelectionChanged: (v) => onFrequencyChanged(v.single),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  IconButton(
                    tooltip: '이전 기간',
                    onPressed: period.start.isAfter(first.start)
                        ? () => onPeriodChanged(selected.shift(-1))
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () =>
                          _choosePeriod(context, selected, first, last),
                      child: Text(
                        period.label,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '다음 기간',
                    onPressed: period.start.isBefore(last.start)
                        ? () => onPeriodChanged(selected.shift(1))
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              Card.filled(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: InsightMetric(
                              label: '구매금액',
                              value: insightWon(summary.spent),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: InsightMetric(
                              label: '확인된 당첨금',
                              value: summary.prizeText,
                              highlight: true,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${summary.records.length}장 · ${summary.games.length}게임 · 당첨 ${summary.winCount}게임',
                      ),
                      if (summary.pendingGames > 0 ||
                          summary.unknownPrizeCount > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          [
                            if (summary.pendingGames > 0)
                              '결과 대기 ${summary.pendingGames}게임',
                            if (summary.unknownPrizeCount > 0)
                              '당첨금 확인 중 ${summary.unknownPrizeCount}게임',
                          ].join(' · '),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '추첨일 기준 · 등록한 복권만 집계 · 당첨금 세전',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '회차별 기록',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '기록 새로고침',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                  FilterChip(
                    label: const Text('당첨만'),
                    selected: winsOnly,
                    onSelected: onWinsOnlyChanged,
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

class _SpendChart extends StatelessWidget {
  const _SpendChart({
    required this.periods,
    required this.selected,
    required this.first,
    required this.onSelected,
  });
  final List<PeriodInsight> periods;
  final InsightPeriod selected;
  final InsightPeriod first;
  final ValueChanged<InsightPeriod> onSelected;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxSpend = periods.fold<int>(1, (max, p) => math.max(max, p.spent));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final p in periods)
          Expanded(
            child: Semantics(
              button: !p.period.start.isBefore(first.start),
              selected: p.period.key == selected.key,
              label:
                  '${p.period.label}, 구매 ${insightWon(p.spent)}, 당첨 ${p.winCount}게임',
              child: InkWell(
                onTap: p.period.start.isBefore(first.start)
                    ? null
                    : () => onSelected(p.period),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Column(
                    children: [
                      Text(
                        p.spent == 0 ? '0' : '${p.spent ~/ 1000}천',
                        style: Theme.of(context).textTheme.labelSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 72,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: 26,
                            height: p.spent == 0
                                ? 3
                                : math.max(5, 72 * p.spent / maxSpend),
                            decoration: BoxDecoration(
                              color: p.period.key == selected.key
                                  ? cs.primary
                                  : cs.primary.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        p.period.shortLabel,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: p.period.key == selected.key
                              ? FontWeight.w800
                              : null,
                        ),
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
}

class _RoundRecordCard extends StatelessWidget {
  const _RoundRecordCard({
    super.key,
    required this.games,
    required this.draw,
    required this.onShare,
    required this.sharing,
  });
  final List<InsightGame> games;
  final DrawResult? draw;
  final Future<void> Function(InsightGame) onShare;
  final Set<String> sharing;
  @override
  Widget build(BuildContext context) {
    final first = games.first;
    final winCount = games.where((g) => g.isWin).length;
    final date = PurchaseInsights.drawDay(first.record);
    final pending = games.where((g) => g.result == null).length;
    final prize = games.fold<int>(0, (sum, game) => sum + (game.amount ?? 0));
    final unknownPrize = games.any((game) => game.isWin && game.amount == null);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>('insight-round-$key'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        title: Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${first.record.round}회',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (winCount > 0)
              Text(
                unknownPrize ? '당첨금 확인 중' : '${insightWon(prize)} 당첨',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        ),
        subtitle: Text(
          '${date.month}.${date.day} 추첨 · ${games.length}게임${winCount > 0 ? ' · 당첨 $winCount' : ''}${pending > 0
              ? ' · 결과 대기'
              : winCount == 0
              ? ' · 당첨 없음'
              : ''}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          for (final game in games)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${game.record.source == 'qr' ? 'QR' : '직접입력'} · ${game.index + 1}게임',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (game.result != null)
                        Text(
                          game.result!.rankLabel,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: game.isWin
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                        )
                      else
                        const Text('결과 대기'),
                      if (game.isWin)
                        Text(
                          game.amount == null
                              ? '당첨금 확인 중'
                              : insightWon(game.amount!),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final number in game.numbers)
                        PurchaseNumberBall(
                          number: number,
                          matched:
                              game.result != null &&
                              draw!.winningNumbers.contains(number),
                          bonus:
                              game.result != null &&
                              draw!.bonusNumber == number,
                          pending: game.result == null,
                        ),
                    ],
                  ),
                  if (game.isWin)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed:
                            game.amount == null ||
                                sharing.contains(
                                  '${game.record.id}-${game.index}',
                                )
                            ? null
                            : () => onShare(game),
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: const Text('당첨 공유'),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
