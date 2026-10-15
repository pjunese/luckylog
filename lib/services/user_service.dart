import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_device_manager.dart';

class UserService {
  UserService._();

  static const _keyNickname = 'profile_nickname';
  static const _keyImagePath = 'profile_image_path';
  static const _keySavedProvider = 'saved_provider';
  static const notificationEnabledKey = 'notif_draw_result';
  static const drawResultTopic = 'draw_result';
  static const _networkTimeout = Duration(seconds: 3);
  static Future<void> _topicTail = Future<void>.value();
  static final ValueNotifier<bool> notificationPendingNotifier =
      ValueNotifier<bool>(false);
  static final _delivery = NotificationDeliveryReconciler(
    syncTopic: syncNotificationTopic,
    onPendingChanged: (pending) => notificationPendingNotifier.value = pending,
  );

  static final NotificationDeviceManager _devices = NotificationDeviceManager(
    settings: _DeviceSettings(),
    tokens: _DeviceTokens(),
    store: _DeviceStore(),
    currentUid: () => FirebaseAuth.instance.currentUser?.uid,
    onBackgroundError: (error, stack) {
      debugPrint('[UserService] 알림 동기화 재시도 필요: $error');
    },
  );

  static String _scopedKey(String name, String accountKey) =>
      '${name}_${base64Url.encode(utf8.encode(accountKey))}';

  // Firebase retains its verified UID offline. A saved provider hint alone
  // must never expose an old account's profile in a guest session.
  static String? get _profileAccount => FirebaseAuth.instance.currentUser?.uid;

  /// User numbering and legacy migration are privileged server operations.
  /// The endpoint derives the account identity from its verified auth context.
  static Future<int> registerIfNeeded(String accountKey) async {
    if (FirebaseAuth.instance.currentUser?.uid != accountKey) {
      throw StateError('회원 등록 계정이 인증된 사용자와 다릅니다.');
    }
    final result = await FirebaseFunctions.instanceFor(
      region: 'asia-northeast3',
    ).httpsCallable('registerUser').call().timeout(const Duration(seconds: 15));
    if (FirebaseAuth.instance.currentUser?.uid != accountKey) {
      throw StateError('회원 등록 중 로그인 계정이 변경되었습니다.');
    }
    final data = result.data;
    final value = data is Map ? data['userNumber'] : null;
    if (value is! num || value <= 0 || value != value.toInt()) {
      throw StateError('서버가 올바른 회원 번호를 반환하지 않았습니다.');
    }
    final userNumber = value.toInt();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_scopedKey('user_number', accountKey), userNumber);
    return userNumber;
  }

  /// Older installs have an authenticated session but no account-scoped cache.
  /// Recover their member number through the server, without discarding a valid
  /// Firebase session when the device is offline.
  static Future<int> restoreUserNumber(String accountKey) async {
    final cached = await cachedUserNumber(accountKey);
    if (cached > 0) return cached;
    try {
      return await registerIfNeeded(accountKey);
    } catch (error) {
      debugPrint('[UserService] 회원 번호 복구 대기: ${error.runtimeType}');
      return 0;
    }
  }

  static Future<int> cachedUserNumber(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_scopedKey('user_number', accountKey)) ?? 0;
  }

  static Future<String> getNickname(int userNumber) async {
    final accountKey = _profileAccount;
    if (accountKey == null) return 'user_$userNumber';
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_scopedKey(_keyNickname, accountKey)) ??
        'user_$userNumber';
  }

  static Future<void> saveNickname(
    String nickname, {
    String? accountKey,
  }) async {
    final owner = accountKey ?? _profileAccount;
    if (owner == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (FirebaseAuth.instance.currentUser?.uid != owner) {
      throw StateError('닉네임을 저장할 계정이 인증된 사용자와 다릅니다.');
    }
    await prefs.setString(_scopedKey(_keyNickname, owner), nickname);
    if (FirebaseAuth.instance.currentUser?.uid == owner) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(owner)
            .update({
              'nickname': nickname,
              'updatedAt': FieldValue.serverTimestamp(),
            })
            .timeout(_networkTimeout);
      } catch (error) {
        debugPrint('[UserService] 닉네임 서버 저장 실패: $error');
      }
    }
  }

  static Future<void> syncNicknameFromFirestore(String accountKey) async {
    if (FirebaseAuth.instance.currentUser?.uid != accountKey) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(accountKey)
          .get()
          .timeout(_networkTimeout);
      if (FirebaseAuth.instance.currentUser?.uid != accountKey) return;
      final nickname = doc.data()?['nickname'] as String?;
      if (nickname != null && nickname.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_scopedKey(_keyNickname, accountKey), nickname);
      }
    } catch (error) {
      debugPrint('[UserService] 닉네임 동기화 실패: $error');
    }
  }

  static Future<String?> getProfileImagePath() async {
    final accountKey = _profileAccount;
    final prefs = await SharedPreferences.getInstance();
    return accountKey == null
        ? null
        : prefs.getString(_scopedKey(_keyImagePath, accountKey));
  }

  static Future<void> saveProfileImagePath(
    String path, {
    String? accountKey,
  }) async {
    final owner = accountKey ?? _profileAccount;
    if (owner == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (FirebaseAuth.instance.currentUser?.uid != owner) {
      throw StateError('프로필 사진을 저장할 계정이 인증된 사용자와 다릅니다.');
    }
    await prefs.setString(_scopedKey(_keyImagePath, owner), path);
  }

  static Future<void> clearProfile() async {
    final accountKey = _profileAccount;
    if (accountKey == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_scopedKey(_keyNickname, accountKey));
    await prefs.remove(_scopedKey(_keyImagePath, accountKey));
    // Old unscoped values remain quarantined; no account imports them.
  }

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

  static String? get notificationsAccount => _devices.boundAccount;

  /// Login/resume best-effort wrapper. Settings and logout use throwing APIs so
  /// their UI can distinguish local intent from a confirmed remote update.
  static Future<void> syncFcmToken(String accountKey) async {
    try {
      await reconcileNotifications(accountKey);
    } catch (error) {
      debugPrint('[UserService] 알림 동기화 재시도 필요: $error');
    }
  }

  /// Strict retry API: failures remain pending and reach the caller's UI.
  /// A null owner reconciles only the guest's public-topic preference.
  static Future<void> reconcileNotifications(String? accountKey) =>
      _delivery.reconcile(() async {
        if (accountKey == null) return;
        await _devices.bind(accountKey);
        if (FirebaseAuth.instance.currentUser?.uid != accountKey) {
          throw StateError('알림 동기화 중 로그인 계정이 변경되었습니다.');
        }
      });

  static Future<void> setPersonalNotificationsEnabled(bool enabled) => _delivery
      .reconcile(() => _devices.setEnabled(enabled, persistSetting: false));

  static Future<void> detachNotifications() =>
      _delivery.reconcile(_devices.detach, updateTopic: false);

  static void allowNotificationBinding() => _devices.allowBinding();

  /// Token rotation clears topic membership; restore it from local intent.
  static Future<void> syncNotificationTopic() {
    final operation = _topicTail.then((_) => _syncNotificationTopic());
    _topicTail = operation.catchError((Object _, StackTrace _) {});
    return operation;
  }

  static Future<void> _syncNotificationTopic() async {
    final prefs = await SharedPreferences.getInstance();
    final messaging = FirebaseMessaging.instance;
    if (prefs.getBool(notificationEnabledKey) ?? false) {
      await messaging
          .subscribeToTopic(drawResultTopic)
          .timeout(_networkTimeout);
    } else {
      await messaging
          .unsubscribeFromTopic(drawResultTopic)
          .timeout(_networkTimeout);
    }
  }
}

