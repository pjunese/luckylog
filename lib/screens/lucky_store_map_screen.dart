import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../db/lotto_database.dart';

// ─────────────────────────────────────────
// 명당지도 화면
// ─────────────────────────────────────────
class LuckyStoreMapScreen extends StatefulWidget {
  const LuckyStoreMapScreen({super.key});

  @override
  State<LuckyStoreMapScreen> createState() => _LuckyStoreMapScreenState();
}

class _LuckyStoreMapScreenState extends State<LuckyStoreMapScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _isLoading = true;
  NaverMapController? _mapController;

  // 월별 데이터
  Map<String, List<Map<String, dynamic>>> _storesByMonth = {};
  List<String> _availableMonths = []; // ["2026-05", "2026-04", ...]
  String _selectedMonth = '';
  int _gradeFilter = 0; // 0=전체, 1=1등, 2=2등

  List<Map<String, dynamic>> get _currentStores {
    final all = _storesByMonth[_selectedMonth] ?? [];
    if (_gradeFilter == 0) return all;
    return all.where((s) => (s['minGrade'] as int) == _gradeFilter).toList();
  }

  // 시작 기준: 2026년 4월부터만 표시
  static final DateTime _startDate = DateTime(2026, 4, 1);

  /// 추첨일 문자열 "YYYY-MM-DD" → "YYYY-MM"
  String _dateToMonth(String drawDate) {
    if (drawDate.length < 7) return '';
    return drawDate.substring(0, 7);
  }

  /// "2026-05" → "5월"
  String _monthLabel(String ym) {
    final parts = ym.split('-');
    return '${int.parse(parts[1])}월';
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadStores();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadStores() async {
    try {
      // 충분히 최근 데이터 로드 (2026-04부터의 데이터를 포함하도록)
      final snapshot = await FirebaseFirestore.instance
          .collection('lotto_draws')
          .orderBy('round', descending: true)
          .limit(20)
          .get();

      // 월별 storeMap 구성
      final Map<String, Map<String, Map<String, dynamic>>> byMonth = {};

      for (final doc in snapshot.docs) {
        final round = int.tryParse(doc.id) ?? 0;
        final drawDate = LottoDatabase.drawDateFromRound(round);

        // 2026-04 이전 회차 스킵
        final dt = DateTime.tryParse(drawDate);
        if (dt == null || dt.isBefore(_startDate)) continue;

        final month = _dateToMonth(drawDate);
        final data = doc.data();
        final storesRaw = data['stores'];
        final stores = (storesRaw is List) ? storesRaw : <dynamic>[];

        byMonth.putIfAbsent(month, () => {});

        for (final s in stores) {
          final store = s as Map<String, dynamic>;
          final grade = (store['grade'] as num?)?.toInt() ?? 1;
          if (grade > 2) continue;

          final key = '${store['name']}_${store['address']}';
          final storeMap = byMonth[month]!;

          if (storeMap.containsKey(key)) {
            storeMap[key]!['totalWins'] =
                (storeMap[key]!['totalWins'] as int) +
                (store['count'] as int? ?? 1);
            final prev = storeMap[key]!['minGrade'] as int;
            if (grade < prev) storeMap[key]!['minGrade'] = grade;
            final gk = 'grade${grade}Wins';
            storeMap[key]![gk] =
                ((storeMap[key]![gk] as int?) ?? 0) +
                (store['count'] as int? ?? 1);
          } else {
            storeMap[key] = {
              'name': store['name'],
              'address': store['address'],
              'lat': store['lat'],
              'lng': store['lng'],
              'totalWins': store['count'] as int? ?? 1,
              'minGrade': grade,
              'grade1Wins': grade == 1 ? (store['count'] as int? ?? 1) : 0,
              'grade2Wins': grade == 2 ? (store['count'] as int? ?? 1) : 0,
            };
          }
        }
      }

      // 월별 정렬 (내림차순 최신 먼저)
      final months = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));

      // 각 월 내 정렬: 1등 우선 → 총 당첨수
      final storesByMonth = <String, List<Map<String, dynamic>>>{};
      for (final m in months) {
        final list = byMonth[m]!.values.toList()
          ..sort((a, b) {
            final aG1 = (a['grade1Wins'] as int) > 0 ? 1 : 0;
            final bG1 = (b['grade1Wins'] as int) > 0 ? 1 : 0;
            if (aG1 != bG1) return bG1.compareTo(aG1);
            return (b['totalWins'] as int).compareTo(a['totalWins'] as int);
          });
        storesByMonth[m] = list;
      }

      setState(() {
        _storesByMonth = storesByMonth;
        _availableMonths = months;
        _selectedMonth = months.isNotEmpty ? months.first : '';
        _isLoading = false;
      });

      // 검증용 로그
      for (final m in months) {
        final list = storesByMonth[m]!;
        final g1Stores = list.where((s) => (s['grade1Wins'] as int) > 0).length;
        final g2Stores = list.where((s) => (s['grade2Wins'] as int) > 0).length;
        final bothStores = list
            .where(
              (s) =>
                  (s['grade1Wins'] as int) > 0 && (s['grade2Wins'] as int) > 0,
            )
            .length;
        debugPrint(
          '🗺️ [$m] 총 ${list.length}곳 | 1등 $g1Stores곳 | 2등 $g2Stores곳 | 1+2등 동시 $bothStores곳',
        );
        // 상위 3개만 자세히
        for (final s in list.take(3)) {
          debugPrint(
            '   - ${s['name']}: minGrade=${s['minGrade']}, 1등×${s['grade1Wins']}, 2등×${s['grade2Wins']}',
          );
        }
      }
      _addMarkers();
    } catch (e) {
      debugPrint('🗺️ loadStores error: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _selectMonth(String month) async {
    setState(() {
      _selectedMonth = month;
      _gradeFilter = 0;
    });
    await _mapController?.clearOverlays();
    await _addMarkers();
  }

  Future<void> _applyFilter(int grade) async {
    setState(() => _gradeFilter = grade);
    await _mapController?.clearOverlays();
    await _addMarkers();
  }

  Future<void> _addMarkers() async {
    if (_mapController == null) return;
    final stores = _currentStores;
    final markers = <NMarker>[];

    for (int i = 0; i < stores.length; i++) {
      final s = stores[i];
      final lat = s['lat'] as double?;
      final lng = s['lng'] as double?;
      if (lat == null || lng == null) continue;

      final grade = s['minGrade'] as int;
      final grade1Wins = s['grade1Wins'] as int;
      final grade2Wins = s['grade2Wins'] as int;
      // 표시 등수의 실제 당첨 횟수만 사용 (totalWins 섞이지 않도록)
      final displayWins = grade == 1 ? grade1Wins : grade2Wins;
      final hasBothGrades = grade1Wins > 0 && grade2Wins > 0;

      // 색상
      final Color pinColor = grade == 1
          ? (displayWins >= 2
                ? const Color(0xFFF57F17)
                : const Color(0xFFFBC400))
          : const Color(0xFF2A75F3);

      final icon = await NOverlayImage.fromWidget(
        widget: _MapMarkerWidget(
          grade: grade,
          wins: displayWins,
          color: pinColor,
          hasBoth: hasBothGrades,
        ),
        size: const Size(48, 56),
        context: context,
      );

      final marker = NMarker(
        id: 'store_$i',
        position: NLatLng(lat, lng),
        icon: icon,
        size: const Size(48, 56),
      );
      marker.setOnTapListener((_) => _showStoreDetail(s));
      markers.add(marker);
    }
    await _mapController!.addOverlayAll(markers.toSet());
  }

  void _showStoreDetail(Map<String, dynamic> store) {
    final grade1 = store['grade1Wins'] as int;
    final grade2 = store['grade2Wins'] as int;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 판매점명
            Text(
              store['name'] as String,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  size: 14,
                  color: Colors.grey,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    store['address'] as String,
                    style: TextStyle(color: Colors.grey[600], fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 등수별 당첨 배지
            Row(
              children: [
                if (grade1 > 0) ...[
                  _GradeBadge(grade: 1, count: grade1),
                  const SizedBox(width: 8),
                ],
                if (grade2 > 0) _GradeBadge(grade: 2, count: grade2),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '최근 1년(52회차) 기준',
              style: TextStyle(color: Colors.grey[400], fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('복권 판매점'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.emoji_events_outlined), text: '명당지도'),
            Tab(icon: Icon(Icons.near_me_outlined), text: '주변 판매점'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildLuckyMap(),
          const _NearbyStoresTab(
            kakaoRestApiKey: '',
          ),
        ],
      ),
    );
  }

  Widget _buildLuckyMap() {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const Center(
        child: Text(
          '명당지도는 iOS/Android에서만 지원됩니다.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return Stack(
      children: [
        NaverMap(
          forceGesture: true,
          options: const NaverMapViewOptions(
            initialCameraPosition: NCameraPosition(
              target: NLatLng(36.5, 127.5),
              zoom: 6.5,
            ),
            mapType: NMapType.basic,
          ),
          onMapReady: (controller) {
            _mapController = controller;
            if (!_isLoading) _addMarkers();
          },
        ),
        if (_isLoading) const Center(child: CircularProgressIndicator()),

        // 상단 컨트롤 (월 선택 + 등수 필터)
        Positioned(
          top: 12,
          left: 16,
          right: 16,
          child: Column(
            children: [
              // 월 선택기
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _availableMonths
                      .map(
                        (m) => _FilterChipBtn(
                          label: _monthLabel(m),
                          selected: _selectedMonth == m,
                          onTap: () => _selectMonth(m),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 8),
              // 등수 필터
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FilterChipBtn(
                      label: '전체',
                      selected: _gradeFilter == 0,
                      onTap: () => _applyFilter(0),
                    ),
                    _FilterChipBtn(
                      label: '1등',
                      selected: _gradeFilter == 1,
                      color: const Color(0xFFFBC400),
                      onTap: () => _applyFilter(1),
                    ),
                    _FilterChipBtn(
                      label: '2등',
                      selected: _gradeFilter == 2,
                      color: const Color(0xFF2A75F3),
                      onTap: () => _applyFilter(2),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 범례
        Positioned(
          bottom: 20,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 8),
              ],
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _LegendItem(color: Color(0xFFFBC400), label: '1등 배출'),
                SizedBox(height: 6),
                _LegendItem(color: Color(0xFF2A75F3), label: '2등 배출'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── 주변 판매점 탭 ──────────────────────────────────────────────
class _NearbyStoresTab extends StatefulWidget {
  const _NearbyStoresTab({required this.kakaoRestApiKey});
  final String kakaoRestApiKey;

  @override
  State<_NearbyStoresTab> createState() => _NearbyStoresTabState();
}

class _NearbyStoresTabState extends State<_NearbyStoresTab> {
  bool _isLoading = false;
  String? _error;
  List<Map<String, dynamic>> _places = [];

  Future<void> _searchNearby() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // 위치 권한 확인
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever ||
          perm == LocationPermission.denied) {
        setState(() {
          _error = '위치 권한이 필요합니다.';
          _isLoading = false;
        });
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      // 카카오 로컬 API 호출
      final uri = Uri.parse(
        'https://dapi.kakao.com/v2/local/search/keyword.json'
        '?query=복권&x=${pos.longitude}&y=${pos.latitude}&radius=3000&size=15&sort=distance',
      );
      final resp = await http.get(
        uri,
        headers: {'Authorization': 'KakaoAK ${widget.kakaoRestApiKey}'},
      );

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final docs = (data['documents'] as List<dynamic>);
        setState(() {
          _places = docs
              .map(
                (d) => {
                  'name': d['place_name'] as String,
                  'address':
                      d['road_address_name'] as String? ??
                      d['address_name'] as String? ??
                      '',
                  'distance':
                      int.tryParse(d['distance'] as String? ?? '0') ?? 0,
                  'lat': double.tryParse(d['y'] as String? ?? '0') ?? 0.0,
                  'lng': double.tryParse(d['x'] as String? ?? '0') ?? 0.0,
                  'url': d['place_url'] as String? ?? '',
                },
              )
              .toList();
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = '검색 실패 (${resp.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = '오류: $e';
        _isLoading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _searchNearby();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('주변 복권 판매점 검색 중...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _searchNearby,
              child: const Text('다시 시도'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 헤더
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
          child: Row(
            children: [
              Icon(Icons.location_on, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                '내 위치 반경 3km · ${_places.length}개 판매점',
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _searchNearby,
                child: Icon(Icons.refresh, size: 20, color: cs.primary),
              ),
            ],
          ),
        ),
        // 목록
        Expanded(
          child: _places.isEmpty
              ? Center(
                  child: Text(
                    '주변 3km 내 복권 판매점이 없습니다.',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                )
              : ListView.separated(
                  itemCount: _places.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final p = _places[i];
                    final dist = p['distance'] as int;
                    final distStr = dist >= 1000
                        ? '${(dist / 1000).toStringAsFixed(1)}km'
                        : '${dist}m';
                    return ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ),
                      title: Text(
                        p['name'] as String,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        p['address'] as String,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            distStr,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: cs.primary,
                            ),
                          ),
                        ],
                      ),
                      onTap: () {
                        final url = p['url'] as String;
                        if (url.isNotEmpty) launchUrl(Uri.parse(url));
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// 지도 마커 위젯
class _MapMarkerWidget extends StatelessWidget {
  const _MapMarkerWidget({
    required this.grade,
    required this.wins,
    required this.color,
    this.hasBoth = false,
  });
  final int grade;
  final int wins;
  final Color color;
  final bool hasBoth; // 1등+2등 둘 다 있는 경우

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  wins > 1 ? '$grade등\n×$wins' : '$grade등',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: grade == 1 ? Colors.black87 : Colors.white,
                    fontSize: wins > 1 ? 10 : 12,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
              ),
            ),
            // 1+2등 동시 보유 표시
            if (hasBoth)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: grade == 1
                        ? const Color(0xFF2A75F3)
                        : const Color(0xFFFBC400),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Center(
                    child: Text(
                      grade == 1 ? '2' : '1',
                      style: TextStyle(
                        color: grade == 1 ? Colors.white : Colors.black87,
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        // 핀 꼬리
        CustomPaint(
          size: const Size(10, 8),
          painter: _PinTailPainter(color: color),
        ),
      ],
    );
  }
}

class _PinTailPainter extends CustomPainter {
  const _PinTailPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_PinTailPainter old) => old.color != color;
}

// 바텀시트 등수 배지
class _GradeBadge extends StatelessWidget {
  const _GradeBadge({required this.grade, required this.count});
  final int grade;
  final int count;

  @override
  Widget build(BuildContext context) {
    final color = grade == 1
        ? const Color(0xFFFBC400)
        : const Color(0xFF2A75F3);
    final textColor = grade == 1 ? Colors.black87 : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$grade등 $count회',
        style: TextStyle(
          color: textColor,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// 필터 칩 버튼
class _FilterChipBtn extends StatelessWidget {
  const _FilterChipBtn({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final activeColor = color ?? Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected
                ? (color == const Color(0xFFFBC400)
                      ? Colors.black87
                      : Colors.white)
                : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
