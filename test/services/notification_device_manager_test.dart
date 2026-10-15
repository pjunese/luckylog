import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/notification_device_manager.dart';

class _Settings implements NotificationDeviceSettings {
  String? account;
  bool rotation = false;
  bool optedIn = true;
  final List<bool> savedSettings = [];

  @override
  Future<String> deviceId() async => 'stable-device';
  @override
  Future<String?> owner() async => account;
  @override
  Future<void> setOwner(String? accountKey) async => account = accountKey;
  @override
  Future<bool> rotationRequired() async => rotation;
  @override
  Future<void> setRotationRequired(bool value) async => rotation = value;
  @override
  Future<bool> enabled() async => optedIn;
  @override
  Future<void> setEnabled(bool value) async {
    savedSettings.add(value);
    optedIn = value;
  }
}

class _Tokens implements NotificationTokenClient {
  _Tokens() {
    controller = StreamController<String>.broadcast(
      sync: true,
      onListen: () => activeListeners++,
      onCancel: () => activeListeners--,
    );
  }
  late final StreamController<String> controller;
  int activeListeners = 0;
  int rotations = 0;
  int fetches = 0;
  bool offline = false;
  Completer<String?>? tokenGate;
  Completer<void>? fetchStarted;

  @override
  Stream<String> get onTokenRefresh => controller.stream;
  @override
  Future<String?> getToken() async {
    fetches++;
    fetchStarted?.complete();
    return tokenGate == null ? 'token-$rotations' : tokenGate!.future;
  }

  @override
  Future<void> deleteToken() async {
    if (offline) throw StateError('token service offline');
    rotations++;
  }
}

class _Write {
  _Write(this.account, this.device, this.enabled, this.token);
  final String account;
  final String device;
  final bool enabled;
  final String? token;
}

class _Store implements NotificationDeviceStore {
  final List<_Write> writes = [];
  final List<String> legacyCleared = [];
  bool offline = false;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;

  @override
  Future<void> writeDevice(
    String accountKey,
    String deviceId, {
    required bool enabled,
    String? token,
  }) async {
    if (offline) throw StateError('database offline');
    final gate = writeGate;
    writeGate = null;
    writeStarted?.complete();
    writeStarted = null;
    if (gate != null) await gate.future;
    writes.add(_Write(accountKey, deviceId, enabled, token));
  }

  @override
  Future<void> clearLegacyToken(String accountKey) async {
    if (offline) throw StateError('database offline');
    legacyCleared.add(accountKey);
  }
}

