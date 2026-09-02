import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'firebase_auth_bridge.dart';
import 'user_service.dart';

class AppleAuthService {
  AppleAuthService._();

  static int _userNumber = 0;
  static String? _providerUserId;

  static int get userNumber => _userNumber;
  static String? get providerUserId => _providerUserId;
  static String? get accountKey =>
      _providerUserId == null ? null : 'apple:$_providerUserId';

  static bool get isLoggedIn => _providerUserId != null;
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  static Future<bool> login() async {
    if (!isSupportedPlatform) return false;
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      // Apple은 최초 로그인에만 userIdentifier를 제공
      final appleId = credential.userIdentifier;
      if (appleId == null || appleId.isEmpty) return false;

      _providerUserId = appleId;

      // identityToken은 로그인 시점에만 제공된다. 여기서 Firebase 세션을
      // 만들어 두어야 이후 재시작에서도 세션이 유지된다.
      final identityToken = credential.identityToken;
      if (identityToken != null && identityToken.isNotEmpty) {
        await FirebaseAuthBridge.ensureSignedIn(
          accountKey: 'apple:$appleId',
          provider: 'apple',
          credential: identityToken,
        );
      } else {
        debugPrint('[AppleAuth] identityToken 없음 - 서버 동기화 불가');
      }

      _userNumber = await UserService.registerIfNeeded('apple:$appleId');
      await UserService.saveProvider('apple:$appleId');
      unawaited(UserService.syncFcmToken('apple:$appleId'));

      return true;
    } catch (e) {
      // 사용자가 직접 취소한 경우 포함
      debugPrint('[AppleAuth] 로그인 실패(취소 포함): $e');
      return false;
    }
  }

  static Future<void> logout() async {
    await FirebaseAuthBridge.signOut();
    _userNumber = 0;
    _providerUserId = null;
    await UserService.clearProvider();
  }

  /// 앱 시작 시 로컬 저장된 Apple 세션 복원
  static Future<void> restoreSession() async {
    if (!isSupportedPlatform) return;
    final saved = await UserService.getSavedProvider();
    if (saved == null || !saved.startsWith('apple:')) return;

    final appleId = saved.substring('apple:'.length);
    // Apple credential 상태 확인
    try {
      final state = await SignInWithApple.getCredentialState(appleId);
      if (state == CredentialState.authorized) {
        _providerUserId = appleId;
        // 복원 시점엔 identityToken을 얻을 수 없다.
        // Firebase 세션은 재시작 후에도 유지되므로 보통 그대로 통과한다.
        // 세션이 사라졌다면 서버 동기화만 막히고, 재로그인 시 복구된다.
        final ok = await FirebaseAuthBridge.ensureSignedIn(
          accountKey: 'apple:$appleId',
          provider: 'apple',
        );
        if (!ok) {
          debugPrint('[AppleAuth] Firebase 세션 없음 - 재로그인해야 동기화됨');
        }
        _userNumber = await UserService.registerIfNeeded('apple:$appleId');
        unawaited(UserService.syncFcmToken('apple:$appleId'));
      }
    } catch (e) {
      // 세션 복원 실패 = 로그아웃 상태로 시작. 원인 추적이 필요하다.
      debugPrint('[AppleAuth] 세션 복원 실패: $e');
    }
  }
}
