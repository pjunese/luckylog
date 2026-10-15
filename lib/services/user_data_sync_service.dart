import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/account_data_sync_engine.dart';
import '../data/private_record.dart';
import '../db/lotto_database.dart';
import 'firebase_auth_bridge.dart';

/// Account-bound incremental backup. Local absence never means remote deletion.
class UserDataSyncService {
  UserDataSyncService._();

  static final _engine = AccountDataSyncEngine(
    database: LottoDatabase.instance,
    remote: _FirestorePrivateRecords(),
    isOwnerActive: (owner) =>
        LottoDatabase.instance.accountKey == owner &&
        FirebaseAuthBridge.uid == owner,
  );

  static Future<void> syncOnLogin({
    required String accountKey,
    required int userNumber,
  }) async {
    try {
      await _engine.sync(accountKey);
    } catch (e) {
      debugPrint('[UserSync] sync deferred; local changes retained: $e');
      rethrow;
    }
  }

  /// Compatibility name: uploads only explicit dirty rows and tombstones.
  /// Also pulls changes since the last server watermark to converge devices.
  static Future<void> pushLocalSnapshot({
    required String accountKey,
    required int userNumber,
  }) {
    return _engine.sync(accountKey);
  }
}

class _FirestorePrivateRecords implements PrivateRecordRemote {
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _collection(
    String owner,
    String collection,
  ) => _firestore.collection('users').doc(owner).collection(collection);

  @override
  Future<List<RemotePrivateRecord>> pull(
    String owner,
    String collection,
    int? sinceMicros,
  ) async {
    Query<Map<String, dynamic>> query = _collection(owner, collection);
    if (sinceMicros != null) {
      // Inclusive boundary prevents losing records sharing a server timestamp.
      query = query.where(
        'updatedAt',
        isGreaterThanOrEqualTo: Timestamp.fromMicrosecondsSinceEpoch(
          sinceMicros,
        ),
      );
    }
    final snapshot = await query
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 15));
    final records = <RemotePrivateRecord>[];
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final record = privateRecordFromRemote(
        collection,
        doc.id,
        {
          ...data,
          'createdAt': _iso(data['createdAt'] ?? data['created_at']),
          'resultCheckedAt': _iso(
            data['resultCheckedAt'] ?? data['result_checked_at'],
          ),
        },
        updatedAtMicros: data['updatedAt'] is Timestamp
            ? (data['updatedAt'] as Timestamp).microsecondsSinceEpoch
            : null,
      );
      if (record == null) {
        debugPrint('[UserSync] skipped invalid $collection record ${doc.id}');
      } else {
        records.add(record);
      }
    }
    return records;
  }

  @override
  Future<bool> push(
    String owner,
    PendingPrivateRecord change,
    bool Function() isActive,
  ) {
    final reference = _collection(owner, change.collection).doc(change.id);
    return _firestore.runTransaction<bool>(
      (transaction) async {
        if (!isActive()) {
          throw StateError('Account changed before synchronization.');
        }
        final existing = await transaction.get(reference);
        if (existing.data()?['deleted'] == true) return true;
        if (!isActive()) {
          throw StateError('Account changed during synchronization.');
        }
        final previous = existing.data() ?? <String, dynamic>{};
        final values = privateRecordToRemote(
          change,
          existing: {
            ...previous,
            'resultCheckedAt': _iso(
              previous['resultCheckedAt'] ?? previous['result_checked_at'],
            ),
          },
        )..['updatedAt'] = FieldValue.serverTimestamp();
        transaction.set(reference, values, SetOptions(merge: true));
        return change.deleted;
      },
      timeout: const Duration(seconds: 15),
      maxAttempts: 3,
    );
  }

  static String _iso(dynamic value) => switch (value) {
    Timestamp stamp => stamp.toDate().toIso8601String(),
    DateTime date => date.toIso8601String(),
    String text => text,
    _ => '',
  };
}
