import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';

import 'db/lotto_database.dart';
import 'firebase_options.dart';
import 'models/number_set.dart';
import 'models/purchase_record.dart';
import 'screens/generator_tab.dart';
import 'screens/home_tab.dart';
import 'screens/login_screen.dart';
import 'screens/profile_tab.dart';
import 'screens/splash_screen.dart';
import 'screens/stats_screen.dart';
import 'screens/vault_tab.dart';
import 'services/apple_auth_service.dart';
import 'services/kakao_auth_service.dart';
import 'services/lotto_sync_service.dart';
import 'services/notification_router.dart';
import 'services/notification_service.dart';
import 'services/user_data_sync_service.dart';
import 'services/user_service.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (KakaoAuthService.isSupportedPlatform) {
    KakaoSdk.init(nativeAppKey: 'ec26372ba0fec512e3f8a00d0295d35c');
  }
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Crashlytics: Flutter 프레임워크 에러 자동 수집
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
  // Crashlytics: 비동기 에러 (Zone 밖) 자동 수집
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };
  if (Platform.isIOS || Platform.isAndroid) {
    await FlutterNaverMap().init(
      clientId: 'zrg9fcwgjs',
      onAuthFailed: (ex) => debugPrint('🗺️ NaverMap 인증 실패: $ex'),
    );
  }
  await LottoDatabase.instance.db;
  if (KakaoAuthService.isSupportedPlatform) {
    await KakaoAuthService.restoreSession();
  }
  if (AppleAuthService.isSupportedPlatform) {
    await AppleAuthService.restoreSession();
  }

  // 세션 복원된 계정으로 데이터 동기화
  final restoredKey =
      KakaoAuthService.accountKey ?? AppleAuthService.accountKey;
  final restoredUserNumber = KakaoAuthService.isLoggedIn
      ? KakaoAuthService.userNumber
      : AppleAuthService.userNumber;
  if (restoredKey != null) {
    await UserDataSyncService.syncOnLogin(
      accountKey: restoredKey,
      userNumber: restoredUserNumber,
    ).timeout(
      const Duration(seconds: 8),
      onTimeout: () => debugPrint('[UserSync] startup sync timeout (8s)'),
    );
  }

  unawaited(LottoSyncService.syncIfNeeded());
  // iOS 포그라운드에서도 알림 표시되도록 설정
  unawaited(
    FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    ),
  );
  // 로그인된 사용자는 FCM 토큰 동기화 (개인 당첨 알림용)
  final accountKey = restoredKey;
  if (accountKey != null && accountKey.isNotEmpty) {
    unawaited(UserService.syncFcmToken(accountKey));
  }

  // 앱이 완전히 종료된 상태에서 알림을 눌러 실행된 경우,
  // 메인 화면이 준비된 뒤 이동하도록 목적지를 보관해둔다.
  try {
    final initialMessage = await FirebaseMessaging.instance
        .getInitialMessage()
        .timeout(const Duration(seconds: 3));
    NotificationRouter.capturePending(initialMessage);
  } catch (e) {
    debugPrint('[FCM] getInitialMessage 실패: $e');
  }

  runApp(const LottoNoteApp());
}

class LottoNoteApp extends StatefulWidget {
  const LottoNoteApp({super.key});

  @override
  State<LottoNoteApp> createState() => _LottoNoteAppState();
}

