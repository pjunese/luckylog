import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import '../core/dev_kakao.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';

import 'firebase_auth_bridge.dart';
import 'kakao_login_flow.dart';
import 'user_service.dart';

class KakaoAuthService {
  KakaoAuthService._();

  static User? _user;
  static int _userNumber = 0;
  static String? _providerUserId;

  static int get userNumber => _userNumber;
  static String? get providerUserId => _providerUserId;
  static String? get accountKey =>
      _providerUserId == null ? null : 'kakao:$_providerUserId';
  static User? get currentUser => _user;
  static bool get isLoggedIn =>
      accountKey != null && FirebaseAuthBridge.isSignedInAs(accountKey!);
  static bool get isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  static bool get isConfigured =>
      appFlavor != 'dev' || devKakaoNativeAppKey.isNotEmpty;

  static Future<bool> login() async {
    if (!isSupportedPlatform || !isConfigured) return false;
    final initialUid = FirebaseAuthBridge.uid;
    String? attemptedAccount;
    var stage = 'kakao_authorize';
    try {
      await loginWithKakaoFallback(
        isTalkInstalled: isKakaoTalkInstalled,
        loginWithTalk: () => UserApi.instance.loginWithKakaoTalk(),
        loginWithAccount: () => UserApi.instance.loginWithKakaoAccount(),
      );
      stage = 'profile';
      var user = await UserApi.instance.me();
      final scopes = <String>[];
      if (user.kakaoAccount?.profileNeedsAgreement == true) {
        scopes.add('profile_nickname');
      }
      if (user.kakaoAccount?.profileImageNeedsAgreement == true) {
        scopes.add('profile_image');
      }
      if (scopes.isNotEmpty) {
        try {
          await UserApi.instance
              .loginWithNewScopes(scopes)
              .timeout(const Duration(seconds: 10));
          user = await UserApi.instance.me();
        } catch (e) {
          debugPrint('[KakaoAuth] 추가 프로필 동의 실패: $e');
        }
      }
      final id = user.id.toString();
      final key = 'kakao:$id';
      attemptedAccount = key;
      final token = await TokenManagerProvider.instance.manager.getToken();
      if (token == null || token.accessToken.isEmpty) return false;
      stage = 'firebase_auth';
      final authenticated = await FirebaseAuthBridge.ensureSignedIn(
        accountKey: key,
        provider: 'kakao',
        credential: token.accessToken,
      );
      if (!authenticated || !FirebaseAuthBridge.isSignedInAs(key)) {
        throw StateError('Firebase 인증을 완료하지 못했습니다.');
      }
      stage = 'register_user';
      final number = await UserService.registerIfNeeded(key);
      await UserService.saveProvider(key);
      // Publish identity only after authentication and registration both succeed.
      _user = user;
      _providerUserId = id;
      _userNumber = number;
      return true;
    } catch (e) {
      if (initialUid == null || FirebaseAuthBridge.uid != initialUid) {
        clearLocalSession();
        if (attemptedAccount != null &&
            FirebaseAuthBridge.uid == attemptedAccount) {
          await FirebaseAuthBridge.signOut();
        }
      }
      debugPrint('[KakaoAuth] 로그인 실패 stage=$stage type=${e.runtimeType}');
      return false;
    }
  }

  static void clearLocalSession() {
    _user = null;
    _userNumber = 0;
    _providerUserId = null;
  }

  /// The caller detaches this device's notifications before signing out.
  static Future<void> logout() async {
    await FirebaseAuthBridge.signOut();
    clearLocalSession();
    await UserService.clearProvider();
    if (!isSupportedPlatform) return;
    try {
      await UserApi.instance.logout().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[KakaoAuth] 공급자 로그아웃 실패: $e');
    }
  }

  /// Firebase's persisted authenticated session is the account authority. A
  /// stale Kakao SDK token must never silently revive a signed-out account.
  static Future<void> restoreSession() async {
    clearLocalSession();
    if (!isSupportedPlatform) return;
    final key = FirebaseAuthBridge.uid;
    if (key == null || !RegExp(r'^kakao:\d+$').hasMatch(key)) return;
    _providerUserId = key.substring('kakao:'.length);
    _userNumber = await UserService.restoreUserNumber(key);
    if (!FirebaseAuthBridge.isSignedInAs(key)) {
      clearLocalSession();
      return;
    }
    await UserService.saveProvider(key);
  }
}
