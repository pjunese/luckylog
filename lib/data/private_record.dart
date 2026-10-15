import 'dart:convert';

import '../core/lotto_validation.dart';
import '../models/purchase_date.dart';

/// The two account-private collections. Keep remote IDs stable across edits.
const privateCollections = ['number_sets', 'purchase_history'];

String legacyRemoteId(String collection, Map<String, dynamic> row) {
  final games = jsonEncode(decodeGames(row['games']));
  final createdAt = row['created_at'];
  final signature = collection == 'number_sets'
      ? 'set|$createdAt|$games'
      : 'history|$createdAt|${row['round']}|${row['source']}|$games';
  return base64UrlEncode(utf8.encode(signature)).replaceAll('=', '');
}

List<List<int>> decodeGames(dynamic value) {
  try {
    final raw = value is String ? jsonDecode(value) : value;
    return (raw as List)
        .map((game) => (game as List).map((number) => number as int).toList())
        .toList();
  } catch (_) {
    return const [];
  }
}

bool isValidPrivateRecord(String collection, Map<String, dynamic> row) {
  final games = decodeGames(row['games']);
  return games.isNotEmpty &&
      games.every(isValidLottoGame) &&
      row['created_at'] is String &&
      (row['created_at'] as String).isNotEmpty &&
      (collection != 'purchase_history' ||
          (row['round'] is int &&
              (row['round'] as int) > 0 &&
              row['draw_date'] is String &&
              row['source'] is String)) &&
      (collection != 'number_sets' ||
          row['qr_raw'] == null ||
          row['qr_raw'] is String);
}

class RemotePrivateRecord {
  const RemotePrivateRecord({
    required this.id,
    required this.values,
    required this.deleted,
    this.updatedAtMicros,
  });

  final String id;

  /// SQLite field names, excluding local ownership and synchronization metadata.
  final Map<String, dynamic> values;
  final bool deleted;
  final int? updatedAtMicros;
}

class PendingPrivateRecord {
  const PendingPrivateRecord(this.collection, this.row);
  final String collection;
  final Map<String, dynamic> row;
  String get id => row['remote_id'] as String;
  int get revision => row['local_revision'] as int;
  bool get deleted => row['deleted'] == 1;
}

/// Checking is a grow-only state. Keep the earliest known valid timestamp so
/// simultaneous device checks converge and an older write cannot clear it.
String? mergeResultCheckedAt(dynamic first, dynamic second) {
  DateTime? parsed(dynamic value) => value is DateTime
      ? value.toUtc()
      : value is String
      ? DateTime.tryParse(value)?.toUtc()
      : null;
  final a = parsed(first);
  final b = parsed(second);
  final result = a == null
      ? b
      : b == null || a.isBefore(b)
      ? a
      : b;
  return result?.toIso8601String();
}

String _isoText(dynamic value) => value is DateTime
    ? value.toIso8601String()
    : value is String
    ? value
    : '';
int? _recordInt(dynamic value) => value is int
    ? value
    : value is num
    ? value.toInt()
    : value is String
    ? int.tryParse(value)
    : null;
String? _fingerprint(dynamic value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value) ? value : null;

/// Firebase Timestamp values are converted by the adapter before this pure codec.
RemotePrivateRecord? privateRecordFromRemote(
  String collection,
  String id,
  Map<String, dynamic> data, {
  int? updatedAtMicros,
}) {
  if (!privateCollections.contains(collection)) return null;
  final games = decodeGames(data['games']);
  final round = _recordInt(data['round']);
  final values = <String, dynamic>{
    'games': jsonEncode(games),
    'created_at': _isoText(data['createdAt'] ?? data['created_at']),
    'round': round,
  };
  if (collection == 'number_sets') {
    final purchased = data['isPurchased'] ?? data['is_purchased'];
    values.addAll({
      'is_purchased':
          purchased == true ||
              purchased == 1 ||
              purchased == '1' ||
              purchased == 'true'
          ? 1
          : 0,
      'qr_raw': data['qrRaw'] ?? data['qr_raw'],
    });
  } else {
    final drawDate = data['drawDate'] ?? data['draw_date'];
    final derivedDate = round == null || round <= 0
        ? null
        : DateTime(2002, 12, 7).add(Duration(days: (round - 1) * 7));
    values.addAll({
      'draw_date':
          drawDate ??
          (derivedDate == null
              ? ''
              : '${derivedDate.year}-${derivedDate.month.toString().padLeft(2, '0')}-${derivedDate.day.toString().padLeft(2, '0')}'),
      'source': data['source'] ?? 'manual',
      'qr_fingerprint': _fingerprint(
        data['qrFingerprint'] ?? data['qr_fingerprint'],
      ),
      'result_checked_at': mergeResultCheckedAt(
        data['resultCheckedAt'] ?? data['result_checked_at'],
        null,
      ),
      ...mergePurchaseDateFields(
        data['purchaseDate'] ?? data['purchase_date'],
        data['purchaseDateUpdatedAt'] ?? data['purchase_date_updated_at'],
        null,
        null,
      ),
    });
  }
  if (!isValidPrivateRecord(collection, values)) return null;
  return RemotePrivateRecord(
    id: id,
    values: values,
    deleted: data['deleted'] == true,
    updatedAtMicros: updatedAtMicros,
  );
}

Map<String, dynamic> privateRecordToRemote(
  PendingPrivateRecord change, {
  Map<String, dynamic> existing = const {},
}) {
  final row = change.row;
  final values = <String, dynamic>{
    'games': row['games'],
    'createdAt': row['created_at'],
    'round': row['round'],
    'deleted': change.deleted,
  };
  if (change.collection == 'number_sets') {
    values.addAll({
      'isPurchased': row['is_purchased'] == 1,
      'qrRaw': row['qr_raw'],
    });
  } else {
    final purchaseDate = mergePurchaseDateFields(
      row['purchase_date'],
      row['purchase_date_updated_at'],
      existing['purchaseDate'] ?? existing['purchase_date'],
      existing['purchaseDateUpdatedAt'] ?? existing['purchase_date_updated_at'],
    );
    values.addAll({
      'drawDate': row['draw_date'],
      'purchaseDate': purchaseDate['purchase_date'],
      'purchaseDateUpdatedAt': purchaseDate['purchase_date_updated_at'],
      'source': row['source'],
      'qrFingerprint':
          _fingerprint(row['qr_fingerprint']) ??
          _fingerprint(existing['qrFingerprint'] ?? existing['qr_fingerprint']),
      'resultCheckedAt': mergeResultCheckedAt(
        row['result_checked_at'],
        existing['resultCheckedAt'] ?? existing['result_checked_at'],
      ),
    });
  }
  return values;
}
