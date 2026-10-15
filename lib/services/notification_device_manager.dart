import 'dart:async';

/// Persistent state is separate from Firebase so account changes and delayed
/// callbacks can be tested without touching a real device or server.
abstract interface class NotificationDeviceSettings {
  Future<String> deviceId();
  Future<String?> owner();
  Future<void> setOwner(String? accountKey);
  Future<bool> rotationRequired();
  Future<void> setRotationRequired(bool value);
  Future<bool> enabled();
  Future<void> setEnabled(bool value);
}

abstract interface class NotificationTokenClient {
  Stream<String> get onTokenRefresh;
  Future<String?> getToken();
  Future<void> deleteToken();
}

abstract interface class NotificationDeviceStore {
  Future<void> writeDevice(
    String accountKey,
    String deviceId, {
    required bool enabled,
    String? token,
  });
  Future<void> clearLegacyToken(String accountKey);
}

/// Serializes registration, settings, refresh and logout. A revision invalidates
/// callbacks immediately, even while an earlier network request is in flight.
class NotificationDeviceManager {
  NotificationDeviceManager({
    required this.settings,
    required this.tokens,
    required this.store,
    required this.currentUid,
    required this.onBackgroundError,
  });

  final NotificationDeviceSettings settings;
  final NotificationTokenClient tokens;
  final NotificationDeviceStore store;
  final String? Function() currentUid;
  final void Function(Object error, StackTrace stack) onBackgroundError;

  Future<void> _tail = Future<void>.value();
  StreamSubscription<String>? _refreshSubscription;
  String? _accountKey;
  int _revision = 0;
  int _listenerRevision = 0;
  bool _bindingBlocked = false;
  int _detachRevision = 0;

  String? get boundAccount => _accountKey;

  /// A fresh interactive login may reopen registration after logout. Routine
  /// foreground sync must never do this while the old session is signing out.
  void allowBinding() => _bindingBlocked = false;

  Future<void> _enqueue(Future<void> Function() operation) {
    final future = _tail.then((_) => operation());
    // A failed foreground operation must not discard later user changes.
    _tail = future.catchError((Object _, StackTrace _) {});
    return future;
  }

  bool _isCurrent(String accountKey, int revision) =>
      _revision == revision &&
      _accountKey == accountKey &&
      currentUid() == accountKey;

  Future<void> bind(String accountKey) {
    if (_bindingBlocked) {
      return Future<void>.error(StateError('로그아웃 중에는 알림을 다시 연결할 수 없습니다.'));
    }
    if (currentUid() != accountKey) {
      return Future<void>.error(StateError('알림 계정이 인증된 사용자와 다릅니다.'));
    }
    // A repeated resume for the same account must not supersede an awaited
    // settings write. Only an identity change invalidates that work.
    if (_accountKey != accountKey) ++_revision;
    _accountKey = accountKey;
    final revision = _revision;
    return _enqueue(() => _bind(accountKey, revision));
  }

  Future<void> setEnabled(bool value, {bool persistSetting = true}) {
    final accountKey = _bindingBlocked ? null : (_accountKey ?? currentUid());
    _accountKey = accountKey;
    final revision = ++_revision;
    return _enqueue(() async {
      // Commit every requested setting in order, including while offline.
      if (persistSetting) await settings.setEnabled(value);
      await _cancelRefresh();
      if (accountKey != null && _isCurrent(accountKey, revision)) {
        await _bind(accountKey, revision);
      }
    });
  }

