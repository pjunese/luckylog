import '../widgets/app_snack_bar.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/lotto_palette.dart';
import '../db/lotto_database.dart';
import '../models/draw_result.dart';
import '../models/purchase_record.dart';
import 'lucky_store_map_screen.dart';
import '../models/scanned_ticket.dart';
import '../models/purchase_summary.dart';
import '../models/purchase_insights.dart';
import '../models/purchase_calendar.dart';
import '../services/purchase_insights_controller.dart';
import '../widgets/monthly_record_card.dart';
import 'purchase_review_page.dart';
import 'qr_scan_page.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({
    super.key,
    required this.purchaseHistory,
    required this.onSaveQrBatch,
    required this.onMarkResultsChecked,
    required this.onNavigateToVault,
    this.database,
    this.insights,
    this.onOpenMonthlyRecords,
  });

  final List<PurchaseRecord> purchaseHistory;
  final Future<QrBatchSaveResult> Function(List<ScannedTicket>) onSaveQrBatch;
  final Future<void> Function(List<int>) onMarkResultsChecked;
  final void Function(int subTabIndex) onNavigateToVault;
  final LottoDatabase? database;
  final PurchaseInsightsController? insights;
  final VoidCallback? onOpenMonthlyRecords;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  DrawResult? _latestDraw;
  bool _loadingDraw = true;
  Map<String, dynamic>? _serviceStats;
  Map<int, DrawResult> _draws = {};
  int? _summaryRound;
  bool _openingScanner = false;
  bool _openingReview = false;
  int _drawLoadGeneration = 0;
  int _statsLoadGeneration = 0;
  late final String? _owner;
  final _reviewRevision = ValueNotifier<int>(0);
  late final PurchaseInsightsController _insights;
  LottoDatabase get _database => widget.database ?? LottoDatabase.instance;

  bool get _ownsView => mounted && _database.accountKey == _owner;

  @override
  void initState() {
    super.initState();
    _owner = _database.accountKey;
    _insights =
        widget.insights ?? PurchaseInsightsController(database: _database);
    _database.drawRevision.addListener(_onDrawChanged);
    unawaited(_loadLatestDraw());
    unawaited(_loadServiceStats());
  }

  @override
  void didUpdateWidget(HomeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.purchaseHistory != widget.purchaseHistory) {
      final previousIds = oldWidget.purchaseHistory.map((r) => r.id).toSet();
      if (widget.purchaseHistory.any((r) => !previousIds.contains(r.id))) {
        _summaryRound = null;
      }
      unawaited(_loadLatestDraw());
    }
  }

  @override
  void dispose() {
    _database.drawRevision.removeListener(_onDrawChanged);
    _reviewRevision.dispose();
    if (widget.insights == null) _insights.dispose();
    super.dispose();
  }

  void _onDrawChanged() {
    if (!_ownsView) return;
    unawaited(_loadLatestDraw());
    unawaited(_loadServiceStats());
  }

  Future<void> _loadServiceStats() async {
    final generation = ++_statsLoadGeneration;
    try {
      final latestRound = await _database.getLatestRound();
      if (!_ownsView ||
          generation != _statsLoadGeneration ||
          latestRound <= 0) {
        return;
      }
      final doc = await FirebaseFirestore.instance
          .collection('service_stats')
          .doc(latestRound.toString())
          .get()
          .timeout(const Duration(seconds: 10));
      if (!_ownsView || generation != _statsLoadGeneration) return;
      setState(() => _serviceStats = doc.exists ? doc.data() : null);
    } catch (e) {
      debugPrint('[HomeTab] 서비스 통계 로드 실패: $e');
    }
  }

  Future<void> _loadLatestDraw() async {
    final generation = ++_drawLoadGeneration;
    final rounds = widget.purchaseHistory.map((r) => r.round).toSet();
    try {
      final latest = await _database.getLatestRound();
      if (latest > 0) rounds.add(latest);
      final draws = await _database.getDrawResultsForRounds(rounds);
      if (!_ownsView || generation != _drawLoadGeneration) return;
      setState(() {
        final previousLatest = _latestDraw?.round;
        _latestDraw = draws[latest];
        _draws = draws;
        _loadingDraw = false;
        // New results take focus once; ordinary updates preserve the user's round selection.
        if (_summaryRound == null || previousLatest != _latestDraw?.round) {
          _summaryRound =
              PurchaseSummary.defaultRound(
                records: widget.purchaseHistory,
                draws: _draws,
                knownLatestRound: latest,
              ) ??
              _upcomingRound();
        }
      });
      _reviewRevision.value++;
    } catch (e) {
      if (_ownsView && generation == _drawLoadGeneration) {
        setState(() => _loadingDraw = false);
      }
      debugPrint('[HomeTab] 추첨 정보 로드 실패: $e');
    }
  }

  String _getDDay() {
    final DateTime now = DateTime.now();
    int daysUntilSaturday = (DateTime.saturday - now.weekday) % 7;
    if (daysUntilSaturday == 0 && now.hour >= 21) {
      daysUntilSaturday = 7;
    }
    final DateTime nextDraw = DateTime(
      now.year,
      now.month,
      now.day + daysUntilSaturday,
      20,
      35,
    );
    // 날짜(자정) 기준으로 며칠 남았는지 계산 (시간 절삭 방지)
    final DateTime todayMidnight = DateTime(now.year, now.month, now.day);
    final DateTime drawDay = DateTime(
      nextDraw.year,
      nextDraw.month,
      nextDraw.day,
    );
    final int calendarDays = drawDay.difference(todayMidnight).inDays;
    if (calendarDays >= 1) return 'D-$calendarDays';
    // 당일 (추첨 전)
    final Duration diff = nextDraw.difference(now);
    if (diff.inHours >= 1) return '${diff.inHours}시간 후';
    if (diff.inMinutes >= 1) return '${diff.inMinutes}분 후';
    return '추첨 진행 중';
  }

  int _upcomingRound() {
    final koreanNow = DateTime.now().toUtc().add(const Duration(hours: 9));
    final day = DateTime.utc(koreanNow.year, koreanNow.month, koreanNow.day);
    final days = day.difference(DateTime.utc(2002, 12, 7)).inDays;
    final calendarRound = days < 0 ? 1 : ((days + 6) ~/ 7) + 1;
    final afterLatest = (_latestDraw?.round ?? 0) + 1;
    return calendarRound > afterLatest ? calendarRound : afterLatest;
  }

  Future<void> _openQrScanner() async {
    if (!_ownsView || _openingScanner) return;
    setState(() => _openingScanner = true);
    QrBatchSaveResult? saved;
    try {
      final known = await _database.getKnownQrFingerprints();
      if (!mounted || !_ownsView) return;
      await Navigator.of(context).push<List<ScannedTicket>>(
        MaterialPageRoute(
          builder: (_) => QRScanPage(
            knownFingerprints: known,
            onSave: (tickets) async {
              if (!_ownsView) throw StateError('계정이 변경되었습니다. 다시 로그인해주세요.');
              saved = await widget.onSaveQrBatch(tickets);
            },
          ),
        ),
      );
      if (!_ownsView || saved == null) return;
      final result = saved!;
      final notes = <String>[
        '${result.insertedCount}장 등록 완료',
        if (result.duplicateCount > 0) '이미 등록된 ${result.duplicateCount}장 제외',
        if (result.deletedCount > 0)
          '이전에 삭제한 ${result.deletedCount}장 · 구매내역 휴지통에서 복원 가능',
      ];
      await _loadLatestDraw();
      if (!mounted || !_ownsView) return;
      showAppSnackBar(context, content: Text(notes.join(' · ')));
    } catch (e) {
      if (mounted && _ownsView) {
        showAppSnackBar(
          context,
          content: Text('QR 등록 화면을 열지 못했습니다. 다시 시도해주세요.'),
        );
      }
    } finally {
      if (_ownsView) setState(() => _openingScanner = false);
    }
  }

  Future<void> _openPurchaseReview() async {
    if (!_ownsView || _openingReview) return;
    final round = _summaryRound;
    if (round == null) return;
    _openingReview = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ValueListenableBuilder<int>(
            valueListenable: _reviewRevision,
            builder: (_, revision, _) => PurchaseReviewPage(
              round: round,
              records: widget.purchaseHistory,
              draws: _draws,
              knownLatestRound: _latestDraw?.round,
              onMarkChecked: (ids) async {
                if (!_ownsView) throw StateError('계정이 변경되었습니다.');
                await widget.onMarkResultsChecked(ids);
              },
            ),
          ),
        ),
      );
    } finally {
      _openingReview = false;
    }
  }

  /// 최근 구매 내역을 회차별로 묶어서 최대 3회차 반환
  List<MapEntry<int, int>> _recentPurchaseSummary() {
    final Map<int, int> roundGameCount = <int, int>{};
    for (final PurchaseRecord r in widget.purchaseHistory) {
      if (r.round > 0) {
        roundGameCount[r.round] =
            (roundGameCount[r.round] ?? 0) + r.games.length;
      }
    }
    final List<MapEntry<int, int>> sorted = roundGameCount.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return sorted.take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // ── 그라데이션 헤더: 최신 당첨번호 + D-day ──────────────
        GestureDetector(
          onTap: () => widget.onNavigateToVault(2),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isDark
                    ? [const Color(0xFF283593), const Color(0xFF3949AB)]
                    : [const Color(0xFF5C6BC0), const Color(0xFF7986CB)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF3949AB).withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
            child: _loadingDraw
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: CircularProgressIndicator(color: Colors.white54),
                    ),
                  )
                : _latestDraw == null
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '당첨 정보를 불러올 수 없습니다.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '제 ${_latestDraw!.round}회 당첨번호',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 0.3,
                                ),
                              ),
                              if (_latestDraw!.drawDate.isNotEmpty)
                                Text(
                                  _latestDraw!.drawDate,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.timer_outlined,
                                  color: Colors.white70,
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    '다음 추첨 ${_getDDay()}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final minSize =
                              (MediaQuery.textScalerOf(context).scale(13) + 12)
                                  .clamp(28.0, 38.0);
                          final size = ((constraints.maxWidth - 48) / 7).clamp(
                            minSize,
                            38.0,
                          );
                          return Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 4,
                            runSpacing: 8,
                            children: [
                              ..._latestDraw!.winningNumbers.map(
                                (n) => _HomeLottoBall(number: n, size: size),
                              ),
                              // The bonus marker must stay with its ball when wrapping.
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const _HomeBonus(),
                                  const SizedBox(width: 4),
                                  _HomeLottoBall(
                                    number: _latestDraw!.bonusNumber,
                                    isBonus: true,
                                    size: size,
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
          ),
        ),

        const SizedBox(height: 16),

        // ── QR 스캔 메인 CTA ──────────────────────────────────
        GestureDetector(
          onTap: _openingScanner ? null : _openQrScanner,
          child: Container(
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cs.primary.withValues(alpha: 0.25),
                width: 1.5,
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.qr_code_scanner,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '복권 여러 장 등록',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '연속 스캔하거나 사진에서 QR을 읽어보세요',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onPrimaryContainer.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: cs.primary.withValues(alpha: 0.7),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        ListenableBuilder(
          listenable: _insights,
          builder: (context, _) {
            if (_insights.loading) return const SizedBox.shrink();
            if (_insights.failed) {
              return TextButton.icon(
                onPressed: () => _insights.refresh(retryPrizes: true),
                icon: const Icon(Icons.refresh),
                label: const Text('이번 달 기록 다시 불러오기'),
              );
            }
            return MonthlyRecordCard(
              summary: CalendarMonthSummary(
                insights: _insights.value,
                month: koreanCalendarDay(),
              ),
              onOpenRecords:
                  widget.onOpenMonthlyRecords ??
                  () => widget.onNavigateToVault(1),
            );
          },
        ),
        const SizedBox(height: 16),

        // ── 서비스 통계 카드 ──────────────────────────────────
        if (_serviceStats != null) _buildServiceStatsCard(cs),
        if (_serviceStats != null) const SizedBox(height: 16),

        // ── 최근 구매 현황 ────────────────────────────────────
        _buildRecentPurchases(cs),

        const SizedBox(height: 16),

        // ── 명당지도 ───────────────────────────────────────────
        GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LuckyStoreMapScreen()),
          ),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [const Color(0xFF2E7D32), const Color(0xFF43A047)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                const Icon(Icons.map_outlined, color: Colors.white, size: 24),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '명당지도',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '최근 1년 1등 당첨매장 지도',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white70,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildServiceStatsCard(ColorScheme cs) {
    final stats = _serviceStats!;
    final winners = (stats['winners'] as Map<String, dynamic>?) ?? {};
    final totalParticipants =
        (stats['totalParticipants'] as num?)?.toInt() ?? 0;
    final totalSets = (stats['totalSets'] as num?)?.toInt() ?? 0;
    final round = (stats['round'] as num?)?.toInt() ?? 0;

    final hasWinner1 = ((winners['1'] as num?)?.toInt() ?? 0) > 0;
    final totalWinners = winners.values.whereType<num>().fold<int>(
      0,
      (total, v) => total + v.toInt(),
    );

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bar_chart_rounded, color: cs.primary, size: 18),
              const SizedBox(width: 8),
              Text(
                '$round회 앱 사용자 현황',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatChip(label: '참여자', value: '$totalParticipants명'),
              const SizedBox(width: 8),
              _StatChip(label: '총 세트', value: '$totalSets세트'),
              const SizedBox(width: 8),
              _StatChip(
                label: '당첨자',
                value: '$totalWinners명',
                highlight: totalWinners > 0,
              ),
            ],
          ),
          if (hasWinner1) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD700).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFFFFD700).withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🏆', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 6),
                  Text(
                    '이번 주 앱 사용자 중 1등 당첨자가 있습니다!',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecentPurchases(ColorScheme cs) {
    final List<MapEntry<int, int>> summary = _recentPurchaseSummary();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 10),
          child: Text(
            '최근 구매 현황',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
        ),
        if (summary.isEmpty)
          Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(vertical: 24),
            width: double.infinity,
            child: Column(
              children: [
                Icon(
                  Icons.receipt_long_outlined,
                  color: cs.onSurface.withValues(alpha: 0.3),
                  size: 36,
                ),
                const SizedBox(height: 8),
                Text(
                  'QR을 스캔하면 구매내역이 기록됩니다',
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          )
        else
          ...summary.map(
            (entry) => GestureDetector(
              onTap: () {
                setState(() => _summaryRound = entry.key);
                _openPurchaseReview();
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          '${entry.key}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: cs.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '제 ${entry.key}회',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                          Text(
                            '${entry.value}게임 구매',
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.receipt_outlined,
                      color: cs.onSurface.withValues(alpha: 0.3),
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 홈 헤더용 로또볼
class _HomeLottoBall extends StatelessWidget {
  const _HomeLottoBall({
    required this.number,
    this.isBonus = false,
    this.size = 38,
  });

  final int number;
  final bool isBonus;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Color ballColor = lottoBallColor(number);
    final Color textColor = lottoBallTextColor(number);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ballColor,
        border: isBonus ? Border.all(color: Colors.white54, width: 2) : null,
        boxShadow: [
          BoxShadow(
            color: ballColor.withValues(alpha: 0.5),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Text(
          '$number',
          style: TextStyle(
            color: textColor,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

/// "+" 구분자 (보너스볼 앞에 표시)
class _HomeBonus extends StatelessWidget {
  const _HomeBonus();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 38,
      child: Icon(
        Icons.add,
        size: 18,
        color: Colors.white.withValues(alpha: 0.5),
        semanticLabel: '보너스 번호',
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    this.highlight = false,
  });
  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlight
            ? cs.primary.withValues(alpha: 0.1)
            : cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: highlight ? cs.primary : cs.onSurface,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}