class _LottoNoteAppState extends State<LottoNoteApp> {
  bool _showSplash = true;
  bool _enteredApp = KakaoAuthService.isLoggedIn || AppleAuthService.isLoggedIn;
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('themeMode') ?? 'system';
    if (!mounted) return;
    setState(() {
      _themeMode = saved == 'dark'
          ? ThemeMode.dark
          : saved == 'light'
          ? ThemeMode.light
          : ThemeMode.system;
    });
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'themeMode',
      mode == ThemeMode.dark
          ? 'dark'
          : mode == ThemeMode.light
          ? 'light'
          : 'system',
    );
    setState(() => _themeMode = mode);
  }

  Future<void> _onLoginSuccess() async {
    final accountKey =
        KakaoAuthService.accountKey ?? AppleAuthService.accountKey;
    final userNumber = KakaoAuthService.isLoggedIn
        ? KakaoAuthService.userNumber
        : AppleAuthService.userNumber;
    if (accountKey != null) {
      await UserDataSyncService.syncOnLogin(
        accountKey: accountKey,
        userNumber: userNumber,
      ).timeout(
        const Duration(seconds: 12),
        onTimeout: () => debugPrint('[UserSync] login sync timeout (12s)'),
      );
    }
    if (!mounted) {
      return;
    }
    setState(() => _enteredApp = true);
  }

  void _onLogout() {
    setState(() {});
  }

  void _onRequireLogin() {
    setState(() => _enteredApp = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Lotto Note',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: _showSplash
          ? SplashScreen(onComplete: () => setState(() => _showSplash = false))
          : _enteredApp
          ? MainTabScreen(
              onLogout: _onLogout,
              onRequireLogin: _onRequireLogin,
              themeMode: _themeMode,
              onThemeModeChanged: _setThemeMode,
            )
          : LoginScreen(onLoginSuccess: _onLoginSuccess),
    );
  }
}