void main() {
  late _Settings settings;
  late _Tokens tokens;
  late _Store store;
  late NotificationDeviceManager manager;
  late List<Object> backgroundErrors;
  String? uid;

  setUp(() {
    uid = 'kakao:A';
    settings = _Settings();
    tokens = _Tokens();
    store = _Store();
    backgroundErrors = [];
    manager = NotificationDeviceManager(
      settings: settings,
      tokens: tokens,
      store: store,
      currentUid: () => uid,
      onBackgroundError: (error, _) => backgroundErrors.add(error),
    );
  });

  tearDown(() async {
    await tokens.controller.close();
  });

  test('unknown legacy ownership rotates before registration', () async {
    await manager.bind('kakao:A');
    expect(tokens.rotations, 1);
    expect(store.writes.single.token, 'token-1');
    expect(store.writes.single.account, 'kakao:A');
    expect(store.writes.single.device, 'stable-device');
    expect(store.legacyCleared, ['kakao:A']);
    expect(settings.account, 'kakao:A');
    expect(settings.rotation, false);
  });

  test('repeated resume retains one refresh listener', () async {
    await manager.bind('kakao:A');
    await manager.bind('kakao:A');
    await manager.bind('kakao:A');
    expect(tokens.activeListeners, 1);
    expect(tokens.rotations, 1);
    tokens.controller.add('refreshed');
    await Future<void>.delayed(Duration.zero);
    expect(store.writes.where((write) => write.token == 'refreshed').length, 1);
    await manager.detach();
    expect(tokens.activeListeners, 0);
  });

  test(
    'resume discards refresh queued by the superseded subscription',
    () async {
      await manager.bind('kakao:A');
      final resume = manager.bind('kakao:A');
      tokens.controller.add('obsolete-token');
      await resume;
      await Future<void>.delayed(Duration.zero);
      expect(store.writes.last.token, 'token-1');
      expect(
        store.writes.where((write) => write.token == 'obsolete-token'),
        isEmpty,
      );
    },
  );

  test('account switch discards the previous account token fetch', () async {
    tokens.tokenGate = Completer<String?>();
    tokens.fetchStarted = Completer<void>();
    final bindingA = manager.bind('kakao:A');
    await tokens.fetchStarted!.future;
    final gate = tokens.tokenGate!;
    tokens.tokenGate = null;
    tokens.fetchStarted = null;
    uid = 'apple:B';
    final bindingB = manager.bind('apple:B');
    gate.complete('late-A-token');
    await bindingA;
    await bindingB;
    expect(store.writes, hasLength(1));
    expect(store.writes.single.account, 'apple:B');
    expect(store.writes.single.token, 'token-2');
    expect(tokens.activeListeners, 1);
  });

  test('logout invalidates a token fetch that has not completed', () async {
    tokens.tokenGate = Completer<String?>();
    tokens.fetchStarted = Completer<void>();
    final binding = manager.bind('kakao:A');
    await tokens.fetchStarted!.future;
    final logout = manager.detach();
    tokens.tokenGate!.complete('late-A-token');
    await binding;
    await logout;
    expect(store.writes.where((write) => write.enabled), isEmpty);
    expect(store.writes.last.enabled, false);
    expect(tokens.activeListeners, 0);
  });

  test(
    'logout waits for an in-flight write and leaves device disabled',
    () async {
      store.writeGate = Completer<void>();
      final gate = store.writeGate!;
      store.writeStarted = Completer<void>();
      final started = store.writeStarted!;
      final binding = manager.bind('kakao:A');
      await started.future;
      final logout = manager.detach();
      tokens.controller.add('late-refresh');
      gate.complete();
      await binding;
      await logout;
      expect(store.writes.map((write) => write.enabled), [true, false]);
      expect(store.writes.last.token, isNull);
      expect(
        store.writes.where((write) => write.token == 'late-refresh'),
        isEmpty,
      );
    },
  );

  test(
    'disable discards an already queued refresh and saves opt-out',
    () async {
      await manager.bind('kakao:A');
      tokens.controller.add('queued-refresh');
      await manager.setEnabled(false);
      expect(settings.optedIn, false);
      expect(store.writes.last.enabled, false);
      expect(store.writes.last.token, isNull);
      expect(tokens.activeListeners, 0);
      expect(
        store.writes.where((write) => write.token == 'queued-refresh'),
        isEmpty,
      );
      tokens.controller.add('after-disable');
      await Future<void>.delayed(Duration.zero);
      expect(store.writes.last.enabled, false);
    },
  );

  test(
    'same-account resume cannot report opt-out before its write completes',
    () async {
      await manager.bind('kakao:A');
      store.writeGate = Completer<void>();
      final gate = store.writeGate!;
      store.writeStarted = Completer<void>();
      final started = store.writeStarted!;
      var settingCompleted = false;
      final setting = manager
          .setEnabled(false)
          .then((_) => settingCompleted = true);
      final resumed = manager.bind('kakao:A');
      await started.future;
      expect(settingCompleted, false);
      gate.complete();
      await setting;
      await resumed;
      expect(store.writes.last.enabled, false);
      expect(tokens.activeListeners, 0);
    },
  );

  test('refresh errors are handled and later settings still run', () async {
    await manager.bind('kakao:A');
    store.offline = true;
    tokens.controller.add('offline-refresh');
    await Future<void>.delayed(Duration.zero);
    expect(backgroundErrors, hasLength(1));
    store.offline = false;
    await manager.setEnabled(false);
    expect(store.writes.last.enabled, false);
  });

  test('failed setting cannot drop a later queued choice', () async {
    await manager.bind('kakao:A');
    store.offline = true;
    await expectLater(manager.setEnabled(false), throwsStateError);
    expect(settings.optedIn, false);
    store.offline = false;
    final off = manager.setEnabled(false);
    final on = manager.setEnabled(true);
    final offAgain = manager.setEnabled(false);
    await Future.wait([off, on, offAgain]);
    expect(settings.savedSettings, [false, false, true, false]);
    expect(settings.optedIn, false);
    expect(store.writes.last.enabled, false);
  });

  test(
    'offline logout fails safely and next account cannot reuse token',
    () async {
      await manager.bind('kakao:A');
      store.offline = true;
      tokens.offline = true;
      await expectLater(manager.detach(), throwsStateError);
      expect(settings.rotation, true);
      expect(tokens.activeListeners, 0);
      uid = 'apple:B';
      store.offline = false;
      await expectLater(manager.bind('apple:B'), throwsStateError);
      expect(
        store.writes.where((write) => write.account == 'apple:B'),
        isEmpty,
      );
      tokens.offline = false;
      await manager.bind('apple:B');
      expect(store.writes.last.token, 'token-2');
      expect(store.writes.last.account, 'apple:B');
      expect(settings.rotation, false);
    },
  );

  test(
    'confirmed unlink allows logout but failed rotation stays pending',
    () async {
      await manager.bind('kakao:A');
      tokens.offline = true;
      await manager.detach();
      expect(store.writes.last.enabled, false);
      expect(settings.rotation, true);
      uid = 'apple:B';
      await expectLater(manager.bind('apple:B'), throwsStateError);
      expect(store.writes.last.account, 'kakao:A');
    },
  );

  test(
    'confirmed FCM deletion allows logout when device unlink fails',
    () async {
      await manager.bind('kakao:A');
      store.offline = true;
      await manager.detach();
      expect(tokens.rotations, 2);
      expect(settings.rotation, false);
      expect(settings.account, isNull);
      expect(tokens.activeListeners, 0);
    },
  );

  test(
    'foreground sync cannot rebind during or immediately after logout',
    () async {
      await manager.bind('kakao:A');
      store.writeGate = Completer<void>();
      final gate = store.writeGate!;
      store.writeStarted = Completer<void>();
      final started = store.writeStarted!;
      final logout = manager.detach();
      await started.future;
      await expectLater(manager.bind('kakao:A'), throwsStateError);
      gate.complete();
      await logout;
      await expectLater(manager.bind('kakao:A'), throwsStateError);
      await manager.setEnabled(true);
      expect(store.writes.last.enabled, false);
      expect(tokens.activeListeners, 0);
      // Only a completed new login can reopen registration, even for the same UID.
      manager.allowBinding();
      await manager.bind('kakao:A');
      expect(store.writes.last.enabled, true);
      expect(store.writes.last.token, 'token-3');
    },
  );

  test('saved opt-out never fetches or registers a personal token', () async {
    settings.optedIn = false;
    await manager.bind('kakao:A');
    expect(tokens.fetches, 0);
    expect(tokens.activeListeners, 0);
    expect(store.writes.single.enabled, false);
    expect(store.writes.single.token, isNull);
  });

  test(
    'missing APNs/FCM token stays retryable instead of reporting success',
    () async {
      tokens.tokenGate = Completer<String?>()..complete(null);
      await expectLater(manager.bind('kakao:A'), throwsStateError);
      expect(store.writes, isEmpty);
    },
  );

  test(
    'private failure still reconciles topic and stays visibly pending',
    () async {
      var pending = false;
      var topicCalls = 0;
      final delivery = NotificationDeliveryReconciler(
        syncTopic: () async {
          topicCalls++;
        },
        onPendingChanged: (value) => pending = value,
      );
      await expectLater(
        delivery.reconcile(() async {
          throw StateError('private offline');
        }),
        throwsStateError,
      );
      expect(topicCalls, 1);
      expect(pending, true);
      await delivery.reconcile(() async {});
      expect(pending, false);
    },
  );

  test('older successful retry cannot clear newer failed setting', () async {
    var pending = false;
    final delivery = NotificationDeliveryReconciler(
      syncTopic: () async {},
      onPendingChanged: (value) => pending = value,
    );
    final oldRequest = Completer<void>();
    final older = delivery.reconcile(() => oldRequest.future);
    await expectLater(
      delivery.reconcile(() async {
        throw StateError('new setting offline');
      }),
      throwsStateError,
    );
    oldRequest.complete();
    await older;
    expect(pending, true);
    await delivery.reconcile(() async {});
    expect(pending, false);
  });

  test('mismatched Firebase identity cannot bind another account', () async {
    await expectLater(manager.bind('apple:B'), throwsStateError);
    expect(store.writes, isEmpty);
    expect(tokens.rotations, 0);
  });
}
