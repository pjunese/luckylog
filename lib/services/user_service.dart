import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserService {
  UserService._();

  static const _keyNickname = 'profile_nickname';
  static const _keyImagePath = 'profile_image_path';
  static const _keySavedProvider = 'saved_provider';

  /// 첫 로그인 시 Firestore에 사용자 등록, userNumber 반환
  static Future<int> registerIfNeeded(String accountKey) async {
    final db = FirebaseFirestore.instance;
    final userRef = db.collection('users').doc(accountKey);
    final snapshot = await userRef.get();

    final int splitAt = accountKey.indexOf(':');
    final String provider = splitAt > 0
        ? accountKey.substring(0, splitAt)
        : 'unknown';
    final String providerUserId = splitAt > 0
        ? accountKey.substring(splitAt + 1)
        : accountKey;

    if (snapshot.exists) {
      return (snapshot.data()?['userNumber'] as int?) ?? 0;
    }

    // 과거 버전(문서 ID = 순수 kakaoId) 마이그레이션
    if (splitAt > 0) {
      final legacyRef = db.collection('users').doc(providerUserId);
      final legacySnapshot = await legacyRef.get();
      if (legacySnapshot.exists) {
        final legacyData = legacySnapshot.data() ?? <String, dynamic>{};
        final int legacyUserNumber = (legacyData['userNumber'] as int?) ?? 0;
        await userRef.set({
          'userNumber': legacyUserNumber,
          'nickname': legacyData['nickname'] ?? 'user_$legacyUserNumber',
          'provider': provider,
          'providerUserId': providerUserId,
          'createdAt': legacyData['createdAt'] ?? FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          'migratedFromLegacyId': providerUserId,
        }, SetOptions(merge: true));
        return legacyUserNumber;
      }
    }

    // 신규 사용자: 카운터 증가 후 번호 부여
    final counterRef = db.collection('meta').doc('userCount');
    int userNumber = 0;

    await db.runTransaction((tx) async {
      final counter = await tx.get(counterRef);
      if (counter.exists) {
        userNumber = ((counter.data()?['count'] as int?) ?? 0) + 1;
        tx.update(counterRef, {'count': userNumber});
      } else {
        userNumber = 1;
        tx.set(counterRef, {'count': 1});
      }
      tx.set(userRef, {
        'userNumber': userNumber,
        'nickname': 'user_$userNumber',
        'provider': provider,
        'providerUserId': providerUserId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    return userNumber;
  }

  static Future<String> getNickname(int userNumber) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyNickname) ?? 'user_$userNumber';
  }

  /// 닉네임 저장 (로컬 + Firestore 동시 저장)
  static Future<void> saveNickname(
    String nickname, {
    String? accountKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyNickname, nickname);
    if (accountKey != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(accountKey)
            .update({
              'nickname': nickname,
              'updatedAt': FieldValue.serverTimestamp(),
            });
      } catch (e) {
        // 네트워크 오류 시 로컬만 저장됨 (다음 동기화 때 반영)
      }
    }
  }

  /// 로그인 시 Firestore에서 닉네임 가져와 로컬 갱신
  static Future<void> syncNicknameFromFirestore(String accountKey) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(accountKey)
          .get();
      final nickname = doc.data()?['nickname'] as String?;
      if (nickname != null && nickname.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyNickname, nickname);
      }
    } catch (e) {
      // 실패 시 기존 로컬 닉네임을 그대로 사용
      debugPrint('[UserService] 닉네임 동기화 실패: $e');
    }
  }

  static Future<String?> getProfileImagePath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyImagePath);
  }

  static Future<void> saveProfileImagePath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyImagePath, path);
  }

  static Future<void> clearProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyNickname);
    await prefs.remove(_keyImagePath);
  }

  /// 로그인 공급자 저장/조회 (Apple 세션 복원용)
  static Future<void> saveProvider(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySavedProvider, accountKey);
  }

  static Future<String?> getSavedProvider() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keySavedProvider);
  }

  static Future<void> clearProvider() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySavedProvider);
  }

  /// FCM 토큰을 Firestore에 저장 (개인 당첨 알림용)
  /// 로그인 후 + 토큰 갱신 시 호출
  static Future<void> syncFcmToken(String accountKey) async {
    try {
      final messaging = FirebaseMessaging.instance;

      // iOS: APNs 토큰이 준비될 때까지 대기 (없으면 FCM 토큰 발급 실패)
      try {
        final apns = await messaging.getAPNSToken();
        if (apns == null) return;
      } catch (_) {
        // APNs 미지원 플랫폼은 무시 (Android, macOS 등)
      }

      final token = await messaging.getToken();
      if (token == null || token.isEmpty) return;

      final db = FirebaseFirestore.instance;
      await db.collection('users').doc(accountKey).set({
        'fcmToken': token,
        'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 토큰 갱신 시 자동 업데이트
      messaging.onTokenRefresh.listen((newToken) {
        db.collection('users').doc(accountKey).set({
          'fcmToken': newToken,
          'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
    } catch (_) {
      // 네트워크 오류 등은 무시 (다음 실행에서 재시도)
    }
  }
}
