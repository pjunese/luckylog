import 'package:flutter/material.dart';
import '../models/purchase_insights.dart';
import '../models/purchase_calendar.dart';

class MonthlyRecordCard extends StatelessWidget {
  const MonthlyRecordCard({
    super.key,
    required this.summary,
    required this.onOpenRecords,
  });
  final CalendarMonthSummary summary;
  final VoidCallback onOpenRecords;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.filled(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpenRecords,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '이번 달 기록',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${summary.period.start.month}월',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
              const SizedBox(height: 16),
              if (summary.records.isEmpty && summary.winCount == 0)
                const Text('달력에 구매내역을 등록하고 이번 달 기록을 모아보세요.')
              else ...[
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
                        label: '당첨금 · 세전',
                        value: summary.prizeText,
                        highlight: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '${summary.games.length}게임 · 당첨 ${summary.winCount}게임',
                  style: theme.textTheme.bodyMedium,
                ),
                if (summary.pendingGames > 0 || summary.unknownPrizeCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      [
                        if (summary.pendingGames > 0)
                          '결과 대기 ${summary.pendingGames}게임',
                        if (summary.unknownPrizeCount > 0)
                          '당첨금 확인 중 ${summary.unknownPrizeCount}게임',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              Text(
                '구매는 구매일 · 당첨은 추첨일 기준',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class InsightMetric extends StatelessWidget {
  const InsightMetric({
    super.key,
    required this.label,
    required this.value,
    this.highlight = false,
  });
  final String label;
  final String value;
  final bool highlight;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        value,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w800,
          color: highlight ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
    ],
  );
}
