import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'user_service.dart';

/// 카카오/애플 로그인을 Firebase Auth 세션으로 연결한다.
///
/// Firestore 보안 규칙이 `request.auth.uid == accountKey` 로 잠겨 있어서,
/// 이 로그인이 되어 있지 않으면 번호세트·구매내역 동기화가 전부 거부된다.
///
/// 자격증명 검증은 서버(`createAuthToken`)에서 한다.
/// 클라이언트가 보낸 계정키를 그대로 믿으면 남의 계정을 사칭할 수 있기 때문.
class FirebaseAuthBridge {
  FirebaseAuthBridge._();

  static const String _region = 'asia-northeast3';

  static User? get currentUser => FirebaseAuth.instance.currentUser;
  static bool get isSignedIn => currentUser != null;
  static String? get uid => currentUser?.uid;

  /// 이미 원하는 계정으로 로그인되어 있는지.
  static bool isSignedInAs(String accountKey) =>
      currentUser != null && currentUser!.uid == accountKey;

  /// 자격증명을 서버에서 검증받아 Firebase Auth에 로그인한다.
  ///
  /// [provider] 'kakao' | 'apple'
  /// [credential] 카카오는 액세스 토큰, 애플은 identityToken
  static Future<bool> signIn({
    required String provider,
    required String credential,
  }) async {
    try {
      final callable = FirebaseFunctions.instanceFor(
        region: _region,
      ).httpsCallable('createAuthToken');

      final result = await callable
          .call<Map<String, dynamic>>({
            'provider': provider,
            'credential': credential,
          })
          .timeout(const Duration(seconds: 15));

      final token = result.data['token'] as String?;
      if (token == null || token.isEmpty) {
        debugPrint('[FirebaseAuth] 토큰이 비어 있음');
        return false;
      }

      final cred = await FirebaseAuth.instance.signInWithCustomToken(token);
      debugPrint('[FirebaseAuth] 로그인 완료: ${cred.user?.uid}');
      return true;
    } catch (e) {
      // 실패해도 앱은 계속 동작한다(로컬 저장은 됨). 다만 서버 동기화는 막힌다.
      debugPrint('[FirebaseAuth] 로그인 실패 - 서버 동기화 불가: $e');
      return false;
    }
  }

  /// 세션 복원용. 이미 같은 계정으로 로그인돼 있으면 아무 것도 하지 않는다.
  ///
  /// Firebase Auth 세션은 앱 재시작 후에도 유지되므로 보통 재발급이 필요 없다.
  /// 세션이 없고 [credential]도 없으면(예: 애플 복원) false를 반환한다.
  static Future<bool> ensureSignedIn({
    required String accountKey,
    required String provider,
    String? credential,
  }) async {
    if (isSignedInAs(accountKey)) return true;

    // 다른 계정으로 남아있는 세션은 정리하고 새로 로그인한다.
    if (isSignedIn) {
      debugPrint('[FirebaseAuth] 다른 계정 세션 정리: $uid → $accountKey');
      await UserService.detachNotifications();
      await signOut();
    }

    if (credential == null || credential.isEmpty) {
      debugPrint('[FirebaseAuth] 세션 없음 + 자격증명 없음 ($accountKey) - 재로그인 필요');
      return false;
    }
    return signIn(provider: provider, credential: credential);
  }

  static Future<void> signOut() => FirebaseAuth.instance.signOut();
}
