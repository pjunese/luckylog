import 'package:flutter/material.dart';
import '../models/purchase_calendar.dart';
import '../models/purchase_date.dart';
import '../models/purchase_insights.dart';
import '../models/purchase_record.dart';
import '../models/scanned_ticket.dart';
import '../services/purchase_insights_controller.dart';
import '../services/share_service.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/monthly_record_card.dart';
import '../widgets/purchase_number_ball.dart';
import '../widgets/result_share_card.dart';
import 'calendar_purchase_entry_page.dart';
import 'qr_scan_page.dart';

class PurchaseCalendarTab extends StatefulWidget {
  const PurchaseCalendarTab({super.key, required this.controller, this.now});
  final PurchaseInsightsController controller;
  final DateTime? now;
  @override
  State<PurchaseCalendarTab> createState() => _PurchaseCalendarTabState();
}

class _PurchaseCalendarTabState extends State<PurchaseCalendarTab> {
  late DateTime _day = koreanCalendarDay(widget.now);
  bool _busy = false;
  void _select(DateTime date) => setState(() => _day = date);
  Future<void> _add() async {
    if (_busy || !widget.controller.isActive) return;
    final selected = _day;
    setState(() => _busy = true);
    try {
      final mode = await showModalBottomSheet<String>(
        context: context,
        useSafeArea: true,
        builder: (context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                '${selected.month}월 ${selected.day}일 구매 등록',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('QR로 등록'),
              onTap: () => Navigator.pop(context, 'qr'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('번호 직접 입력'),
              onTap: () => Navigator.pop(context, 'manual'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      );
      if (!mounted || !widget.controller.isActive) return;
      if (mode == 'manual') {
        final added = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => CalendarPurchaseEntryPage(
              day: selected,
              controller: widget.controller,
            ),
          ),
        );
        if (added == true && mounted) {
          showAppSnackBar(
            context,
            content: const Text('선택한 날짜에 구매내역을 등록했습니다.'),
          );
        }
      } else if (mode == 'qr') {
        final known = await widget.controller.database.getKnownQrFingerprints();
        if (!mounted || !widget.controller.isActive) return;
        QrBatchSaveResult? saved;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => QRScanPage(
              knownFingerprints: known,
              onSave: (tickets) async {
                if (tickets.any(
                  (t) => DateTime.utc(
                    2002,
                    12,
                    7,
                  ).add(Duration(days: (t.round - 1) * 7)).isBefore(selected),
                )) {
                  if (mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('구매일을 확인해주세요'),
                        content: const Text(
                          '선택한 구매일보다 먼저 추첨된 복권이 있습니다. 달력에서 실제 구매한 날짜를 선택해 등록해주세요.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('확인'),
                          ),
                        ],
                      ),
                    );
                  }
                  throw ArgumentError('purchase date after draw');
                }
                saved = await widget.controller.addQrPurchases(
                  tickets,
                  selected,
                );
              },
            ),
          ),
        );
        if (mounted && saved != null) {
          showAppSnackBar(
            context,
            content: Text(
              '${saved!.insertedCount}장 등록 완료${saved!.duplicateCount > 0 ? ' · 중복 ${saved!.duplicateCount}장 제외' : ''}${saved!.deletedCount > 0 ? ' · 삭제된 내역은 휴지통에서 복원해주세요' : ''}',
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          content: const Text('등록 화면을 열지 못했어요. 다시 시도해주세요.'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editDate(PurchaseRecord record) async {
    if (_busy || !widget.controller.isActive) return;
    final today = koreanCalendarDay(widget.now);
    final draw = PurchaseInsights.drawDay(record);
    final last = today.isBefore(draw) ? today : draw;
    final original = calendarPurchaseDay(record);
    final initial = original.isAfter(last)
        ? last
        : original.isBefore(DateTime.utc(2002, 12, 2))
        ? DateTime.utc(2002, 12, 2)
        : original;
    final picked = await showDatePicker(
      context: context,
      helpText: '실제 구매일 선택',
      initialDate: initial,
      firstDate: DateTime(2002, 12, 2),
      lastDate: DateTime(last.year, last.month, last.day),
    );
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    final date = DateTime.utc(picked.year, picked.month, picked.day);
    try {
      await widget.controller.changePurchaseDate(record.id, date);
      if (mounted) {
        setState(() => _day = date);
        showAppSnackBar(context, content: const Text('구매일을 수정했습니다.'));
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          content: const Text('구매일을 저장하지 못했어요. 다시 시도해주세요.'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(InsightGame game) async {
    if (_busy || game.amount == null || !widget.controller.isActive) return;
    final draw = widget.controller.value.draws[game.record.round];
    if (draw == null) return;
    setState(() => _busy = true);
    try {
      final ok = await ShareService.shareWidget(
        widget: ResultShareCard(
          round: game.record.round,
          numbers: game.numbers,
          winningNumbers: draw.winningNumbers,
          bonusNumber: draw.bonusNumber,
          rankLabel: game.result!.rankLabel,
          amount: game.amount!,
          drawDate: purchaseDateKey(PurchaseInsights.drawDay(game.record)),
        ),
        size: const Size(340, 300),
        fileName: 'luckylog_${game.record.round}회',
      );
      if (!ok && mounted) {
        showAppSnackBar(context, content: const Text('공유하지 못했어요. 다시 시도해주세요.'));
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, content: const Text('공유하지 못했어요. 다시 시도해주세요.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      if (c.loading) return const Center(child: CircularProgressIndicator());
      if (c.failed) {
        return Center(
          child: TextButton(
            onPressed: () => c.refresh(retryPrizes: true),
            child: const Text('달력 다시 불러오기'),
          ),
        );
      }
      return PurchaseCalendarView(
        insights: c.value,
        selected: _day,
        today: koreanCalendarDay(widget.now),
        onSelect: _select,
        onAdd: _busy ? null : _add,
        onEditDate: _busy ? null : _editDate,
        onShare: _busy ? null : _share,
        onRefresh: () => c.refresh(retryPrizes: true),
      );
    },
  );
}

class PurchaseCalendarView extends StatelessWidget {
  const PurchaseCalendarView({
    super.key,
    required this.insights,
    required this.selected,
    required this.today,
    required this.onSelect,
    required this.onAdd,
    required this.onEditDate,
    required this.onShare,
    required this.onRefresh,
  });
  final PurchaseInsights insights;
  final DateTime selected;
  final DateTime today;
  final ValueChanged<DateTime> onSelect;
  final VoidCallback? onAdd;
  final Future<void> Function(PurchaseRecord)? onEditDate;
  final Future<void> Function(InsightGame)? onShare;
  final Future<void> Function() onRefresh;
  Future<void> _chooseMonth(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      helpText: '보고 싶은 날짜 선택',
      initialDate:
          DateTime(
            selected.year,
            selected.month,
            selected.day,
          ).isAfter(DateTime(today.year, today.month, today.day))
          ? DateTime(today.year, today.month, today.day)
          : DateTime(
              selected.year,
              selected.month,
              selected.day,
            ).isBefore(DateTime(2002, 12, 2))
          ? DateTime(2002, 12, 2)
          : DateTime(selected.year, selected.month, selected.day),
      firstDate: DateTime(2002, 12, 2),
      lastDate: DateTime(today.year, today.month, today.day),
    );
    if (picked != null) {
      onSelect(DateTime.utc(picked.year, picked.month, picked.day));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final month = CalendarMonthSummary(insights: insights, month: selected);
    final day = month.day(selected);
    final first = month.period.start;
    final next = DateTime.utc(first.year, first.month + 1);
    final offset = first.weekday % 7;
    final days = next.subtract(const Duration(days: 1)).day;
    final count = ((offset + days) / 7).ceil() * 7;
    final purchaseColor = cs.primary;
    final winColor = theme.brightness == Brightness.dark
        ? const Color(0xFFFFD180)
        : const Color(0xFF8D4D00);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '이전 달',
                onPressed: first.isAfter(DateTime.utc(2002, 12))
                    ? () =>
                          onSelect(DateTime.utc(first.year, first.month - 1, 1))
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () => _chooseMonth(context),
                  child: Text(
                    '${first.year}년 ${first.month}월',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '다음 달',
                onPressed: next.isAfter(today) ? null : () => onSelect(next),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: InsightMetric(
                        label: '구매금액',
                        value: insightWon(month.spent),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InsightMetric(
                        label: '당첨금 · 세전',
                        value: month.prizeText,
                        highlight: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${month.records.length}장 · ${month.games.length}게임 · 당첨 ${month.winCount}게임',
                  style: theme.textTheme.bodySmall,
                ),
                if (month.unknownPrizeCount > 0)
                  Text(
                    '당첨금 확인 중 ${month.unknownPrizeCount}게임',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          Row(
            children: [
              for (final text in ['일', '월', '화', '수', '목', '금', '토'])
                Expanded(
                  child: Center(
                    child: Text(
                      text,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, box) {
              final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: count,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 3,
                  crossAxisSpacing: 2,
                  mainAxisExtent: 68 * scale.clamp(1.0, double.infinity),
                ),
                itemBuilder: (context, index) {
                  final number = index - offset + 1;
                  if (number < 1 || number > days) {
                    return const SizedBox.shrink();
                  }
                  final date = DateTime.utc(first.year, first.month, number);
                  final entry = month.day(date);
                  final chosen = date == selected;
                  final future = date.isAfter(today);
                  return Semantics(
                    button: true,
                    selected: chosen,
                    label:
                        '${date.month}월 $number일, 구매 ${insightWon(entry.spent)}, 당첨 ${entry.wins.length}게임',
                    excludeSemantics: true,
                    child: InkWell(
                      key: ValueKey('calendar-day-${purchaseDateKey(date)}'),
                      onTap: () => onSelect(date),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        decoration: BoxDecoration(
                          color: chosen ? cs.primaryContainer : null,
                          borderRadius: BorderRadius.circular(10),
                          border: date == today
                              ? Border.all(
                                  color: cs.primary.withValues(alpha: 0.5),
                                )
                              : null,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          children: [
                            Text(
                              '$number',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: chosen
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: future
                                    ? cs.onSurfaceVariant.withValues(
                                        alpha: 0.45,
                                      )
                                    : cs.onSurface,
                              ),
                            ),
                            if (entry.spent > 0)
                              Text(
                                '${entry.spent ~/ 1000}천',
                                maxLines: 1,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: purchaseColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (entry.wins.isNotEmpty)
                              Text(
                                '★${entry.wins.length}',
                                maxLines: 1,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: winColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      '구매금액',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: purchaseColor,
                      ),
                    ),
                    Text(
                      '★ 당첨 게임',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: winColor,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => onSelect(today),
                child: const Text('오늘'),
              ),
            ],
          ),
          Text(
            '구매는 구매일 · 당첨은 추첨일 기준\n구매일을 지정하지 않은 내역은 등록일로 표시합니다.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${selected.month}월 ${selected.day}일',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: selected.isAfter(today) ? null : onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('구매 등록'),
              ),
            ],
          ),
          if (day.purchases.isEmpty && day.wins.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                '이날의 기록이 없어요.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          for (final record in day.purchases)
            _PurchaseDayCard(
              record: record,
              insights: insights,
              onEditDate: onEditDate,
            ),
          for (final win in day.wins)
            Card.filled(
              margin: const EdgeInsets.only(top: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${win.record.round}회 · ${win.result!.rankLabel}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      win.amount == null ? '당첨금 확인 중' : insightWon(win.amount!),
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _CalendarBalls(game: win, insights: insights),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: win.amount == null || onShare == null
                            ? null
                            : () => onShare!(win),
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: const Text('당첨 공유'),
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
}

class _PurchaseDayCard extends StatelessWidget {
  const _PurchaseDayCard({
    required this.record,
    required this.insights,
    required this.onEditDate,
  });
  final PurchaseRecord record;
  final PurchaseInsights insights;
  final Future<void> Function(PurchaseRecord)? onEditDate;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 8),
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: ExpansionTile(
      key: PageStorageKey(
        'calendar-purchase-${record.id}-${purchaseDateKey(calendarPurchaseDay(record))}',
      ),
      title: Text(
        '${record.round}회 · ${insightWon(record.games.length * 1000)}',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        '${record.source == 'qr' ? 'QR' : '직접입력'} · ${record.games.length}게임${record.purchaseDate == null ? ' · 등록일 기준' : ''}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        for (final game in insights.games.where(
          (g) => g.record.id == record.id,
        ))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _CalendarBalls(game: game, insights: insights),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: onEditDate == null ? null : () => onEditDate!(record),
            icon: const Icon(Icons.edit_calendar, size: 18),
            label: const Text('구매일 수정'),
          ),
        ),
      ],
    ),
  );
}

class _CalendarBalls extends StatelessWidget {
  const _CalendarBalls({required this.game, required this.insights});
  final InsightGame game;
  final PurchaseInsights insights;
  @override
  Widget build(BuildContext context) {
    final draw = insights.draws[game.record.round];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final n in game.numbers)
          PurchaseNumberBall(
            number: n,
            matched: game.result != null && draw!.winningNumbers.contains(n),
            bonus: game.result != null && draw!.bonusNumber == n,
            pending: game.result == null,
          ),
      ],
    );
  }
}