  Future<void> _bind(String accountKey, int revision) async {
    await _cancelRefresh();
    if (!_isCurrent(accountKey, revision)) return;
    final deviceId = await settings.deviceId();
    final previousOwner = await settings.owner();
    final mustRotate = await settings.rotationRequired();
    if (!_isCurrent(accountKey, revision)) return;

    // Unknown ownership includes upgrades from the old shared fcmToken field.
    // Never attach that token to a newly authenticated account.
    if (mustRotate || previousOwner != accountKey) {
      await settings.setRotationRequired(true);
      await tokens.deleteToken();
      await settings.setRotationRequired(false);
      await settings.setOwner(null);
      if (!_isCurrent(accountKey, revision)) return;
    }
    await settings.setOwner(accountKey);
    final enabled = await settings.enabled();
    if (!_isCurrent(accountKey, revision)) return;
    await store.clearLegacyToken(accountKey);
    if (!_isCurrent(accountKey, revision)) return;

    if (!enabled) {
      await store.writeDevice(accountKey, deviceId, enabled: false);
      return;
    }

    final listenerRevision = _listenerRevision;
    bool ownsListener() =>
        _isCurrent(accountKey, revision) &&
        _listenerRevision == listenerRevision;
    _refreshSubscription = tokens.onTokenRefresh.listen(
      (token) {
        if (!ownsListener() || token.isEmpty) return;
        // Stream.listen does not await async callbacks. Explicitly catch the
        // queued write so transient refresh failures cannot become unhandled.
        unawaited(
          _enqueue(() async {
            if (!ownsListener()) return;
            if (!await settings.enabled()) return;
            if (!ownsListener()) return;
            await store.writeDevice(
              accountKey,
              deviceId,
              enabled: true,
              token: token,
            );
          }).catchError(onBackgroundError),
        );
      },
      onError: (Object error, StackTrace stack) {
        onBackgroundError(error, stack);
      },
    );
    final token = await tokens.getToken();
    if (!_isCurrent(accountKey, revision)) return;
    if (token == null || token.isEmpty) {
      throw StateError('알림 토큰이 아직 준비되지 않았습니다. 잠시 후 다시 동기화합니다.');
    }
    await store.writeDevice(accountKey, deviceId, enabled: true, token: token);
  }

  /// Call before Firebase sign-out. A confirmed server disable OR confirmed
  /// FCM invalidation suffices to detach. If neither works, the caller must keep
  /// the authenticated session and let the user retry when online.
  Future<void> detach() {
    final authenticatedAccount = currentUid();
    final previousAccount = _accountKey ?? authenticatedAccount;
    _bindingBlocked = true;
    _accountKey = null;
    ++_revision;
    final detachRevision = ++_detachRevision;
    return _enqueue(() async {
      await _cancelRefresh();
      await settings.setRotationRequired(true);
      final deviceId = await settings.deviceId();
      Object? unlinkError;
      Object? rotationError;
      await Future.wait<void>([
        () async {
          try {
            if (previousAccount == null || currentUid() != previousAccount) {
              throw StateError('알림을 해제할 인증 세션이 없습니다.');
            }
            await store.writeDevice(previousAccount, deviceId, enabled: false);
            // No server uses this field any more. Remove it when authorized.
            try {
              await store.clearLegacyToken(previousAccount);
            } catch (error, stack) {
              onBackgroundError(error, stack);
            }
          } catch (error) {
            unlinkError = error;
          }
        }(),
        () async {
          try {
            await tokens.deleteToken();
            await settings.setRotationRequired(false);
            await settings.setOwner(null);
          } catch (error) {
            rotationError = error;
          }
        }(),
      ]);
      if (unlinkError != null && rotationError != null) {
        throw StateError('개인 알림 연결을 해제하지 못했습니다. 인터넷 연결 후 다시 로그아웃해 주세요.');
      }
    }).catchError((Object error, StackTrace stack) {
      if (_detachRevision == detachRevision) _bindingBlocked = false;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _cancelRefresh() async {
    ++_listenerRevision;
    final subscription = _refreshSubscription;
    _refreshSubscription = null;
    await subscription?.cancel();
  }
}

/// Shares confirmed/pending state between settings and foreground retries.
/// An older successful operation cannot clear a newer failed user preference.
class NotificationDeliveryReconciler {
  NotificationDeliveryReconciler({
    required this.syncTopic,
    required this.onPendingChanged,
  });

  final Future<void> Function() syncTopic;
  final void Function(bool) onPendingChanged;
  int _revision = 0;

  Future<void> reconcile(
    Future<void> Function() personalOperation, {
    bool updateTopic = true,
  }) async {
    final revision = ++_revision;
    onPendingChanged(true);
    Object? failure;
    StackTrace? failureStack;
    try {
      await personalOperation();
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
    if (updateTopic) {
      // Public opt-out must still be attempted when a private update fails.
      try {
        await syncTopic();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    if (_revision == revision) onPendingChanged(false);
  }
}
