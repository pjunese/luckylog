import 'package:flutter/material.dart';

import '../models/purchase_summary.dart';

class PurchaseSummaryCard extends StatelessWidget {
  const PurchaseSummaryCard({
    super.key,
    required this.summary,
    required this.onOpenRecords,
    this.onAddPurchase,
    this.onRoundChanged,
    this.availableRounds = const [],
  });

  final PurchaseSummary summary;
  final VoidCallback onOpenRecords;
  final VoidCallback? onAddPurchase;
  final ValueChanged<int>? onRoundChanged;
  final List<int> availableRounds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final rounds = {
      ...availableRounds,
      summary.round,
    }.where((round) => round > 0).toList()..sort((a, b) => b.compareTo(a));
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '내 복권 한눈에',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            if (onRoundChanged != null && rounds.length > 1)
              DropdownButtonFormField<int>(
                key: ValueKey('purchase-round-${summary.round}'),
                initialValue: summary.round,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '구매 회차',
                  border: OutlineInputBorder(),
                ),
                items: rounds
                    .map(
                      (round) => DropdownMenuItem(
                        value: round,
                        child: Text('제$round회'),
                      ),
                    )
                    .toList(),
                onChanged: (round) {
                  if (round != null) onRoundChanged!(round);
                },
              )
            else
              Text(
                '제${summary.round}회',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            const SizedBox(height: 12),
            if (summary.ticketCount == 0) ...[
              Text('아직 등록한 복권이 없어요.', style: theme.textTheme.bodyLarge),
              const SizedBox(height: 6),
              Text(
                '구매한 복권을 등록하면 추첨과 결과 확인 상태를 한곳에서 볼 수 있어요.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onAddPurchase ?? onOpenRecords,
                icon: const Icon(Icons.add),
                label: const Text('구매 복권 등록'),
              ),
            ] else ...[
              Text(
                '${summary.ticketCount}장 · ${summary.gameCount}게임',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatusCount(
                    label: summary.delayedResultCount > 0
                        ? '결과 업데이트 대기'
                        : '추첨 대기',
                    count: summary.waitingCount,
                    icon: Icons.schedule,
                    color: colors.onSurfaceVariant,
                  ),
                  _StatusCount(
                    label: '결과 미확인',
                    count: summary.uncheckedCount,
                    icon: Icons.mark_email_unread_outlined,
                    color: colors.primary,
                  ),
                  _StatusCount(
                    label: '확인 완료',
                    count: summary.checkedCount,
                    icon: Icons.check_circle_outline,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
              if (summary.delayedResultCount > 0) ...[
                const SizedBox(height: 12),
                Text(
                  '당첨번호를 불러오면 결과를 확인할 수 있어요.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onOpenRecords,
                  icon: Icon(
                    summary.uncheckedCount > 0
                        ? Icons.fact_check_outlined
                        : Icons.receipt_long_outlined,
                  ),
                  label: Text(
                    summary.uncheckedCount > 0 ? '구매 결과 확인' : '구매내역 보기',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCount extends StatelessWidget {
  const _StatusCount({
    required this.label,
    required this.count,
    required this.icon,
    required this.color,
  });
  final String label;
  final int count;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label $count장',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(icon, size: 18, color: color),
            Text(
              '$label $count장',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
