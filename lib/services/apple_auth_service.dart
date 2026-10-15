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
  static bool get isLoggedIn =>
      accountKey != null && FirebaseAuthBridge.isSignedInAs(accountKey!);
  static bool get isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static Future<bool> login() async {
    if (!isSupportedPlatform) return false;
    final initialUid = FirebaseAuthBridge.uid;
    String? attemptedAccount;
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final id = credential.userIdentifier;
      final token = credential.identityToken;
      if (id == null || id.isEmpty || token == null || token.isEmpty) {
        throw StateError('Apple 인증 정보가 없습니다.');
      }
      final key = 'apple:$id';
      attemptedAccount = key;
      final authenticated = await FirebaseAuthBridge.ensureSignedIn(
        accountKey: key,
        provider: 'apple',
        credential: token,
      );
      if (!authenticated || !FirebaseAuthBridge.isSignedInAs(key)) {
        throw StateError('Firebase 인증을 완료하지 못했습니다.');
      }
      final number = await UserService.registerIfNeeded(key);
      await UserService.saveProvider(key);
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
      debugPrint('[AppleAuth] 로그인 실패: $e');
      return false;
    }
  }

  static void clearLocalSession() {
    _providerUserId = null;
    _userNumber = 0;
  }

  static Future<void> logout() async {
    await FirebaseAuthBridge.signOut();
    clearLocalSession();
    await UserService.clearProvider();
  }

  static Future<void> restoreSession() async {
    clearLocalSession();
    if (!isSupportedPlatform) return;
    final key = FirebaseAuthBridge.uid;
    if (key == null || !key.startsWith('apple:') || key.length <= 6) return;
    _providerUserId = key.substring('apple:'.length);
    _userNumber = await UserService.restoreUserNumber(key);
    if (!FirebaseAuthBridge.isSignedInAs(key)) {
      clearLocalSession();
      return;
    }
    await UserService.saveProvider(key);
  }
}
