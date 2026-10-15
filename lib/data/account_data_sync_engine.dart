import '../db/lotto_database.dart';
import 'private_record.dart';

abstract interface class PrivateRecordRemote {
  Future<List<RemotePrivateRecord>> pull(
    String owner,
    String collection,
    int? sinceMicros,
  );

  /// Atomically return true if this ID is (or has become) a terminal tombstone.
  /// Implementations must refuse to replace a remote tombstone with live data.
  Future<bool> push(
    String owner,
    PendingPrivateRecord change,
    bool Function() isActive,
  );
}

/// Serializes each owner's work, with ownership captured before every await.
/// Switching accounts never waits for these workers. Dirty SQLite rows are the
/// durable retry queue; a failed request leaves them untouched.
class AccountDataSyncEngine {
  AccountDataSyncEngine({
    required this.database,
    required this.remote,
    required this.isOwnerActive,
  });
  final LottoDatabase database;
  final PrivateRecordRemote remote;
  final bool Function(String owner) isOwnerActive;
  final Map<String, _SyncRun> _runs = {};

  Future<void> sync(String owner, {bool pull = true}) {
    if (!isOwnerActive(owner)) return Future.value();
    final running = _runs[owner];
    if (running != null) {
      running.repeat = true;
      running.pull = running.pull || pull;
      return running.future;
    }
    final run = _SyncRun()..pull = pull;
    _runs[owner] = run;
    run.future = _work(owner, run).whenComplete(() => _runs.remove(owner));
    return run.future;
  }

  Future<void> _work(String owner, _SyncRun run) async {
    do {
      run.repeat = false;
      if (run.pull) {
        run.pull = false;
        for (final collection in privateCollections) {
          if (!isOwnerActive(owner)) return;
          final watermark = await database.syncWatermark(owner, collection);
          if (!isOwnerActive(owner)) return;
          final records = await remote.pull(owner, collection, watermark);
          if (!isOwnerActive(owner)) return;
          await database.applyRemoteRecords(owner, collection, records);
        }
      }
      while (isOwnerActive(owner)) {
        final changes = await database.pendingChanges(owner);
        if (changes.isEmpty) break;
        for (final change in changes) {
          if (!isOwnerActive(owner)) return;
          final deleted = await remote.push(
            owner,
            change,
            () => isOwnerActive(owner),
          );
          // Even a late response can only acknowledge its captured owner's row.
          await database.acknowledgeUpload(
            owner,
            change,
            remoteDeleted: deleted,
          );
        }
      }
    } while (run.repeat && isOwnerActive(owner));
  }
}

class _SyncRun {
  bool repeat = false;
  bool pull = false;
  late Future<void> future;
}