class _DeviceSettings implements NotificationDeviceSettings {
  static const _deviceIdKey = 'notification_installation_id';
  static const _ownerKey = 'notification_token_owner';
  static const _rotationKey = 'notification_token_rotation_pending';

  @override
  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final id = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    await prefs.setString(_deviceIdKey, id);
    return id;
  }

  @override
  Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(
        UserService.notificationEnabledKey,
      ) ??
      false;

  @override
  Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(
      UserService.notificationEnabledKey,
      value,
    );
  }

  @override
  Future<String?> owner() async =>
      (await SharedPreferences.getInstance()).getString(_ownerKey);

  @override
  Future<void> setOwner(String? accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    if (accountKey == null) {
      await prefs.remove(_ownerKey);
    } else {
      await prefs.setString(_ownerKey, accountKey);
    }
  }

  @override
  Future<bool> rotationRequired() async =>
      (await SharedPreferences.getInstance()).getBool(_rotationKey) ?? false;

  @override
  Future<void> setRotationRequired(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(_rotationKey, value);
  }
}

class _DeviceTokens implements NotificationTokenClient {
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  @override
  Future<String?> getToken() async {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      final apns = await _messaging.getAPNSToken().timeout(
        UserService._networkTimeout,
      );
      if (apns == null) return null;
    }
    return _messaging.getToken().timeout(UserService._networkTimeout);
  }

  @override
  Future<void> deleteToken() =>
      _messaging.deleteToken().timeout(UserService._networkTimeout);
}

class _DeviceStore implements NotificationDeviceStore {
  @override
  Future<void> writeDevice(
    String accountKey,
    String deviceId, {
    required bool enabled,
    String? token,
  }) => FirebaseFirestore.instance
      .collection('users')
      .doc(accountKey)
      .collection('devices')
      .doc(deviceId)
      .set({
        'enabled': enabled,
        'token': enabled && token != null ? token : FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true))
      .timeout(UserService._networkTimeout);

  @override
  Future<void> clearLegacyToken(String accountKey) => FirebaseFirestore.instance
      .collection('users')
      .doc(accountKey)
      .update({
        'fcmToken': FieldValue.delete(),
        'fcmTokenUpdatedAt': FieldValue.delete(),
      })
      .timeout(UserService._networkTimeout);
}
