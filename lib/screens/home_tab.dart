import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/lotto_palette.dart';
import '../db/lotto_database.dart';
import '../models/draw_result.dart';
import '../models/number_set.dart';
import '../models/purchase_record.dart';
import 'lucky_store_map_screen.dart';
import 'qr_result_webview_page.dart';
import 'qr_scan_page.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({
    super.key,
    required this.savedSets,
    required this.purchaseHistory,
    required this.onSaveSet,
    required this.onAddPurchaseHistory,
    required this.onNavigateToVault,
  });

  final List<NumberSet> savedSets;
  final List<PurchaseRecord> purchaseHistory;
  final Future<void> Function(List<List<int>>) onSaveSet;
  final Future<void> Function(List<List<int>>, int, String)
  onAddPurchaseHistory;
  final void Function(int subTabIndex) onNavigateToVault;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  DrawResult? _latestDraw;
  bool _loadingDraw = true;
  Map<String, dynamic>? _serviceStats;

  @override
  void initState() {
    super.initState();
    _loadLatestDraw();
    _loadServiceStats();
  }

  Future<void> _loadServiceStats() async {
    try {
      final latestRound = await LottoDatabase.instance.getLatestRound();
      if (latestRound <= 0) return;
      final doc = await FirebaseFirestore.instance
          .collection('service_stats')
          .doc(latestRound.toString())
          .get();
      if (!mounted) return;
      if (doc.exists) {
        setState(() => _serviceStats = doc.data());
      }
    } catch (e) {
      // 부가 정보라 실패해도 화면은 그대로 둔다 (사용자 알림 없음)
      debugPrint('[HomeTab] 서비스 통계 로드 실패: $e');
    }
  }

  Future<void> _loadLatestDraw() async {
    try {
      final int round = await LottoDatabase.instance.getLatestRound();
      final Map<String, dynamic>? row = await LottoDatabase.instance
          .getDrawResult(round);
      if (!mounted) return;
      if (row != null) {
        setState(() {
          _latestDraw = DrawResult(
            round: row['round'] as int,
            winningNumbers: [
              row['num1'] as int,
              row['num2'] as int,
              row['num3'] as int,
              row['num4'] as int,
              row['num5'] as int,
              row['num6'] as int,
            ],
            bonusNumber: row['bonus'] as int,
            drawDate: row['draw_date'] as String? ?? '',
          );
          _loadingDraw = false;
        });
      } else {
        if (mounted) setState(() => _loadingDraw = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingDraw = false);
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

  Uri? _buildQROpenUri(String raw) {
    final String input = raw.trim();
    if (input.isEmpty) return null;

    final Uri? parsed = Uri.tryParse(input);
    if (parsed != null && parsed.hasScheme) {
      if (parsed.host.contains('dhlottery.co.kr')) {
        return parsed.replace(
          scheme: 'https',
          port: parsed.hasPort && parsed.port != 80 ? parsed.port : null,
        );
      }
      return null;
    }

    final RegExp vTokenRegExp = RegExp(r'(?:^|[?&])v=([A-Za-z0-9_-]+)');
    final Match? tokenMatch = vTokenRegExp.firstMatch(input);
    if (tokenMatch != null) {
      final String token = tokenMatch.group(1)!;
      return Uri.parse('https://m.dhlottery.co.kr/qr.do?method=winQr&v=$token');
    }

    if (RegExp(r'^[A-Za-z0-9_-]{8,}$').hasMatch(input)) {
      return Uri.parse('https://m.dhlottery.co.kr/qr.do?method=winQr&v=$input');
    }

    return null;
  }

  int? _parseQrRound(String raw) {
    try {
      final Uri? uri = Uri.tryParse(raw);
      final String v = uri?.queryParameters['v'] ?? raw;
      final Match? match = RegExp(r'^(\d{4})').firstMatch(v);
      return match != null ? int.tryParse(match.group(1)!) : null;
    } catch (_) {
      return null;
    }
  }

  List<List<int>>? _parseQrNumbers(String raw) {
    try {
      final Uri? uri = Uri.tryParse(raw);
      final String v = uri?.queryParameters['v'] ?? raw;
      final RegExp pattern = RegExp(
        r'm(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})',
      );
      final Iterable<RegExpMatch> matches = pattern.allMatches(v);
      final List<List<int>> games = matches
          .map(
            (m) => [
              int.parse(m.group(1)!),
              int.parse(m.group(2)!),
              int.parse(m.group(3)!),
              int.parse(m.group(4)!),
              int.parse(m.group(5)!),
              int.parse(m.group(6)!),
            ],
          )
          .toList();
      return games.isEmpty ? null : games;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openQrScanner() async {
    final String? result = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QRScanPage()));
    if (!mounted || result == null) return;

    final Uri? uri = _buildQROpenUri(result);
    if (uri == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('유효한 동행복권 QR 코드가 아닙니다.')));
      return;
    }

    final List<List<int>>? games = _parseQrNumbers(result);
    final int? round = _parseQrRound(result);

    await _openInAppQrResult(uri);

    if (games != null && mounted) {
      final bool? save = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('구매내역 저장'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                round != null
                    ? '$round회 구매 번호를 구매내역에 저장할까요?'
                    : '스캔한 번호를 구매내역에 저장할까요?',
              ),
              const SizedBox(height: 12),
              ...games.map(
                (g) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Wrap(
                    spacing: 4,
                    children: g
                        .map(
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
                        )
                        .toList(),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('저장 안 함'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('저장'),
            ),
          ],
        ),
      );
      if (save == true) {
        await widget.onAddPurchaseHistory(games, round ?? 0, 'qr');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('구매내역에 저장됐습니다.')));
        }
      }
    }
  }

  Future<void> _openInAppQrResult(Uri uri) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => QRResultWebViewPage(initialUri: uri)),
    );
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                              children: [
                                const Icon(
                                  Icons.timer_outlined,
                                  color: Colors.white70,
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '다음 추첨 ${_getDDay()}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          ..._latestDraw!.winningNumbers.map(
                            (n) => _HomeLottoBall(number: n),
                          ),
                          const _HomeBonus(),
                          _HomeLottoBall(
                            number: _latestDraw!.bonusNumber,
                            isBonus: true,
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),

        const SizedBox(height: 16),

        // ── QR 스캔 메인 CTA ──────────────────────────────────
        GestureDetector(
          onTap: _openQrScanner,
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
                        'QR 당첨 조회',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '복권 QR을 카메라로 스캔하세요',
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
      (sum, v) => sum + v.toInt(),
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
              onTap: () => widget.onNavigateToVault(1),
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
  const _HomeLottoBall({required this.number, this.isBonus = false});

  final int number;
  final bool isBonus;

  @override
  Widget build(BuildContext context) {
    final Color ballColor = lottoBallColor(number);
    final Color textColor = lottoBallTextColor(number);
    return Container(
      width: 38,
      height: 38,
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
      child: Center(
        child: Text(
          '+',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 18,
            fontWeight: FontWeight.w300,
          ),
        ),
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
