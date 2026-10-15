import '../widgets/app_snack_bar.dart';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';

import '../db/lotto_database.dart';
import '../models/draw_result.dart';
import '../models/purchase_record.dart';
import '../services/apple_auth_service.dart';
import '../services/firebase_auth_bridge.dart';
import '../services/user_data_sync_service.dart';
import '../services/kakao_auth_service.dart';
import '../services/notification_service.dart';
import '../services/share_service.dart';
import '../services/user_service.dart';
import '../widgets/result_share_card.dart';
import '../services/purchase_insights_controller.dart';
import 'purchase_calendar_tab.dart';

class ProfileTab extends StatefulWidget {
  const ProfileTab({
    super.key,
    required this.onLogout,
    required this.insights,
    required this.onRequireLogin,
    required this.purchaseHistory,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final Future<void> Function() onLogout;
  final PurchaseInsightsController insights;
  final VoidCallback onRequireLogin;
  final List<PurchaseRecord> purchaseHistory;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeModeChanged;

  @override
  State<ProfileTab> createState() => ProfileTabState();
}

class ProfileTabState extends State<ProfileTab>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int _recordsRevision = 0;
  void openRecords() {
    if (!mounted) return;
    setState(() => _recordsRevision++);
    _tabs.animateTo(0);
  }

  @override
  void dispose() {
    widget.insights.removeListener(_loadDrawCache);
    _tabs.dispose();
    super.dispose();
  }

  String _nickname = '';
  String? _imagePath;
  bool _loading = true;
  bool _recovering = false;
  int _notificationRequest = 0;
  int _legacyCount = 0;
  int _guestCount = 0;
  // 당첨 기록 캐시 (round → DrawResult)
  final Map<int, DrawResult> _drawCache = {};
  // 회차별 당첨금 캐시 (round → prizes) — 1~3등은 회차마다 달라 서버 값이 필요
  final Map<int, Map<String, dynamic>> _prizeCache = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    widget.insights.addListener(_loadDrawCache);
    _load();
    _loadNotifSetting();
    _loadDrawCache();
  }

