import 'package:flutter/material.dart';

import '../db/lotto_database.dart';
import '../services/lotto_sync_service.dart';
import '../widgets/mini_lotto_ball.dart';

class DrawHistoryTab extends StatefulWidget {
  const DrawHistoryTab({super.key});

  @override
  State<DrawHistoryTab> createState() => _DrawHistoryTabState();
}

class _DrawHistoryTabState extends State<DrawHistoryTab> {
  final List<Map<String, dynamic>> _results = [];
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  bool _hasMore = true;
  int _offset = 0;
  static const int _pageSize = 50;

  int? _selectedRound;
  Map<String, dynamic>? _selectedDetail;
  bool _loadingDetail = false;

  @override
  void initState() {
    super.initState();
    _loadMore().then((_) => _loadLatestDetail());
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !_isLoading &&
          _hasMore) {
        _loadMore();
      }
    });
  }

  Future<void> _loadLatestDetail() async {
    final latest = await LottoDatabase.instance.getLatestRound();
    if (latest <= 0) return;
    setState(() {
      _selectedRound = latest;
      _loadingDetail = true;
    });
    final detail = await LottoSyncService.fetchDrawDetail(latest);
    if (!mounted) return;
    setState(() {
      _selectedDetail = detail;
      _loadingDetail = false;
    });
  }

  Future<void> _selectRound(int round) async {
    Map<String, dynamic>? detail;
    if (_selectedRound == round && _selectedDetail != null) {
      detail = _selectedDetail;
    } else {
      setState(() {
        _selectedRound = round;
        _selectedDetail = null;
        _loadingDetail = true;
      });
      detail = await LottoSyncService.fetchDrawDetail(round);
      if (!mounted) return;
      setState(() {
        _selectedDetail = detail;
        _loadingDetail = false;
      });
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DrawDetailSheet(round: round, detail: detail),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    final List<Map<String, dynamic>> rows = await LottoDatabase.instance
        .getAllDrawResults(limit: _pageSize, offset: _offset);
    setState(() {
      _results.addAll(rows);
      _offset += rows.length;
      _hasMore = rows.length == _pageSize;
      _isLoading = false;
    });
  }

  Future<void> _search(String query) async {
    setState(() {
      _results.clear();
      _offset = 0;
      _hasMore = true;
      _isLoading = true;
    });
    final List<Map<String, dynamic>> rows = await LottoDatabase.instance
        .getAllDrawResults(
          searchRound: query.isEmpty ? null : query,
          limit: query.isEmpty ? _pageSize : 1000,
          offset: 0,
        );
    setState(() {
      _results.addAll(rows);
      _offset = rows.length;
      _hasMore = query.isEmpty && rows.length == _pageSize;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      behavior: HitTestBehavior.translucent,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '회차 검색 (예: 1150)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _search('');
                          FocusScope.of(context).unfocus();
                        },
                      )
                    : null,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: _search,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
            ),
          ),
          if (_selectedRound != null)
            _LatestPrizeCompactCard(
              round: _selectedRound!,
              detail: _selectedDetail,
              isLoading: _loadingDetail,
              onTap: () => _selectRound(_selectedRound!),
            ),
          Expanded(
            child: _results.isEmpty && !_isLoading
                ? const Center(child: Text('결과가 없습니다'))
                : ListView.builder(
                    controller: _scrollController,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: _results.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _results.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final Map<String, dynamic> row = _results[index];
                      final int round = row['round'] as int;
                      final List<int> nums = [
                        row['num1'] as int,
                        row['num2'] as int,
                        row['num3'] as int,
                        row['num4'] as int,
                        row['num5'] as int,
                        row['num6'] as int,
                      ];
                      final int bonus = row['bonus'] as int;
                      final String date = LottoDatabase.drawDateFromRound(
                        round,
                      );
                      return GestureDetector(
                        onTap: () => _selectRound(round),
                        child: _DrawResultItem(
                          round: round,
                          date: date,
                          numbers: nums,
                          bonus: bonus,
                          isSelected: _selectedRound == round,
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

// 최신 회차 컴팩트 카드 (1등 당첨금만 표시, 탭하면 상세 바텀시트)
class _LatestPrizeCompactCard extends StatelessWidget {
  const _LatestPrizeCompactCard({
    required this.round,
    required this.detail,
    required this.isLoading,
    required this.onTap,
  });

  final int round;
  final Map<String, dynamic>? detail;
  final bool isLoading;
  final VoidCallback onTap;

  String _formatMoney(dynamic value) {
    if (value == null) return '-';
    final n = (value as num).toInt();
    if (n >= 100000000) {
      final eok = n / 100000000;
      return '${eok.toStringAsFixed(eok % 1 == 0 ? 0 : 1)}억원';
    }
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(0)}만원';
    return '$n원';
  }

  @override
  Widget build(BuildContext context) {
    final prizes = detail?['prizes'] as Map<String, dynamic>?;
    final prize1 = prizes?['1'] as Map<String, dynamic>?;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.primaryContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
          ),
        ),
        child: isLoading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$round회 최신 당첨',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          prize1 != null
                              ? '1등 ${_formatMoney(prize1['perPrize'])} × ${prize1['count']}명'
                              : '당첨금 정보 없음',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        '상세보기',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

// 바텀시트: 당첨금 / 당첨점 탭
class _DrawDetailSheet extends StatefulWidget {
  const _DrawDetailSheet({required this.round, required this.detail});
  final int round;
  final Map<String, dynamic>? detail;

  @override
  State<_DrawDetailSheet> createState() => _DrawDetailSheetState();
}

class _DrawDetailSheetState extends State<_DrawDetailSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _formatMoney(dynamic value) {
    if (value == null) return '-';
    final n = (value as num).toInt();
    if (n >= 100000000) {
      final eok = n / 100000000;
      return '${eok.toStringAsFixed(eok % 1 == 0 ? 0 : 1)}억원';
    }
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(0)}만원';
    return '$n원';
  }

  @override
  Widget build(BuildContext context) {
    final prizes = widget.detail?['prizes'] as Map<String, dynamic>?;
    final storesRaw = widget.detail?['stores'];
    final grade1Stores = storesRaw != null
        ? (storesRaw as List)
              .where((s) => (s as Map)['grade'] == 1)
              .cast<Map>()
              .toList()
        : <Map>[];

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scrollController) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${widget.round}회 당첨 상세',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: '당첨금'),
              Tab(text: '당첨점 확인'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // 당첨금 탭
                prizes == null
                    ? Center(
                        child: Text(
                          '${widget.round}회 당첨금 정보 없음\n(구버전 회차)',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[500]),
                        ),
                      )
                    : ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        children: List.generate(5, (i) {
                          final grade = i + 1;
                          final g =
                              prizes[grade.toString()] as Map<String, dynamic>?;
                          final count = g?['count'] ?? 0;
                          final per = g?['perPrize'];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    color: [
                                      const Color(0xFFFFD700),
                                      const Color(0xFFC0C0C0),
                                      const Color(0xFFCD7F32),
                                      Colors.blue.shade100,
                                      Colors.green.shade100,
                                    ][i],
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Center(
                                    child: Text(
                                      '$grade등',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: i < 3
                                            ? Colors.black87
                                            : Colors.black54,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '$count명',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Text(
                                  _formatMoney(per),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ),
                // 당첨점 탭
                grade1Stores.isEmpty
                    ? const Center(child: Text('당첨점 정보 없음'))
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: grade1Stores.length,
                        itemBuilder: (_, i) {
                          final s = grade1Stores[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.store_outlined,
                                  size: 16,
                                  color: Colors.grey,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s['name'] as String? ?? '',
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        s['address'] as String? ?? '',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[500],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DrawResultItem extends StatelessWidget {
  const _DrawResultItem({
    required this.round,
    required this.date,
    required this.numbers,
    required this.bonus,
    this.isSelected = false,
  });

  final int round;
  final String date;
  final List<int> numbers;
  final int bonus;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: isSelected
              ? BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 1.5,
                )
              : BorderSide.none,
        ),
        color: isSelected
            ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3)
            : Theme.of(context).colorScheme.surfaceContainerLowest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$round회',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      date.substring(2),
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: numbers
                      .map((n) => MiniLottoBall(number: n))
                      .toList(),
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                '+',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(width: 6),
              MiniLottoBall(number: bonus, isBonus: true),
            ],
          ),
        ),
      ),
    );
  }
}
