import 'dart:convert';

/// 보관함에 저장한 번호 세트 (아직 구매 전이거나 구매 처리된 것).
class NumberSet {
  const NumberSet({
    required this.id,
    required this.games,
    required this.createdAt,
    required this.isPurchased,
  });

  final int id;
  final List<List<int>> games;
  final DateTime createdAt;
  final bool isPurchased;

  factory NumberSet.fromDb(Map<String, dynamic> row) {
    final List<List<int>> games =
        (jsonDecode(row['games'] as String) as List<dynamic>)
            .map((g) => List<int>.from(g as List))
            .toList();
    return NumberSet(
      id: row['id'] as int,
      games: games,
      createdAt: DateTime.parse(row['created_at'] as String),
      isPurchased: (row['is_purchased'] as int) == 1,
    );
  }

  NumberSet copyWith({bool? isPurchased}) {
    return NumberSet(
      id: id,
      games: games,
      createdAt: createdAt,
      isPurchased: isPurchased ?? this.isPurchased,
    );
  }
}