class MainTabScreen extends StatefulWidget {
  const MainTabScreen({
    super.key,
    required this.onLogout,
    required this.onRequireLogin,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final VoidCallback onLogout;
  final VoidCallback onRequireLogin;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeModeChanged;

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _selectedIndex = 0;
  List<NumberSet> _savedSets = <NumberSet>[];
  List<PurchaseRecord> _purchaseHistory = <PurchaseRecord>[];
  final _vaultKey = GlobalKey<NumberSetVaultTabState>();
  StreamSubscription<RemoteMessage>? _notifTapSub;

  @override
  void initState() {
    super.initState();
    _loadSets();
    _loadHistory();

    // 종료 상태에서 알림으로 실행된 경우 (main()에서 보관해둔 목적지)
    final pending = NotificationRouter.consumePending();
    if (pending != null) {
      _goToNotificationTarget(pending);
    }

    // 백그라운드 상태에서 알림을 눌러 복귀한 경우
    _notifTapSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final target = NotificationRouter.parse(message);
      if (target != null) {
        _goToNotificationTarget(target);
      }
    });

    // 첫 진입 시 1회 알림 권한 요청.
    // 화면이 그려진 뒤 물어야 사용자가 맥락을 보고 판단할 수 있다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        unawaited(NotificationService.requestOnFirstLaunch());
      });
    });
  }

  @override
  void dispose() {
    _notifTapSub?.cancel();
    super.dispose();
  }

  /// 알림 목적지로 이동. 번호세트 탭이면 서브탭까지 맞춘다.
  void _goToNotificationTarget(NotificationTarget target) {
    if (!mounted) return;
    setState(() => _selectedIndex = target.mainTab);

    final int? sub = target.vaultSubTab;
    if (sub == null) return;

    // 번호세트 화면의 TabController가 준비된 뒤에 이동해야 한다.
    // 첫 프레임엔 아직 없을 수 있어 한 번 재시도한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = _vaultKey.currentState;
      if (state != null) {
        state.jumpToTab(sub);
        return;
      }
      Future.delayed(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        _vaultKey.currentState?.jumpToTab(sub);
      });
    });
  }

  void _syncSnapshotIfLoggedIn() {
    // 카카오/애플 중 로그인된 쪽 계정으로 백업한다.
    // (카카오만 확인하면 애플 사용자는 데이터가 서버에 올라가지 않아
    //  기기 변경·재설치 시 전부 유실된다)
    final accountKey =
        KakaoAuthService.accountKey ?? AppleAuthService.accountKey;
    if (accountKey == null) {
      return;
    }
    final userNumber = KakaoAuthService.isLoggedIn
        ? KakaoAuthService.userNumber
        : AppleAuthService.userNumber;
    unawaited(
      UserDataSyncService.pushLocalSnapshot(
        accountKey: accountKey,
        userNumber: userNumber,
      ).catchError((Object e, StackTrace st) {
        debugPrint('[UserSync] snapshot sync 실패: $e');
        debugPrint('$st');
      }),
    );
  }

  Future<void> _loadSets() async {
    final List<Map<String, dynamic>> rows = await LottoDatabase.instance
        .getAllNumberSets();
    if (!mounted) return;
    setState(() {
      _savedSets = rows.map(NumberSet.fromDb).toList();
    });
  }

  Future<void> _loadHistory() async {
    final List<Map<String, dynamic>> rows = await LottoDatabase.instance
        .getAllPurchaseHistory();
    if (!mounted) return;
    setState(() {
      _purchaseHistory = rows.map(PurchaseRecord.fromDb).toList();
    });
  }

  Future<void> _addNumberSet(List<List<int>> games) async {
    final List<List<int>> sorted = games
        .map((numbers) => List<int>.from(numbers)..sort())
        .toList(growable: false);
    await LottoDatabase.instance.insertNumberSet(games: sorted);
    await _loadSets();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _addPurchaseHistory(
    List<List<int>> games,
    int round,
    String source,
  ) async {
    await LottoDatabase.instance.insertPurchaseHistory(
      games: games,
      round: round,
      source: source,
    );
    await _loadHistory();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _deletePurchaseHistory(int id) async {
    await LottoDatabase.instance.deletePurchaseHistory(id);
    await _loadHistory();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _togglePurchased(int setId, bool value) async {
    await LottoDatabase.instance.updatePurchased(setId, isPurchased: value);
    await _loadSets();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _deleteSet(int setId) async {
    await LottoDatabase.instance.deleteNumberSet(setId);
    await _loadSets();
    _syncSnapshotIfLoggedIn();
  }

  @override
  Widget build(BuildContext context) {
    final List<_TabItem> tabs = <_TabItem>[
      _TabItem(
        title: '홈',
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        page: HomeTab(
          savedSets: _savedSets,
          purchaseHistory: _purchaseHistory,
          onSaveSet: _addNumberSet,
          onAddPurchaseHistory: _addPurchaseHistory,
          onNavigateToVault: (subTabIndex) {
            setState(() => _selectedIndex = 1);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _vaultKey.currentState?.jumpToTab(subTabIndex);
            });
          },
        ),
      ),
      _TabItem(
        title: '번호세트',
        icon: Icons.collections_bookmark_outlined,
        selectedIcon: Icons.collections_bookmark,
        page: NumberSetVaultTab(
          key: _vaultKey,
          savedSets: _savedSets,
          purchaseHistory: _purchaseHistory,
          onSaveSet: _addNumberSet,
          onDeleteSet: _deleteSet,
          onTogglePurchased: _togglePurchased,
          onAddPurchaseHistory: _addPurchaseHistory,
          onDeletePurchaseHistory: _deletePurchaseHistory,
        ),
      ),
      const _TabItem(
        title: '통계',
        icon: Icons.bar_chart_outlined,
        selectedIcon: Icons.bar_chart,
        page: _StatsTab(),
      ),
      _TabItem(
        title: '번호 생성',
        icon: Icons.auto_awesome_outlined,
        selectedIcon: Icons.auto_awesome,
        page: NumberGeneratorTab(onSaveSet: _addNumberSet),
      ),
      _TabItem(
        title: '마이페이지',
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        page: ProfileTab(
          onLogout: widget.onLogout,
          onRequireLogin: widget.onRequireLogin,
          purchaseHistory: _purchaseHistory,
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
        ),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(tabs[_selectedIndex].title)),
      body: IndexedStack(
        index: _selectedIndex,
        children: tabs.map((tab) => tab.page).toList(),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int index) {
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: tabs
            .map(
              (tab) => NavigationDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.selectedIcon),
                label: tab.title,
              ),
            )
            .toList(),
      ),
    );
  }
}

class _TabItem {
  const _TabItem({
    required this.title,
    required this.icon,
    required this.selectedIcon,
    required this.page,
  });

  final String title;
  final IconData icon;
  final IconData selectedIcon;
  final Widget page;
}

class _StatsTab extends StatelessWidget {
  const _StatsTab();

  @override
  Widget build(BuildContext context) {
    return const StatsScreen();
  }
}

// ─────────────────────────────────────────
// 당첨결과 탭
// ─────────────────────────────────────────