  @override
  void didUpdateWidget(ProfileTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.purchaseHistory != widget.purchaseHistory) {
      _loadDrawCache();
      _load();
    }
  }

  Future<void> _loadDrawCache() async {
    if (!mounted) return;
    setState(() {
      _drawCache
        ..clear()
        ..addAll(widget.insights.value.draws);
    });
    await _loadPrizeCache();
  }

  String? _calcPrize(List<int> game, DrawResult draw) {
    final matched = game.where((n) => draw.winningNumbers.contains(n)).length;
    final hasBonus = game.contains(draw.bonusNumber);
    if (matched == 6) return '1등';
    if (matched == 5 && hasBonus) return '2등';
    if (matched == 5) return '3등';
    if (matched == 4) return '4등';
    if (matched == 3) return '5등';
    return null;
  }

  Color _prizeBadgeColor(String prize) {
    switch (prize) {
      case '1등':
        return const Color(0xFFE53935);
      case '2등':
        return const Color(0xFFE67E22);
      case '3등':
        return const Color(0xFF8E24AA);
      case '4등':
        return const Color(0xFF1E88E5);
      case '5등':
        return const Color(0xFF43A047);
      default:
        return Colors.grey;
    }
  }

  /// 회차별 실제 당첨금 (Firestore에서 수집한 1개당 당첨금).
  /// 1~3등은 회차마다 달라서 이 값이 있어야 정확하다.
  int _prizeAmount(int round, String prize) {
    final rank = prize.replaceAll('등', '');
    final perPrize =
        (_prizeCache[round]?[rank]?['perPrize'] as num?)?.toInt() ?? 0;
    if (perPrize > 0) return perPrize;

    // 아직 못 받았거나 수집 실패한 경우: 고정 등수만 폴백
    switch (prize) {
      case '4등':
        return 50000;
      case '5등':
        return 5000;
      default:
        return 0;
    }
  }

  /// 당첨 기록이 있는 회차의 당첨금 정보를 받아둔다.
  Future<void> _loadPrizeCache() async {
    if (!mounted) return;
    setState(() {
      _prizeCache.clear();
      for (final round in widget.insights.value.prizes.entries) {
        _prizeCache[round.key] = {
          for (final prize in round.value.entries)
            '${prize.key}': {'perPrize': prize.value},
        };
      }
    });
  }

  /// 당첨 결과를 이미지 카드로 만들어 공유한다.
  Future<void> _shareWin(_WinEntry w) async {
    final draw = _drawCache[w.round];
    if (draw == null) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        content: Text('당첨번호를 불러오는 중이에요. 잠시 후 다시 시도해주세요.'),
      );
      return;
    }

    final ok = await ShareService.shareWidget(
      widget: ResultShareCard(
        round: w.round,
        numbers: w.game,
        winningNumbers: draw.winningNumbers,
        bonusNumber: draw.bonusNumber,
        rankLabel: w.prize,
        amount: w.amount,
        drawDate: w.drawDate,
      ),
      size: const Size(340, 300),
      fileName: 'luckylog_${w.round}회',
    );

    if (!ok && mounted) {
      showAppSnackBar(context, content: Text('공유에 실패했어요.'));
    }
  }

  Widget _buildWinningHistoryCard(ColorScheme cs) {
    // 당첨 기록 모으기 (회차 내림차순, 같은 회차 내 등수 오름차순)
    final List<_WinEntry> wins = [];
    for (final record in widget.purchaseHistory) {
      final draw = _drawCache[record.round];
      if (draw == null) continue;
      for (int gi = 0; gi < record.games.length; gi++) {
        final prize = _calcPrize(record.games[gi], draw);
        if (prize != null) {
          wins.add(
            _WinEntry(
              round: record.round,
              drawDate: record.drawDate,
              gameIndex: gi,
              game: record.games[gi],
              prize: prize,
              amount: _prizeAmount(record.round, prize),
            ),
          );
        }
      }
    }
    wins.sort((a, b) {
      if (a.round != b.round) return b.round.compareTo(a.round);
      return a.prize.compareTo(b.prize);
    });

    final int totalAmount = wins.fold(0, (s, w) => s + w.amount);
    final int totalCount = wins.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.emoji_events, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  '당첨 기록',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: cs.primary,
                  ),
                ),
                const Spacer(),
                if (totalCount > 0)
                  Text(
                    '$totalCount건 / ${_formatWon(totalAmount)}',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (wins.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    '아직 당첨 기록이 없어요',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                ),
              )
            else
              ...wins
                  .take(20)
                  .map(
                    (w) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _prizeBadgeColor(w.prize),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              w.prize,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${w.round}회 · ${w.gameIndex + 1}게임',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (w.drawDate.isNotEmpty)
                                  Text(
                                    w.drawDate,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (w.amount > 0)
                            Text(
                              _formatWon(w.amount),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          else
                            Text(
                              '확인필요',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          IconButton(
                            onPressed: () => _shareWin(w),
                            icon: const Icon(Icons.ios_share, size: 18),
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.only(left: 8),
                            constraints: const BoxConstraints(),
                            tooltip: '결과 공유',
                            color: cs.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
            if (wins.length > 20)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '외 ${wins.length - 20}건',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _load() async {
    final owner = LottoDatabase.instance.accountKey;
    final number = owner == null
        ? 0
        : await UserService.cachedUserNumber(owner);
    final nickname = owner == null
        ? '게스트'
        : await UserService.getNickname(number);
    final legacyCount = await LottoDatabase.instance
        .getUnassignedLegacyRecordCount();
    final imagePath = owner == null
        ? null
        : await UserService.getProfileImagePath();
    final guestCount = await LottoDatabase.instance.getGuestRecordCount();
    if (!mounted || LottoDatabase.instance.accountKey != owner) return;
    setState(() {
      _legacyCount = legacyCount;
      _guestCount = guestCount;
      _nickname = nickname.isEmpty
          ? (KakaoAuthService.isLoggedIn ? '사용자' : '게스트')
          : nickname;
      _imagePath = imagePath;
      _loading = false;
    });
  }

  Future<void> _loadNotifSetting() async {
    // 값은 NotificationService.enabledNotifier 로 전달되어 토글이 자동 갱신된다.
    await NotificationService.isEnabled();
  }

  Future<void> _toggleNotif(bool value) async {
    final request = ++_notificationRequest;
    try {
      final applied = await NotificationService.setEnabled(value);
      if (mounted && request == _notificationRequest && value && !applied) {
        showAppSnackBar(
          context,
          content: const Text('기기에서 알림이 꺼져 있어요. 설정에서 허용해주세요.'),
          action: SnackBarAction(
            label: '설정 열기',
            onPressed: () {
              Geolocator.openAppSettings();
            },
          ),
        );
      }
    } catch (e) {
      if (mounted && request == _notificationRequest) {
        showAppSnackBar(context, content: Text('알림 설정을 저장하지 못했어요. 다시 시도해주세요.'));
      }
    }
  }

  Future<void> _recoverLegacyRecords({bool guest = false}) async {
    final owner = LottoDatabase.instance.accountKey;
    if (_recovering ||
        owner == null ||
        !FirebaseAuthBridge.isSignedInAs(owner)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(guest ? '게스트 기록 가져오기' : '이전 기록 가져오기'),
        content: Text(
          '이 기기에 남아 있는 ${guest ? '게스트 기록 $_guestCount' : '이전 버전 기록 $_legacyCount'}개를 현재 계정으로 가져옵니다. 모두 본인 기록일 때만 진행해주세요. 원래 기록은 보존됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('내 기록 가져오기'),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        LottoDatabase.instance.accountKey != owner ||
        !FirebaseAuthBridge.isSignedInAs(owner)) {
      return;
    }
    setState(() => _recovering = true);
    try {
      final count = guest
          ? await LottoDatabase.instance.claimGuestRecords()
          : await LottoDatabase.instance.claimUnassignedLegacyRecords();
      if (!mounted) return;
      await _load();
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text('$count개 기록을 가져왔습니다. 가져오지 못한 원래 기록도 보존되어 있습니다.'),
        );
      }
      await UserDataSyncService.pushLocalSnapshot(
        accountKey: owner,
        userNumber: 0,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text('기록은 이 기기에 보관되어 있습니다. 연결 후 동기화를 다시 시도해주세요.'),
        );
      }
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  Future<void> _pickImage() async {
    final owner = LottoDatabase.instance.accountKey;
    if (owner == null || !FirebaseAuthBridge.isSignedInAs(owner)) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked == null || !_matchesAccount(owner)) return;
    await UserService.saveProfileImagePath(picked.path, accountKey: owner);
    if (!_matchesAccount(owner)) return;
    setState(() => _imagePath = picked.path);
  }

  bool _matchesAccount(String? owner) =>
      mounted &&
      LottoDatabase.instance.accountKey == owner &&
      (owner == null
          ? !FirebaseAuthBridge.isSignedIn
          : FirebaseAuthBridge.isSignedInAs(owner));

  Future<void> _showFeedbackDialog() async {
    final owner = LottoDatabase.instance.accountKey;
    String selectedCategory = '일반 의견';
    const categories = ['일반 의견', '버그 신고', '기능 요청', '기타'];

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            scrollable: true,
            title: const Text('의견 보내기'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '유형',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: categories
                        .map(
                          (cat) => ChoiceChip(
                            label: Text(
                              cat,
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: selectedCategory == cat,
                            onSelected: (_) =>
                                setDialogState(() => selectedCategory = cat),
                            visualDensity: VisualDensity.compact,
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '내용',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: controller,
                    maxLines: 4,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      hintText: '불편한 점이나 개선 사항을 자유롭게 적어주세요.',
                      hintStyle: TextStyle(fontSize: 13),
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(10),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              TextButton(
                onPressed: () {
                  final text = controller.text.trim();
                  if (text.isEmpty) return;
                  Navigator.pop(ctx);
                  if (_matchesAccount(owner)) {
                    _submitFeedback(selectedCategory, text, owner);
                  }
                },
                child: const Text('보내기'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _submitFeedback(
    String category,
    String text,
    String? owner,
  ) async {
    try {
      final bool isLoggedIn =
          KakaoAuthService.isLoggedIn || AppleAuthService.isLoggedIn;
      final int userNum = owner == null
          ? 0
          : await UserService.cachedUserNumber(owner);
      if (!_matchesAccount(owner)) return;
      final String provider = AppleAuthService.isLoggedIn
          ? 'apple'
          : KakaoAuthService.isLoggedIn
          ? 'kakao'
          : 'guest';

      await FirebaseFirestore.instance.collection('feedback').add({
        'category': category,
        'text': text,
        'userNumber': isLoggedIn ? userNum : 0,
        'provider': provider,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      showAppSnackBar(
        context,
        content: Text('소중한 의견 감사합니다! 검토 후 반영할게요 🙏'),
        duration: Duration(seconds: 3),
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(context, content: Text('전송에 실패했습니다. 잠시 후 다시 시도해주세요.'));
    }
  }

  Future<void> _editNickname() async {
    final owner = LottoDatabase.instance.accountKey;
    if (owner == null || !FirebaseAuthBridge.isSignedInAs(owner)) return;
    final controller = TextEditingController(text: _nickname);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('닉네임 변경'),
        content: TextField(
          controller: controller,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '닉네임 입력'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || !_matchesAccount(owner)) return;
    await UserService.saveNickname(result, accountKey: owner);
    if (!_matchesAccount(owner)) return;
    setState(() => _nickname = result);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '기록'),
            Tab(text: '내 정보'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              PurchaseCalendarTab(
                key: ValueKey(_recordsRevision),
                controller: widget.insights,
              ),
              _buildProfile(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProfile(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final bool isLoggedIn =
        KakaoAuthService.isLoggedIn || AppleAuthService.isLoggedIn;
    final String loginProvider = AppleAuthService.isLoggedIn
        ? 'Apple'
        : 'kakao';
    final cs = Theme.of(context).colorScheme;

    // 구매 통계 계산
    final int totalGames = widget.purchaseHistory.fold(
      0,
      (total, r) => total + r.games.length,
    );
    final int totalSpent = totalGames * 1000;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
      children: [
        // ── 프로필 헤더 ──
        Center(
          child: GestureDetector(
            onTap: _pickImage,
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: const Color(0xFFFEE500),
                  backgroundImage: _imagePath != null
                      ? FileImage(File(_imagePath!))
                      : null,
                  child: _imagePath == null
                      ? const Icon(
                          Icons.person,
                          size: 44,
                          color: Colors.black54,
                        )
                      : null,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const Icon(Icons.camera_alt, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _nickname,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _editNickname,
              child: const Icon(Icons.edit, size: 18, color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            isLoggedIn ? '$loginProvider 계정 연동됨' : '게스트 모드 (로컬 저장)',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ),

        const SizedBox(height: 24),

        // ── 구매 통계 카드 ──
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '내 구매 통계',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _StatItem(
                        label: '총 구매 회차',
                        value:
                            '${widget.purchaseHistory.map((r) => r.round).toSet().length}회차',
                      ),
                    ),
                    Expanded(
                      child: _StatItem(label: '총 게임 수', value: '$totalGames게임'),
                    ),
                    Expanded(
                      child: _StatItem(
                        label: '총 지출',
                        value: _formatWon(totalSpent),
                        highlight: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 8),

        // ── 당첨 기록 카드 ──
        _buildWinningHistoryCard(cs),

        const SizedBox(height: 8),

        // ── 설정 섹션 ──
        Card(
          child: Column(
            children: [
              // 다크모드
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.dark_mode_outlined),
                        SizedBox(width: 12),
                        Expanded(child: Text('다크모드')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<ThemeMode>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity(
                          horizontal: -3,
                          vertical: -2,
                        ),
                      ),
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('라이트', style: TextStyle(fontSize: 11)),
                        ),
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('시스템', style: TextStyle(fontSize: 11)),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('다크', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                      selected: {widget.themeMode},
                      onSelectionChanged: (s) =>
                          widget.onThemeModeChanged(s.first),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              // 추첨 결과 알림
              // 첫 진입 권한 요청이 이 화면보다 늦게 끝나므로,
              // 값을 구독해서 나중에 바뀌어도 토글이 따라가게 한다.
              ValueListenableBuilder<bool>(
                valueListenable: NotificationService.enabledNotifier,
                builder: (context, enabled, _) => ValueListenableBuilder<bool>(
                  valueListenable: NotificationService.pendingNotifier,
                  builder: (context, pending, _) => SwitchListTile(
                    secondary: const Icon(Icons.notifications_outlined),
                    title: const Text('추첨 결과 알림'),
                    subtitle: Text(
                      pending ? '설정 저장됨 · 서버에 반영 중' : '매주 토요일 결과 푸시 알림',
                    ),
                    value: enabled,
                    onChanged: _toggleNotif,
                  ),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.feedback_outlined),
                title: const Text('의견 보내기'),
                subtitle: const Text('버그 신고, 기능 요청 등'),
                trailing: const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Colors.grey,
                ),
                onTap: _showFeedbackDialog,
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),

        if (isLoggedIn && _guestCount > 0)
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: Text('게스트 기록 $_guestCount개 가져오기'),
              subtitle: const Text('본인 기록을 현재 계정에 연결해 백업합니다.'),
              onTap: _recovering
                  ? null
                  : () => _recoverLegacyRecords(guest: true),
            ),
          ),
        if (_legacyCount > 0)
          Card(
            child: ListTile(
              leading: const Icon(Icons.restore),
              title: Text('이전 버전 기록 $_legacyCount개 보관 중'),
              subtitle: Text(
                isLoggedIn ? '본인 기록을 현재 계정으로 가져오기' : '로그인 후 본인 기록을 가져올 수 있습니다.',
              ),
              trailing: _recovering
                  ? const CircularProgressIndicator()
                  : const Icon(Icons.chevron_right),
              onTap: isLoggedIn && !_recovering
                  ? () => _recoverLegacyRecords()
                  : null,
            ),
          ),

        // ── 계정 섹션 ──
        Card(
          child: isLoggedIn
              ? ListTile(
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: const Text(
                    '로그아웃',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  onTap: () async {
                    try {
                      await widget.onLogout();
                    } catch (e) {
                      if (context.mounted) {
                        showAppSnackBar(
                          context,
                          content: Text(
                            '로그아웃을 완료하지 못했습니다. 인터넷 연결 후 다시 시도해주세요.',
                          ),
                        );
                      }
                    }
                  },
                )
              : ListTile(
                  leading: const Icon(Icons.login),
                  title: const Text('로그인 연결'),
                  subtitle: const Text('기기 변경/재설치 시 데이터 복원 가능'),
                  onTap: widget.onRequireLogin,
                ),
        ),
      ],
    );
  }

  String _formatWon(int amount) {
    if (amount >= 10000) {
      final man = amount ~/ 10000;
      final rem = amount % 10000;
      return rem == 0 ? '$man만원' : '$man만 $rem원';
    }
    return '$amount원';
  }
}

class _WinEntry {
  const _WinEntry({
    required this.round,
    required this.drawDate,
    required this.gameIndex,
    required this.game,
    required this.prize,
    required this.amount,
  });
  final int round;
  final String drawDate;
  final int gameIndex;
  final List<int> game;
  final String prize;
  final int amount;
}

class _StatItem extends StatelessWidget {
  const _StatItem({
    required this.label,
    required this.value,
    this.highlight = false,
  });
  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: highlight ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
