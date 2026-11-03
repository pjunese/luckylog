import 'widgets/app_content_frame.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart' show appFlavor;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'widgets/app_snack_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart'
    show KakaoSdk;

import 'core/dev_kakao.dart';
import 'db/lotto_database.dart';
import 'firebase_options.dart';
import 'models/number_set.dart';
import 'models/purchase_record.dart';
import 'models/scanned_ticket.dart';
import 'screens/generator_tab.dart';
import 'screens/home_tab.dart';
import 'screens/login_screen.dart';
import 'screens/profile_tab.dart';
import 'screens/splash_screen.dart';
import 'screens/stats_screen.dart';
import 'screens/vault_tab.dart';
import 'services/apple_auth_service.dart';
import 'services/app_integrity_service.dart';
import 'services/firebase_auth_bridge.dart';
import 'services/kakao_auth_service.dart';
import 'services/lotto_sync_service.dart';
import 'services/purchase_insights_controller.dart';
import 'services/notification_router.dart';
import 'services/notification_service.dart';
import 'services/user_data_sync_service.dart';
import 'services/user_service.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (KakaoAuthService.isSupportedPlatform && KakaoAuthService.isConfigured) {
    KakaoSdk.init(
      nativeAppKey: appFlavor == 'dev'
          ? devKakaoNativeAppKey
          : 'ec26372ba0fec512e3f8a00d0295d35c',
    );
  }
  // Native dev configuration is registered for the separate .dev app ID.
  // Keep the existing production initialization unchanged.
  await Firebase.initializeApp(
    options: appFlavor == 'dev' ? null : DefaultFirebaseOptions.currentPlatform,
  );
  await AppIntegrityService.initialize();

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

  final restoredKey = KakaoAuthService.isLoggedIn
      ? KakaoAuthService.accountKey
      : AppleAuthService.isLoggedIn
      ? AppleAuthService.accountKey
      : null;
  await LottoDatabase.instance.switchAccount(restoredKey);

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
  bool _accountTransition = false;
  int _sessionRevision = 0;
  final _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      final owner = LottoDatabase.instance.accountKey;
      if (!_accountTransition && owner != null && user?.uid != owner) {
        unawaited(_clearExpiredSession());
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _clearExpiredSession() async {
    setState(() => _accountTransition = true);
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    KakaoAuthService.clearLocalSession();
    AppleAuthService.clearLocalSession();
    await LottoDatabase.instance.switchAccount(null);
    try {
      await UserService.clearProvider();
    } catch (e) {
      debugPrint('[Auth] 이전 계정 표시 정리 실패: $e');
    }
    try {
      await UserService.detachNotifications();
    } catch (e) {
      debugPrint('[Auth] 만료된 계정의 알림 해제 재시도 필요: $e');
    }
    NotificationRouter.clearPending();
    if (!mounted) return;
    setState(() {
      _sessionRevision++;
      _enteredApp = false;
      _accountTransition = false;
    });
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
    if (!mounted) return;
    setState(() => _themeMode = mode);
  }

  Future<void> _onLoginSuccess() async {
    final accountKey = KakaoAuthService.isLoggedIn
        ? KakaoAuthService.accountKey
        : AppleAuthService.isLoggedIn
        ? AppleAuthService.accountKey
        : null;
    if (accountKey != null && !FirebaseAuthBridge.isSignedInAs(accountKey)) {
      throw StateError('계정 인증을 다시 진행해주세요.');
    }
    await LottoDatabase.instance.switchAccount(accountKey);
    if (accountKey != null) UserService.allowNotificationBinding();
    if (!mounted) return;
    setState(() {
      _sessionRevision++;
      _enteredApp = true;
    });
  }

  Future<void> _onLogout() async {
    if (_accountTransition) return;
    final owner = LottoDatabase.instance.accountKey;
    setState(() => _accountTransition = true);
    try {
      // Revocation must complete before reporting logout success. If offline
      // and both revocation paths fail, the caller presents a retryable error.
      await UserService.detachNotifications();
      await KakaoAuthService.logout();
      await AppleAuthService.logout();
      await LottoDatabase.instance.switchAccount(null);
      NotificationRouter.clearPending();
      if (!mounted) return;
      setState(() {
        _sessionRevision++;
        _enteredApp = true;
      });
    } catch (_) {
      if (owner != null && FirebaseAuthBridge.isSignedInAs(owner)) {
        UserService.allowNotificationBinding();
      } else if (mounted) {
        await _clearExpiredSession();
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _accountTransition = false);
    }
  }

  void _onRequireLogin() {
    setState(() => _enteredApp = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: appFlavor == 'dev' ? '럭키로그 DEV' : '럭키로그',
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
      builder: (context, child) => Stack(
        children: [
          ?child,
          if (appFlavor == 'dev')
            const Positioned(
              top: 0,
              right: 0,
              child: IgnorePointer(
                child: SafeArea(
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(0xFF9A3412),
                        borderRadius: BorderRadius.all(Radius.circular(4)),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Text(
                          'DEV · 테스트 계정',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_accountTransition) ...[
            const ModalBarrier(dismissible: false, color: Colors.white),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
      home: _showSplash
          ? SplashScreen(onComplete: () => setState(() => _showSplash = false))
          : _enteredApp
          ? MainTabScreen(
              key: ValueKey(
                '${LottoDatabase.instance.accountKey}:$_sessionRevision',
              ),
              onLogout: _onLogout,
              accountTransition: _accountTransition,
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
    required this.accountTransition,
    required this.onRequireLogin,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final Future<void> Function() onLogout;
  final bool accountTransition;
  final VoidCallback onRequireLogin;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeModeChanged;

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;
  List<NumberSet> _savedSets = <NumberSet>[];
  List<PurchaseRecord> _purchaseHistory = <PurchaseRecord>[];
  final _vaultKey = GlobalKey<NumberSetVaultTabState>();
  final _profileKey = GlobalKey<ProfileTabState>();
  late final PurchaseInsightsController _insights;
  StreamSubscription<RemoteMessage>? _notifTapSub;
  Timer? _syncTimer;
  bool _syncing = false;
  bool _registered = false;
  String? _syncError;
  int _readGeneration = 0;
  late final String? _owner;

  @override
  void initState() {
    super.initState();
    _owner = LottoDatabase.instance.accountKey;
    _insights = PurchaseInsightsController(
      database: LottoDatabase.instance,
      onRecordsChanged: _syncSnapshotIfLoggedIn,
    );
    WidgetsBinding.instance.addObserver(this);
    LottoDatabase.instance.revision.addListener(_onDatabaseChanged);
    _reloadPrivateData();
    unawaited(_refreshAccount());
    _syncTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_refreshAccount());
      }
    });

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
        if (!_ownsView) return;
        unawaited(NotificationService.requestOnFirstLaunch());
      });
    });
  }

  @override
  void dispose() {
    _notifTapSub?.cancel();
    _insights.dispose();
    _syncTimer?.cancel();
    LottoDatabase.instance.revision.removeListener(_onDatabaseChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshAccount());
  }

  bool get _ownsView =>
      mounted &&
      !widget.accountTransition &&
      LottoDatabase.instance.accountKey == _owner;

  void _onDatabaseChanged() {
    if (_ownsView) unawaited(_reloadPrivateData());
  }

  Future<void> _reloadPrivateData() async {
    final generation = ++_readGeneration;
    final rows = await Future.wait([
      LottoDatabase.instance.getAllNumberSets(),
      LottoDatabase.instance.getAllPurchaseHistory(),
    ]);
    if (!_ownsView || generation != _readGeneration) return;
    setState(() {
      _savedSets = rows[0].map(NumberSet.fromDb).toList();
      _purchaseHistory = rows[1].map(PurchaseRecord.fromDb).toList();
    });
  }

  Future<void> _refreshAccount() async {
    if (!_ownsView || _syncing) return;
    setState(() {
      _syncing = true;
      _syncError = null;
    });
    try {
      // Public results remain refreshable even if private backup or push setup
      // is waiting for authentication, connectivity, or notification permission.
      await LottoSyncService.syncIfNeeded();
      if (!_ownsView) return;
      if (_owner != null && FirebaseAuthBridge.isSignedInAs(_owner)) {
        final number = _registered
            ? await UserService.cachedUserNumber(_owner)
            : await UserService.registerIfNeeded(_owner);
        _registered = true;
        if (!_ownsView) return;
        await UserService.syncNicknameFromFirestore(_owner);
        await UserDataSyncService.syncOnLogin(
          accountKey: _owner,
          userNumber: number,
        );
        if (!_ownsView) return;
      }
      if (!_ownsView) return;
      await UserService.reconcileNotifications(_owner);
      if (_ownsView) await _reloadPrivateData();
    } catch (e) {
      if (_ownsView) {
        setState(() => _syncError = '동기화 대기 중 · 저장한 기록은 이 기기에 보관됩니다.');
      }
      debugPrint('[Sync] 재시도 대기: $e');
    } finally {
      if (mounted && LottoDatabase.instance.accountKey == _owner) {
        setState(() => _syncing = false);
      }
    }
  }

  /// 알림 목적지로 이동. 번호세트 탭이면 서브탭까지 맞춘다.
  void _goToNotificationTarget(NotificationTarget target) {
    if (!mounted) return;
    dismissAppSnackBars(context);
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
    if (!_ownsView ||
        _owner == null ||
        !FirebaseAuthBridge.isSignedInAs(_owner)) {
      return;
    }
    unawaited(
      UserDataSyncService.pushLocalSnapshot(
        accountKey: _owner,
        userNumber: 0,
      ).catchError((Object e, StackTrace st) {
        if (_ownsView) setState(() => _syncError = '동기화 대기 중 · 다시 시도해주세요.');
        debugPrint('[Sync] 변경분 업로드 대기: $e');
      }),
    );
  }

  Future<void> _addNumberSet(List<List<int>> games) async {
    if (!_ownsView) return;
    final List<List<int>> sorted = games
        .map((numbers) => List<int>.from(numbers)..sort())
        .toList(growable: false);
    await LottoDatabase.instance.insertNumberSet(games: sorted);
    if (!_ownsView) return;
    await _reloadPrivateData();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _addPurchaseHistory(
    List<List<int>> games,
    int round,
    String source,
  ) async {
    if (!_ownsView) return;
    await LottoDatabase.instance.insertPurchaseHistory(
      games: games,
      round: round,
      source: source,
    );
    if (!_ownsView) return;
    await _reloadPrivateData();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _deletePurchaseHistory(int id) async {
    if (!_ownsView) return;
    await LottoDatabase.instance.deletePurchaseHistory(id);
    if (!_ownsView) return;
    await _reloadPrivateData();
    _syncSnapshotIfLoggedIn();
  }

  Future<QrBatchSaveResult> _addQrPurchaseBatch(
    List<ScannedTicket> tickets,
  ) async {
    if (!_ownsView) throw StateError('등록할 계정이 변경되었습니다.');
    final result = await LottoDatabase.instance.insertQrPurchaseBatch(tickets);
    if (!_ownsView) throw StateError('등록할 계정이 변경되었습니다.');
    await _reloadPrivateData();
    _syncSnapshotIfLoggedIn();
    return result;
  }

  Future<void> _markResultsChecked(List<int> ids) async {
    if (!_ownsView) throw StateError('계정이 변경되었습니다.');
    await LottoDatabase.instance.markPurchaseResultsChecked(ids);
    if (!_ownsView) throw StateError('계정이 변경되었습니다.');
    await _reloadPrivateData();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _togglePurchased(int setId, bool value) async {
    if (!_ownsView) return;
    await LottoDatabase.instance.updatePurchased(setId, isPurchased: value);
    if (!_ownsView) return;
    await _reloadPrivateData();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _deleteSet(int setId) async {
    if (!_ownsView) return;
    await LottoDatabase.instance.deleteNumberSet(setId);
    if (!_ownsView) return;
    await _reloadPrivateData();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _restoreSet(int setId) async {
    if (!_ownsView) throw StateError('계정이 변경되었습니다.');
    await LottoDatabase.instance.restoreNumberSet(setId);
    if (!_ownsView) return;
    await _reloadPrivateData();
    _syncSnapshotIfLoggedIn();
  }

  Future<void> _restorePurchaseHistory(int setId) async {
    if (!_ownsView) throw StateError('계정이 변경되었습니다.');
    await LottoDatabase.instance.restorePurchaseHistory(setId);
    if (!_ownsView) return;
    await _reloadPrivateData();
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
          insights: _insights,
          onOpenMonthlyRecords: () {
            dismissAppSnackBars(context);
            setState(() => _selectedIndex = 4);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _profileKey.currentState?.openRecords();
            });
          },
          purchaseHistory: _purchaseHistory,
          onSaveQrBatch: _addQrPurchaseBatch,
          onMarkResultsChecked: _markResultsChecked,
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
          onRestoreSet: _restoreSet,
          onTogglePurchased: _togglePurchased,
          onAddPurchaseHistory: _addPurchaseHistory,
          onDeletePurchaseHistory: _deletePurchaseHistory,
          onRestorePurchaseHistory: _restorePurchaseHistory,
          onMarkResultsChecked: _markResultsChecked,
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
          key: _profileKey,
          insights: _insights,
          onLogout: widget.onLogout,
          onRequireLogin: widget.onRequireLogin,
          purchaseHistory: _purchaseHistory,
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
        ),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(tabs[_selectedIndex].title),
        actions: [
          IconButton(
            tooltip: _syncError ?? '동기화',
            onPressed: _syncing ? null : _refreshAccount,
            icon: _syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_syncError == null ? Icons.sync : Icons.sync_problem),
          ),
        ],
        bottom: _syncError == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(34),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _syncError!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
      ),
      body: AppContentFrame(
        child: IndexedStack(
          index: _selectedIndex,
          children: tabs.map((tab) => tab.page).toList(),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int index) {
          if (_selectedIndex != index) dismissAppSnackBars(context);
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
