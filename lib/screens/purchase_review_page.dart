import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../widgets/purchase_number_ball.dart';
import '../models/draw_result.dart';
import '../models/purchase_record.dart';
import '../models/purchase_summary.dart';

/// Explicitly reviewing a loaded result is separate from opening this page.
class PurchaseReviewPage extends StatefulWidget {
  const PurchaseReviewPage({
    super.key,
    required this.round,
    required this.records,
    required this.draws,
    required this.onMarkChecked,
    this.knownLatestRound,
    this.now,
  });

  final int round;
  final List<PurchaseRecord> records;
  final Map<int, DrawResult> draws;
  final Future<void> Function(List<int>) onMarkChecked;
  final int? knownLatestRound;
  final DateTime? now;

  @override
  State<PurchaseReviewPage> createState() => _PurchaseReviewPageState();
}

class _PurchaseReviewPageState extends State<PurchaseReviewPage> {
  final Set<int> _confirmedIds = {};
  bool _saving = false;
  String? _error;

  PurchaseSummary get _summary => PurchaseSummary.forRound(
    round: widget.round,
    records: widget.records,
    draws: widget.draws,
    knownLatestRound: widget.knownLatestRound,
    now: widget.now,
  );

  @override
  void didUpdateWidget(PurchaseReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.round != widget.round) {
      _confirmedIds.clear();
      _error = null;
    }
    _confirmedIds.removeWhere(
      (id) => !widget.records.any((record) => record.id == id),
    );
  }

  Future<void> _markChecked() async {
    if (_saving) return;
    final round = widget.round;
    final ids = _summary.uncheckedIds
        .where((id) => !_confirmedIds.contains(id))
        .toList(growable: false);
    if (ids.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onMarkChecked(List.unmodifiable(ids));
      if (!mounted) return;
      if (widget.round == round) setState(() => _confirmedIds.addAll(ids));
    } catch (_) {
      if (mounted && widget.round == round) {
        setState(() => _error = '확인 상태를 저장하지 못했어요. 다시 눌러주세요.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final draw = summary.draw;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final unchecked = summary.uncheckedIds
        .where((id) => !_confirmedIds.contains(id))
        .length;
    return Scaffold(
      appBar: AppBar(title: Text('제${widget.round}회 구매 결과')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            Text(
              '${summary.ticketCount}장 · ${summary.gameCount}게임',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            if (summary.ticketCount == 0)
              const _Notice(
                icon: Icons.receipt_long_outlined,
                title: '이 회차에 등록한 복권이 없어요.',
                body: '구매내역에서 다른 회차를 선택하거나 복권을 등록해주세요.',
              )
            else if (draw == null)
              _Notice(
                icon: Icons.schedule,
                title: summary.delayedResultCount > 0 ? '결과 업데이트 대기' : '추첨 대기',
                body: summary.delayedResultCount > 0
                    ? '아직 이 회차의 당첨번호를 불러오지 못했어요. 연결 후 다시 확인해주세요.'
                    : '당첨번호가 등록되면 구매한 번호와 비교할 수 있어요.',
              ),
            if (draw != null) ...[
              Card.filled(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '당첨번호',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (draw.drawDate.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          draw.drawDate,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final number in draw.winningNumbers)
                            _Number(number: number, matched: true),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '+',
                                semanticsLabel: '보너스 번호',
                                style: theme.textTheme.titleMedium,
                              ),
                              const SizedBox(width: 8),
                              _Number(number: draw.bonusNumber, bonus: true),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '번호를 살펴본 뒤 아래 버튼을 누르면 확인 완료로 표시돼요.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            for (final record in summary.records) ...[
              _PurchaseTicket(
                record: record,
                draw: draw,
                status: draw != null && _confirmedIds.contains(record.id)
                    ? PurchaseReviewStatus.checked
                    : summary.statuses[record.id]!,
              ),
              const SizedBox(height: 12),
            ],
            if (_error != null) ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.error,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (draw != null && summary.ticketCount > 0)
              if (unchecked > 0)
                FilledButton.icon(
                  key: const Key('mark-purchase-results-checked'),
                  onPressed: _saving ? null : _markChecked,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline),
                  label: Text(
                    _saving ? '확인 상태 저장 중' : '결과 확인 완료 ($unchecked장)',
                  ),
                )
              else
                Semantics(
                  liveRegion: true,
                  child: const _Notice(
                    icon: Icons.check_circle_outline,
                    title: '이 회차의 결과를 모두 확인했어요.',
                    body: '구매내역에서 언제든 다시 볼 수 있어요.',
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _PurchaseTicket extends StatelessWidget {
  const _PurchaseTicket({
    required this.record,
    required this.draw,
    required this.status,
  });
  final PurchaseRecord record;
  final DrawResult? draw;
  final PurchaseReviewStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                Text(
                  record.source == 'qr' ? 'QR 등록 복권' : '직접 등록 복권',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  status.label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: status == PurchaseReviewStatus.unchecked
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              formatDateTime(record.createdAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            for (final entry in record.games.asMap().entries) ...[
              const SizedBox(height: 16),
              _GameNumbers(index: entry.key, numbers: entry.value, draw: draw),
            ],
          ],
        ),
      ),
    );
  }
}

class _GameNumbers extends StatelessWidget {
  const _GameNumbers({
    required this.index,
    required this.numbers,
    required this.draw,
  });
  final int index;
  final List<int> numbers;
  final DrawResult? draw;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = PurchaseGameResult.evaluate(numbers, draw);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            Text('${index + 1}게임', style: theme.textTheme.labelLarge),
            if (result != null) ...[
              Text(
                result.rankLabel,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: result.rank > 0
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(result.matchLabel, style: theme.textTheme.bodySmall),
            ] else if (!isLottoGame(numbers))
              const Text('번호 정보 확인 필요'),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final number in numbers)
              _Number(
                number: number,
                matched: draw?.winningNumbers.contains(number) ?? false,
                bonus: draw?.bonusNumber == number,
                pending: draw == null,
              ),
          ],
        ),
      ],
    );
  }
}

class _Number extends StatelessWidget {
  const _Number({
    required this.number,
    this.matched = false,
    this.bonus = false,
    this.pending = false,
  });
  final int number;
  final bool matched;
  final bool bonus;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    return PurchaseNumberBall(
      number: number,
      matched: matched,
      bonus: bonus,
      pending: pending,
      size: 36,
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 8),
      Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 6),
      Text(
        body,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}
