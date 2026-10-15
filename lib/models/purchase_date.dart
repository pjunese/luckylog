String purchaseDateKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

DateTime? parsePurchaseDate(dynamic value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final date = DateTime.tryParse('${value}T00:00:00Z');
  return date != null && date.year >= 2002 && purchaseDateKey(date) == value
      ? date
      : null;
}

/// Keep an explicitly chosen date across old clients and concurrent edits.
/// Equal timestamps choose the same calendar date on every device.
Map<String, dynamic> mergePurchaseDateFields(
  dynamic dayA,
  dynamic editA,
  dynamic dayB,
  dynamic editB,
) {
  final a = parsePurchaseDate(dayA);
  final b = parsePurchaseDate(dayB);
  final ta = editA is String ? DateTime.tryParse(editA)?.toUtc() : null;
  final tb = editB is String ? DateTime.tryParse(editB)?.toUtc() : null;
  final validA = a != null && ta != null;
  final validB = b != null && tb != null;
  if (!validA && !validB) {
    return {'purchase_date': null, 'purchase_date_updated_at': null};
  }
  final useB =
      validB &&
      (!validA ||
          tb.isAfter(ta) ||
          (tb.isAtSameMomentAs(ta) &&
              (dayB as String).compareTo(dayA as String) > 0));
  return {
    'purchase_date': useB ? dayB : dayA,
    'purchase_date_updated_at': (useB ? tb : ta)!.toIso8601String(),
  };
}
