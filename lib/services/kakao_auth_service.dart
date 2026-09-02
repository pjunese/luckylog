import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';

import 'firebase_auth_bridge.dart';
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
  static bool get isLoggedIn => _user != null;
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
  }

  /// 카카오 로그인 (카카오톡 앱 우선, 없으면 웹)
  static Future<bool> login() async {
    if (!isSupportedPlatform) {
      debugPrint('[KakaoAuth] 현재 플랫폼은 카카오 로그인을 지원하지 않습니다.');
      return false;
    }
    try {
      if (await isKakaoTalkInstalled()) {
        await UserApi.instance.loginWithKakaoTalk();
      } else {
        await UserApi.instance.loginWithKakaoAccount();
      }
      _user = await UserApi.instance.me();

      // 프로필 동의가 안 된 경우 추가 동의 요청
      final scopes = <String>[];
      if (_user?.kakaoAccount?.profileNeedsAgreement == true) {
        scopes.add('profile_nickname');
      }
      if (_user?.kakaoAccount?.profileImageNeedsAgreement == true) {
        scopes.add('profile_image');
      }
      if (scopes.isNotEmpty) {
        try {
          await UserApi.instance
              .loginWithNewScopes(scopes)
              .timeout(const Duration(seconds: 10));
          _user = await UserApi.instance.me();
        } catch (e) {
          debugPrint('[KakaoAuth] 추가 동의 실패 (무시): $e');
        }
      }

      final kakaoId = _user?.id.toString() ?? '';
      if (kakaoId.isNotEmpty) {
        _providerUserId = kakaoId;
        // Firestore 동기화는 Firebase Auth 세션이 있어야 허용된다.
        await _signInToFirebase(kakaoId);
        _userNumber = await UserService.registerIfNeeded('kakao:$kakaoId');
        // 개인 당첨 알림용 FCM 토큰 동기화
        unawaited(UserService.syncFcmToken('kakao:$kakaoId'));
      }

      return true;
    } catch (e) {
      debugPrint('[KakaoAuth] 로그인 에러: $e');
      return false;
    }
  }

  /// 로그아웃
  static Future<void> logout() async {
    try {
      await UserApi.instance.logout();
    } catch (e) {
      // 서버 로그아웃이 실패해도 아래에서 로컬 세션은 정리된다
      debugPrint('[KakaoAuth] 서버 로그아웃 실패(로컬은 정리됨): $e');
    }
    await FirebaseAuthBridge.signOut();
    _user = null;
    _userNumber = 0;
    _providerUserId = null;
  }

  /// 앱 시작 시 자동 로그인 복원
  static Future<void> restoreSession() async {
    if (!isSupportedPlatform) {
      _user = null;
      return;
    }
    try {
      final token = await TokenManagerProvider.instance.manager.getToken();
      if (token == null || token.accessToken.isEmpty) return;
      _user = await UserApi.instance.me();
      final kakaoId = _user?.id.toString() ?? '';
      if (kakaoId.isNotEmpty) {
        _providerUserId = kakaoId;
        await _signInToFirebase(kakaoId);
        _userNumber = await UserService.registerIfNeeded('kakao:$kakaoId');
        // 개인 당첨 알림용 FCM 토큰 동기화
        unawaited(UserService.syncFcmToken('kakao:$kakaoId'));
      }
    } catch (_) {
      _user = null;
      _userNumber = 0;
      _providerUserId = null;
    }
  }

  /// 카카오 액세스 토큰으로 Firebase Auth 세션을 확보한다.
  /// 실패해도 로그인 자체는 유지된다(로컬 사용은 가능, 서버 동기화만 막힘).
  static Future<void> _signInToFirebase(String kakaoId) async {
    try {
      final token = await TokenManagerProvider.instance.manager.getToken();
      final accessToken = token?.accessToken;
      if (accessToken == null || accessToken.isEmpty) {
        debugPrint('[KakaoAuth] 액세스 토큰 없음 - Firebase 로그인 생략');
        return;
      }
      await FirebaseAuthBridge.ensureSignedIn(
        accountKey: 'kakao:$kakaoId',
        provider: 'kakao',
        credential: accessToken,
      );
    } catch (e) {
      debugPrint('[KakaoAuth] Firebase 로그인 실패: $e');
    }
  }
}
