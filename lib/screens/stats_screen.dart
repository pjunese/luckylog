import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../db/lotto_database.dart';
import '../models/number_stat.dart';

// ─────────────────────────────────────────
// 로또 볼 색상 헬퍼
// ─────────────────────────────────────────
Color _ballColor(int n) {
  if (n <= 10) return const Color(0xFFFBC400);
  if (n <= 20) return const Color(0xFF2A75F3);
  if (n <= 30) return const Color(0xFFE74C3C);
  if (n <= 40) return const Color(0xFF1F1F1F);
  return const Color(0xFF2EAD4C);
}

// 검정 배경(31~40)만 흰색, 나머지는 검은색
Color _ballTextColor(int n) =>
    (n >= 31 && n <= 40) ? Colors.white : Colors.black;

// ─────────────────────────────────────────
// 최상위 화면 (TabBar 컨테이너)
// ─────────────────────────────────────────
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '전체 시장'),
            Tab(text: '최근 흐름'),
            Tab(text: '연번 상세'),
            Tab(text: '해석 보조'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              _FrequencyTab(),
              _TrendTab(),
              _ConsecutiveDetailTab(),
              _PatternTab(),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────
// Tab 1: 번호 빈도
// ─────────────────────────────────────────
class _FrequencyTab extends StatefulWidget {
  const _FrequencyTab();

  @override
  State<_FrequencyTab> createState() => _FrequencyTabState();
}

class _FrequencyTabState extends State<_FrequencyTab>
    with AutomaticKeepAliveClientMixin {
  // 필터 상태
  int? _recentN; // null = 전체
  bool _includeBonus = false;
  _SortMode _sort = _SortMode.byNumber;

  bool _loading = true;
  List<NumberStat> _stats = [];
  int _latestRound = 0;
  int _fromRound = 1;
  Map<String, int> _rangeDist = const <String, int>{};

  static const List<_FilterOption> _filters = [
    _FilterOption(label: '전체', value: null),
    _FilterOption(label: '최근 3회', value: 3),
    _FilterOption(label: '최근 5회', value: 5),
    _FilterOption(label: '최근 7회', value: 7),
    _FilterOption(label: '최근 10회', value: 10),
    _FilterOption(label: '최근 20회', value: 20),
    _FilterOption(label: '최근 30회', value: 30),
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _loading = true);
    final int latest = await LottoDatabase.instance.getLatestRound();
    final int from = _recentN == null
        ? 1
        : (latest - _recentN! + 1).clamp(1, latest);

    final results = await Future.wait([
      LottoDatabase.instance.getNumberStats(
        from: from,
        to: latest,
        includeBonus: _includeBonus,
      ),
      LottoDatabase.instance.getRangeDistribution(from: from, to: latest),
    ]);

    final List<NumberStat> stats = results[0] as List<NumberStat>;
    final Map<String, int> rangeDist = results[1] as Map<String, int>;

    if (!mounted) return;
    setState(() {
      _latestRound = latest;
      _fromRound = from;
      _stats = stats;
      _rangeDist = rangeDist;
      _loading = false;
    });
  }

  List<NumberStat> get _sortedStats {
    final List<NumberStat> copy = List.from(_stats);
    switch (_sort) {
      case _SortMode.byNumber:
        copy.sort((a, b) => a.number.compareTo(b.number));
      case _SortMode.byFreqDesc:
        copy.sort((a, b) => b.freq.compareTo(a.freq));
      case _SortMode.byFreqAsc:
        copy.sort((a, b) => a.freq.compareTo(b.freq));
      case _SortMode.byAbsence:
        copy.sort((a, b) => b.absenceCount.compareTo(a.absenceCount));
    }
    return copy;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        // ── 필터 바 ──
        _buildFilterBar(),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '데이터 기준: ${_fromRound}~${_latestRound}회',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                _buildDefinitionCard(),
                const SizedBox(height: 12),
                // ── 핫/콜드 요약 ──
                _buildHotColdSummary(),
                const SizedBox(height: 16),
                // ── 출현빈도 TOP 10 공 ──
                _buildTop10BallsCard(),
                const SizedBox(height: 16),
                // ── 번호 스크롤 리스트 ──
                _buildSortRow(),
                const SizedBox(height: 8),
                _buildNumberScrollList(),
                // ── 전체 기간만 표시 ──
                if (_recentN == null) ...[
                  const SizedBox(height: 16),
                  _buildRangeDistributionCard(),
                  const SizedBox(height: 16),
                  _buildAbsenceCard(),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFilterBar() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          // 회차 범위 필터
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final opt = _filters[i];
                final bool selected = _recentN == opt.value;
                return FilterChip(
                  label: Text(opt.label),
                  selected: selected,
                  onSelected: (_) {
                    setState(() => _recentN = opt.value);
                    _loadStats();
                  },
                );
              },
            ),
          ),
          // 보너스 포함 토글
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text('보너스 번호 포함'),
            value: _includeBonus,
            onChanged: (v) {
              setState(() => _includeBonus = v);
              _loadStats();
            },
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  Widget _buildHotColdSummary() {
    final hot = _stats.where((s) => s.isHot).toList()
      ..sort((a, b) => b.freq.compareTo(a.freq));
    final cold = _stats.where((s) => s.isCold).toList()
      ..sort((a, b) => a.freq.compareTo(b.freq));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('핫 · 콜드 번호',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 2),
            InkWell(
              onTap: _showHotColdInfo,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                  Icons.help_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _HotColdCard(
                title: '🔥 핫 번호',
                numbers: hot.take(5).toList(),
                isHot: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _HotColdCard(
                title: '🧊 콜드 번호',
                numbers: cold.take(5).toList(),
                isHot: false,
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _showHotColdInfo() {
    final cs = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('핫 · 콜드 번호란?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('🔥 ', style: TextStyle(fontSize: 15)),
                Expanded(
                  child: Text(
                    '핫 번호\n선택한 구간에서 평균보다 25% 이상 자주 나온 번호예요.',
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('🧊 ', style: TextStyle(fontSize: 15)),
                Expanded(
                  child: Text(
                    '콜드 번호\n평균보다 25% 이상 적게 나온 번호예요.',
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '45개 번호가 고르게 나온다고 가정했을 때의 평균 출현 횟수와 비교한 값이에요. 통계적 참고용이며 당첨 확률과는 관계없어요.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Widget _buildDefinitionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('집계 기준', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              _includeBonus
                  ? '보너스 포함 ON: 메인 6개 + 보너스 1개 출현 횟수로 집계합니다.'
                  : '보너스 포함 OFF: 메인 6개 번호만 집계합니다.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSortRow() {
    return Row(
      children: [
        Text('번호별 출현 횟수', style: Theme.of(context).textTheme.titleSmall),
        const Spacer(),
        DropdownButton<_SortMode>(
          value: _sort,
          isDense: true,
          underline: const SizedBox(),
          items: const [
            DropdownMenuItem(value: _SortMode.byNumber, child: Text('번호순')),
            DropdownMenuItem(
              value: _SortMode.byFreqDesc,
              child: Text('많이 나온 순'),
            ),
            DropdownMenuItem(
              value: _SortMode.byFreqAsc,
              child: Text('적게 나온 순'),
            ),
            DropdownMenuItem(
              value: _SortMode.byAbsence,
              child: Text('미출현 긴 순'),
            ),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _sort = v);
          },
        ),
      ],
    );
  }

  Widget _buildTop10BallsCard() {
    final List<NumberStat> top = List<NumberStat>.from(_stats)
      ..sort((a, b) {
        final byFreq = b.freq.compareTo(a.freq);
        if (byFreq != 0) return byFreq;
        return a.number.compareTo(b.number);
      });
    final List<NumberStat> top10 = top.take(10).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '출현 빈도 TOP 10',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: top10.map((s) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: _ballColor(s.number),
                      child: Text(
                        '${s.number}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _ballTextColor(s.number),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${s.freq}회',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNumberScrollList() {
    final sorted = _sortedStats;
    final int maxFreq = sorted.map((s) => s.freq).fold(0, max);

    return Card(
      child: Column(
        children: sorted.map((stat) {
          final double ratio = maxFreq == 0 ? 0 : stat.freq / maxFreq;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: _ballColor(stat.number).withValues(
                    alpha: 0.45 + ratio * 0.55,
                  ),
                  child: Text(
                    '${stat.number}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _ballTextColor(stat.number),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 10,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation(
                        _ballColor(stat.number).withValues(
                          alpha: 0.6 + ratio * 0.4,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${stat.freq}회',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (stat.isHot)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Text('🔥', style: TextStyle(fontSize: 11)),
                  )
                else if (stat.isCold)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Text('🧊', style: TextStyle(fontSize: 11)),
                  )
                else
                  const SizedBox(width: 19),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRangeDistributionCard() {
    final orderedKeys = <String>['1~10', '11~20', '21~30', '31~40', '41~45'];
    final int total = _rangeDist.values.fold(0, (a, b) => a + b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('구간 분포', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '선택한 회차 범위에서 구간별 출현 비중',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ...orderedKeys.map((key) {
              final int count = _rangeDist[key] ?? 0;
              final double pct = total == 0 ? 0 : count / total;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(key, style: const TextStyle(fontSize: 12)),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 14,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation(_rangeColor(key)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 52,
                      child: Text(
                        '${(pct * 100).toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Color _rangeColor(String range) {
    switch (range) {
      case '1~10':
        return const Color(0xFFFBC400);
      case '11~20':
        return const Color(0xFF2A75F3);
      case '21~30':
        return const Color(0xFFE74C3C);
      case '31~40':
        return const Color(0xFF1F1F1F);
      default:
        return const Color(0xFF2EAD4C);
    }
  }

  Widget _buildAbsenceCard() {
    final absent = List<NumberStat>.from(_stats)
      ..sort((a, b) => b.absenceCount.compareTo(a.absenceCount));
    final top = absent.take(10).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('미출현 TOP 10', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              '마지막 출현 이후 연속 미출현 횟수 기준',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ...top.map((s) => _AbsenceRow(stat: s, latestRound: _latestRound)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// Tab 2: 흐름 분석
// ─────────────────────────────────────────
class _TrendTab extends StatefulWidget {
  const _TrendTab();

  @override
  State<_TrendTab> createState() => _TrendTabState();
}

class _TrendTabState extends State<_TrendTab>
    with AutomaticKeepAliveClientMixin {
  int _recentN = 10;
  bool _loading = true;
  List<RoundPattern> _patterns = [];
  int _latestRound = 0;

  static const List<int> _options = [3, 5, 7, 10, 20, 50];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final latest = await LottoDatabase.instance.getLatestRound();
    final patterns = await LottoDatabase.instance.getRecentRoundPatterns(
      _recentN,
    );
    if (!mounted) return;
    setState(() {
      _latestRound = latest;
      _patterns = patterns;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        // N 선택 칩
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            itemCount: _options.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final int n = _options[i];
              return FilterChip(
                label: Text('최근 $n회'),
                selected: _recentN == n,
                onSelected: (_) {
                  setState(() => _recentN = n);
                  _load();
                },
              );
            },
          ),
        ),
        const Divider(height: 1),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: const EdgeInsets.all(16),
              children: [
                _buildSummaryCards(),
                const SizedBox(height: 16),
                _buildRecentRoundList(),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSummaryCards() {
    if (_patterns.isEmpty) return const SizedBox();

    // 번호 출현 집계
    final Map<int, int> freqMap = {};
    for (final p in _patterns) {
      for (final n in p.numbers) {
        freqMap[n] = (freqMap[n] ?? 0) + 1;
      }
    }
    final sorted = freqMap.entries.toList()
      ..sort((a, b) {
        final int byFreq = b.value.compareTo(a.value);
        if (byFreq != 0) return byFreq;
        return a.key.compareTo(b.key);
      });
    final topEntries = sorted
        .where((e) => e.value >= 2)
        .take(6)
        .toList(growable: false);
    final zeroNums = List.generate(
      45,
      (i) => i + 1,
    ).where((n) => !freqMap.containsKey(n)).toList();
    final int fromRound = (_latestRound - _recentN + 1).clamp(1, _latestRound);

    // 평균 합계
    final double avgSum =
        _patterns.map((p) => p.sum).fold(0, (a, b) => a + b) / _patterns.length;

    // 홀짝 평균
    final double avgOdd =
        _patterns.map((p) => p.oddCount).fold(0, (a, b) => a + b) /
        _patterns.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '최근 $_recentN회 요약 (${fromRound}~$_latestRound회)',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _SummaryCard(
                  icon: Icons.local_fire_department,
                  iconColor: Colors.orange,
                  title: '중복 출현 번호 (2회+)',
                  child: topEntries.isEmpty
                      ? const Text('없음', style: TextStyle(fontSize: 12))
                      : Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: topEntries
                              .map(
                                (e) => _FreqBall(number: e.key, freq: e.value),
                              )
                              .toList(),
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SummaryCard(
                  icon: Icons.ac_unit,
                  iconColor: Colors.blueAccent,
                  title: '한 번도 안 나온 번호',
                  child: zeroNums.isEmpty
                      ? const Text('없음', style: TextStyle(fontSize: 12))
                      : Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: zeroNums
                              .map((n) => _SmallBall(number: n))
                              .toList(),
                        ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _SummaryCard(
                  icon: Icons.functions,
                  iconColor: Colors.purple,
                  title: '평균 합계',
                  child: Text(
                    avgSum.toStringAsFixed(1),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SummaryCard(
                  icon: Icons.compare_arrows,
                  iconColor: Colors.teal,
                  title: '평균 홀:짝',
                  child: Text(
                    '${avgOdd.toStringAsFixed(1)} : ${(6 - avgOdd).toStringAsFixed(1)}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecentRoundList() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('최근 회차 상세', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            ...(_patterns.reversed.take(10).map((p) => _RoundRow(pattern: p))),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// Tab 4: 연번 상세
// ─────────────────────────────────────────
class _ConsecutiveDetailTab extends StatefulWidget {
  const _ConsecutiveDetailTab();

  @override
  State<_ConsecutiveDetailTab> createState() => _ConsecutiveDetailTabState();
}

class _ConsecutiveDetailTabState extends State<_ConsecutiveDetailTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  int? _recentN;
  int _latestRound = 0;
  int _fromRound = 1;
  int _sequenceLength = 2;
  bool _sortByFreq = true;
  Map<int, int> _consecutiveDist = <int, int>{};
  Map<int, int> _pairSeqFreq = <int, int>{};
  Map<int, int> _tripleSeqFreq = <int, int>{};
  static const List<_FilterOption> _filters = [
    _FilterOption(label: '전체', value: null),
    _FilterOption(label: '최근 3회', value: 3),
    _FilterOption(label: '최근 5회', value: 5),
    _FilterOption(label: '최근 7회', value: 7),
    _FilterOption(label: '최근 10회', value: 10),
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final int latest = await LottoDatabase.instance.getLatestRound();
    final int from = _recentN == null
        ? 1
        : (latest - _recentN! + 1).clamp(1, latest);
    final results = await Future.wait([
      LottoDatabase.instance.getConsecutivePairDistribution(
        from: from,
        to: latest,
      ),
      LottoDatabase.instance.getConsecutiveSequenceFrequency(
        sequenceLength: 2,
        from: from,
        to: latest,
      ),
      LottoDatabase.instance.getConsecutiveSequenceFrequency(
        sequenceLength: 3,
        from: from,
        to: latest,
      ),
    ]);

    if (!mounted) return;
    setState(() {
      _latestRound = latest;
      _fromRound = from;
      _consecutiveDist = results[0] as Map<int, int>;
      _pairSeqFreq = results[1] as Map<int, int>;
      _tripleSeqFreq = results[2] as Map<int, int>;
      _loading = false;
    });
  }

  List<MapEntry<int, int>> _entries() {
    final Map<int, int> data = _sequenceLength == 2
        ? _pairSeqFreq
        : _tripleSeqFreq;
    final int maxStart = 45 - _sequenceLength + 1;
    return List<MapEntry<int, int>>.generate(maxStart, (i) {
      final int start = i + 1;
      return MapEntry<int, int>(start, data[start] ?? 0);
    }, growable: false);
  }

  void _showConsecutiveRounds({
    required int startNumber,
    required int sequenceLength,
  }) {
    final seqNums = List.generate(sequenceLength, (i) => startNumber + i);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ConsecutiveRoundsSheet(
        seqNums: seqNums,
        sequenceLength: sequenceLength,
      ),
    );
  }

  Widget _buildSequenceBalls(int start) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List<Widget>.generate(_sequenceLength, (i) {
        return Padding(
          padding: EdgeInsets.only(right: i == _sequenceLength - 1 ? 0 : 4),
          child: _SmallBall(number: start + i),
        );
      }),
    );
  }

  Widget _buildConsecutivePairCard() {
    final int total = _consecutiveDist.values.fold(0, (a, b) => a + b);
    final int c0 = _consecutiveDist[0] ?? 0;
    final int c1 = _consecutiveDist[1] ?? 0;
    final int c2 = _consecutiveDist[2] ?? 0;
    final int c3Plus =
        (_consecutiveDist[3] ?? 0) +
        (_consecutiveDist[4] ?? 0) +
        (_consecutiveDist[5] ?? 0);

    final Map<String, int> bins = <String, int>{
      '1쌍': c1,
      '2쌍': c2,
      '3쌍+': c3Plus,
      '0쌍': c0,
    };
    final int maxCount = bins.values.fold(0, max);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('연번 출현 분포', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '회차별 연속 번호 쌍 개수 (보너스 제외)',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ...bins.entries.map((e) {
              final double ratio = maxCount == 0 ? 0 : e.value / maxCount;
              final double pct = total == 0 ? 0 : e.value / total * 100;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 42,
                      child: Text(
                        e.key,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 14,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation(
                            Theme.of(context).colorScheme.tertiary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 110,
                      child: Text(
                        '${e.value}회 (${pct.toStringAsFixed(1)}%)',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11),
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final List<MapEntry<int, int>> entries = _entries();
    final int maxFreq = entries.isEmpty
        ? 0
        : entries.map((e) => e.value).reduce(max);
    final List<MapEntry<int, int>> sortedEntries = List.from(entries)
      ..sort((a, b) {
        if (_sortByFreq) {
          final int byFreq = b.value.compareTo(a.value);
          if (byFreq != 0) return byFreq;
          return a.key.compareTo(b.key);
        }
        return a.key.compareTo(b.key);
      });

    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  Icons.insights_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '데이터 기준: ${_fromRound}~${_latestRound}회 (보너스 제외)',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: _filters
              .map((opt) {
                return FilterChip(
                  label: Text(opt.label),
                  selected: _recentN == opt.value,
                  onSelected: (_) {
                    setState(() => _recentN = opt.value);
                    _load();
                  },
                );
              })
              .toList(growable: false),
        ),
        const SizedBox(height: 12),
        _buildConsecutivePairCard(),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('연번 상세 통계', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  '1~45 전체 연속 조합의 누적 출현 횟수',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 2, label: Text('2연번')),
                          ButtonSegment(value: 3, label: Text('3연번')),
                        ],
                        selected: <int>{_sequenceLength},
                        onSelectionChanged: (selection) {
                          setState(() => _sequenceLength = selection.first);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: true, label: Text('많이 나온 순')),
                        ButtonSegment(value: false, label: Text('번호 순')),
                      ],
                      selected: <bool>{_sortByFreq},
                      onSelectionChanged: (s) {
                        setState(() => _sortByFreq = s.first);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final int crossAxisCount = constraints.maxWidth >= 440
                        ? 3
                        : 2;
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: sortedEntries.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 2.4,
                      ),
                      itemBuilder: (_, i) {
                        final entry = sortedEntries[i];
                        final double ratio = maxFreq == 0
                            ? 0
                            : entry.value / maxFreq;
                        return InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _showConsecutiveRounds(
                            startNumber: entry.key,
                            sequenceLength: _sequenceLength,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: Theme.of(context).colorScheme.primary
                                  .withValues(alpha: 0.07 + (ratio * 0.23)),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(child: _buildSequenceBalls(entry.key)),
                                const SizedBox(width: 6),
                                Text(
                                  '${entry.value}회',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────
// Tab 5: 해석 보조
// ─────────────────────────────────────────
class _PatternTab extends StatefulWidget {
  const _PatternTab();

  @override
  State<_PatternTab> createState() => _PatternTabState();
}

class _PatternTabState extends State<_PatternTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  Map<int, int> _oddEven = {};
  Map<String, int> _sumDist = {};
  Map<int, int> _endingDist = {};
  int _totalRounds = 0;

  int _coTargetNumber = 7;
  int _coTopN = 5;
  int _coRecentN = 10;
  int _coFromRound = 1;
  int _coToRound = 0;
  int _coTargetAppearCount = 0;
  bool _coLoading = false;
  List<_CoOccurrenceItem> _coItems = const <_CoOccurrenceItem>[];

  static const List<int> _coTopOptions = <int>[5, 10];
  static const List<int> _coRecentOptions = <int>[3, 5, 10, 15];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final latest = await LottoDatabase.instance.getLatestRound();

    final results = await Future.wait([
      LottoDatabase.instance.getOddEvenDistribution(from: 1, to: latest),
      LottoDatabase.instance.getSumDistribution(from: 1, to: latest),
      LottoDatabase.instance.getEndingDigitDistribution(from: 1, to: latest),
    ]);

    if (!mounted) return;
    setState(() {
      _oddEven = results[0] as Map<int, int>;
      _sumDist = results[1] as Map<String, int>;
      _endingDist = results[2] as Map<int, int>;
      _totalRounds = latest;
      _loading = false;
    });
    await _loadCoOccurrence(latestRound: latest);
  }

  Future<void> _loadCoOccurrence({int? latestRound}) async {
    final int latest = latestRound ?? _totalRounds;
    if (latest <= 0) return;

    final int from = (latest - _coRecentN + 1).clamp(1, latest);
    setState(() {
      _coLoading = true;
      _coFromRound = from;
      _coToRound = latest;
    });

    final results = await Future.wait([
      LottoDatabase.instance.getTargetAppearCount(
        targetNumber: _coTargetNumber,
        from: from,
        to: latest,
      ),
      LottoDatabase.instance.getCoOccurrenceTop(
        targetNumber: _coTargetNumber,
        from: from,
        to: latest,
        topN: _coTopN,
      ),
    ]);

    if (!mounted) return;
    final int targetAppearCount = results[0] as int;
    final List<Map<String, dynamic>> rows =
        results[1] as List<Map<String, dynamic>>;
    final List<_CoOccurrenceItem> items = rows
        .map(
          (row) => _CoOccurrenceItem(
            number: row['number'] as int,
            freq: row['freq'] as int,
          ),
        )
        .toList(growable: false);

    setState(() {
      _coTargetAppearCount = targetAppearCount;
      _coItems = items;
      _coLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.all(16),
      children: [
        _buildCoOccurrenceCard(),
        const SizedBox(height: 16),
        _buildOddEvenChart(),
        const SizedBox(height: 16),
        _buildSumDistChart(),
        const SizedBox(height: 16),
        _buildEndingDigitChart(),
      ],
    );
  }

  Widget _buildOddEvenChart() {
    final int total = _oddEven.values.fold(0, (a, b) => a + b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '홀짝 비율 분포 (전체 $_totalRounds회)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '6개 번호 중 홀수 개수',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              child: BarChart(
                BarChartData(
                  barGroups: List.generate(7, (i) {
                    final int count = _oddEven[i] ?? 0;
                    return BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: count.toDouble(),
                          color: i == 3
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.5),
                          width: 28,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ],
                    );
                  }),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (v, _) {
                          final i = v.toInt();
                          return Text(
                            '홀$i\n짝${6 - i}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 9),
                          );
                        },
                        reservedSize: 32,
                      ),
                    ),
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (group, _, rod, __) {
                        final int count = rod.toY.toInt();
                        final double pct = total == 0 ? 0 : count / total * 100;
                        return BarTooltipItem(
                          '$count회\n${pct.toStringAsFixed(1)}%',
                          const TextStyle(color: Colors.white, fontSize: 11),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSumDistChart() {
    final int total = _sumDist.values.fold(0, (a, b) => a + b);
    final keys = _sumDist.keys.toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('번호 합계 분포', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '6개 번호의 합계 구간별 빈도',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ...keys.map((k) {
              final int count = _sumDist[k] ?? 0;
              final double pct = total == 0 ? 0 : count / total;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 60,
                      child: Text(k, style: const TextStyle(fontSize: 12)),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 16,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation(
                            Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '$count회',
                        style: const TextStyle(fontSize: 11),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildEndingDigitChart() {
    final int total = _endingDist.values.fold(0, (a, b) => a + b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('끝수(일의 자리) 분포', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '예: 7, 17, 27, 37 → 끝수 7',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 160,
              child: BarChart(
                BarChartData(
                  barGroups: List.generate(10, (i) {
                    final int count = _endingDist[i] ?? 0;
                    return BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: count.toDouble(),
                          color: Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.8),
                          width: 22,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ],
                    );
                  }),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (v, _) => Text(
                          '${v.toInt()}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        reservedSize: 20,
                      ),
                    ),
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (group, _, rod, __) {
                        final int count = rod.toY.toInt();
                        final double pct = total == 0 ? 0 : count / total * 100;
                        return BarTooltipItem(
                          '끝수 ${group.x}: $count회\n${pct.toStringAsFixed(1)}%',
                          const TextStyle(color: Colors.white, fontSize: 11),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoOccurrenceCard() {
    final int maxFreq = _coItems.isEmpty
        ? 0
        : _coItems.map((e) => e.freq).reduce(max);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('동반 출현 분석', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              '기준 번호와 함께 자주 등장한 번호를 보여줍니다.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _coTargetNumber,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: '기준 번호',
                      border: OutlineInputBorder(),
                    ),
                    items: List.generate(
                      45,
                      (i) => DropdownMenuItem<int>(
                        value: i + 1,
                        child: Text('${i + 1}번'),
                      ),
                    ),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _coTargetNumber = value);
                      _loadCoOccurrence();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: _coTopOptions
                      .map(
                        (n) =>
                            ButtonSegment<int>(value: n, label: Text('TOP $n')),
                      )
                      .toList(growable: false),
                  selected: <int>{_coTopN},
                  onSelectionChanged: (selection) {
                    setState(() => _coTopN = selection.first);
                    _loadCoOccurrence();
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _coRecentOptions
                  .map((n) {
                    final bool selected = _coRecentN == n;
                    final String label = '최근 $n회';
                    return FilterChip(
                      label: Text(label),
                      selected: selected,
                      onSelected: (_) {
                        setState(() => _coRecentN = n);
                        _loadCoOccurrence();
                      },
                    );
                  })
                  .toList(growable: false),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.calendar_month_outlined,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '집계범위 ${_coFromRound}~${_coToRound}회',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.my_location_outlined,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '기준번호 등장 ${_coTargetAppearCount}회',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_coLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_coTargetAppearCount == 0 || _coItems.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('해당 구간에 기준 번호 출현 데이터가 없습니다.'),
              )
            else
              ..._coItems.map((item) {
                final double ratio = maxFreq == 0 ? 0 : item.freq / maxFreq;
                final double appearPct = _coTargetAppearCount == 0
                    ? 0
                    : item.freq / _coTargetAppearCount * 100;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      _SmallBall(number: item.number),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 64,
                        child: Text(
                          '${item.number}번',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: ratio,
                            minHeight: 12,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: AlwaysStoppedAnimation(
                              _ballColor(item.number),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 76,
                        child: Text(
                          '${item.freq}회 (${appearPct.toStringAsFixed(1)}%)',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _CoOccurrenceItem {
  const _CoOccurrenceItem({required this.number, required this.freq});

  final int number;
  final int freq;
}

// ─────────────────────────────────────────
// 공통 위젯
// ─────────────────────────────────────────

class _HotColdCard extends StatelessWidget {
  const _HotColdCard({
    required this.title,
    required this.numbers,
    required this.isHot,
  });

  final String title;
  final List<NumberStat> numbers;
  final bool isHot;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: numbers
                  .map((s) => _SmallBall(number: s.number))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallBall extends StatelessWidget {
  const _SmallBall({required this.number});
  final int number;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 14,
      backgroundColor: _ballColor(number),
      child: Text(
        '$number',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: _ballTextColor(number),
        ),
      ),
    );
  }
}

class _FreqBall extends StatelessWidget {
  const _FreqBall({required this.number, required this.freq});

  final int number;
  final int freq;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SmallBall(number: number),
          const SizedBox(width: 4),
          Text(
            '${freq}회',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _AbsenceRow extends StatelessWidget {
  const _AbsenceRow({required this.stat, required this.latestRound});
  final NumberStat stat;
  final int latestRound;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _SmallBall(number: stat.number),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${stat.absenceCount}회째 미출현',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  stat.lastAppeared == 0
                      ? '출현 기록 없음'
                      : '최근 출현: ${stat.lastAppeared}회',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: stat.absenceCount > 20
                  ? Colors.red.shade100
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${stat.absenceCount}회',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: stat.absenceCount > 20
                    ? Colors.red.shade700
                    : Colors.grey.shade700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: iconColor),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _RoundRow extends StatelessWidget {
  const _RoundRow({required this.pattern});
  final RoundPattern pattern;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${pattern.round}회',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '합계 ${pattern.sum}  홀${pattern.oddCount}:짝${pattern.evenCount}  연번 ${pattern.consecutiveCount}쌍',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: pattern.numbers
                .map((n) => _SmallBall(number: n))
                .toList(),
          ),
          const Divider(height: 16),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// 헬퍼 클래스
// ─────────────────────────────────────────

enum _SortMode { byNumber, byFreqDesc, byFreqAsc, byAbsence }

class _FilterOption {
  const _FilterOption({required this.label, required this.value});
  final String label;
  final int? value;
}

// ─────────────────────────────────────────
// 연번 출현 회차 바텀시트
// ─────────────────────────────────────────
class _ConsecutiveRoundsSheet extends StatefulWidget {
  const _ConsecutiveRoundsSheet({
    required this.seqNums,
    required this.sequenceLength,
  });

  final List<int> seqNums;
  final int sequenceLength;

  @override
  State<_ConsecutiveRoundsSheet> createState() =>
      _ConsecutiveRoundsSheetState();
}

class _ConsecutiveRoundsSheetState extends State<_ConsecutiveRoundsSheet> {
  List<Map<String, dynamic>>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await LottoDatabase.instance.getConsecutiveSequenceRounds(
      startNumber: widget.seqNums.first,
      sequenceLength: widget.sequenceLength,
    );
    if (mounted) setState(() => _rows = rows);
  }

  @override
  Widget build(BuildContext context) {
    final seqSet = widget.seqNums.toSet();
    final label = widget.seqNums.join('~');

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (_, controller) => Column(
        children: [
          // 핸들
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // 타이틀
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                Text(
                  '$label 연번 출현 회차',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_rows != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '총 ${_rows!.length}회',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          // 목록
          Expanded(
            child: _rows == null
                ? const Center(child: CircularProgressIndicator())
                : _rows!.isEmpty
                ? const Center(child: Text('출현 기록이 없습니다'))
                : ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _rows!.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (_, i) {
                      final row = _rows![i];
                      final round = row['round'] as int;
                      final nums = [
                        row['num1'] as int, row['num2'] as int,
                        row['num3'] as int, row['num4'] as int,
                        row['num5'] as int, row['num6'] as int,
                      ]..sort();

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 52,
                              child: Text(
                                '$round회',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Wrap(
                                spacing: 5,
                                runSpacing: 4,
                                children: [
                                  ...nums.map((n) => _ConsecBall(
                                        number: n,
                                        highlight: seqSet.contains(n),
                                      )),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConsecBall extends StatelessWidget {
  const _ConsecBall({
    required this.number,
    required this.highlight,
    this.isBonus = false,
  });

  final int number;
  final bool highlight;
  final bool isBonus;

  @override
  Widget build(BuildContext context) {
    final color = _ballColor(number);
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: highlight ? color : Colors.grey.shade200,
        border: isBonus
            ? Border.all(color: Colors.orange.shade400, width: 1.5)
            : null,
      ),
      child: Center(
        child: Text(
          '$number',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: highlight ? _ballTextColor(number) : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }
}
