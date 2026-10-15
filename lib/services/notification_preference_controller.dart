import 'dart:async';
import 'package:flutter/foundation.dart';

/// Local intent never waits behind a previous push-token network request.
class NotificationPreferenceController {
  NotificationPreferenceController({
    required this.read,
    required this.save,
    required this.requestPermission,
    required this.sync,
    required this.onSyncError,
  });
  final Future<bool> Function() read;
  final Future<void> Function(bool) save;
  final Future<bool> Function() requestPermission;
  final Future<void> Function(bool) sync;
  final void Function(Object, StackTrace) onSyncError;
  final enabled = ValueNotifier<bool>(false);
  int _revision = 0;
  bool _persisted = false;
  Future<void> _writes = Future<void>.value();
  Future<bool>? _permission;

  Future<bool> load() async {
    if (_revision != 0) return enabled.value;
    final revision = _revision;
    final stored = await read();
    if (revision == _revision) {
      _persisted = stored;
      enabled.value = stored;
    }
    return enabled.value;
  }

  Future<bool> setEnabled(bool value) {
    final revision = ++_revision;
    enabled.value = value;
    return _commit(value, revision);
  }

  Future<bool> _commit(bool value, int revision) async {
    try {
      var applied = false;
      if (value) {
        final permission = _permission ??= requestPermission();
        try {
          applied = await permission;
        } finally {
          if (identical(_permission, permission)) _permission = null;
        }
      }
      if (revision != _revision) return enabled.value;
      final write = _writes.then((_) async {
        if (revision != _revision) return;
        await save(applied);
        _persisted = applied;
        if (revision != _revision) return;
        enabled.value = applied;
        unawaited(
          Future<void>.sync(() => sync(applied)).catchError(onSyncError),
        );
      });
      _writes = write.catchError((Object _, StackTrace _) {});
      await write;
      return enabled.value;
    } catch (_) {
      if (revision == _revision) enabled.value = _persisted;
      rethrow;
    }
  }
}
