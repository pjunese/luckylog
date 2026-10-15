import '../core/lotto_validation.dart';

/// All QR input is normalized before it reaches a browser. Subsequent browser
/// navigation is checked independently, including redirects and subframes.
class LottoQrPolicy {
  LottoQrPolicy._();

  static const _hosts = {
    'dhlottery.co.kr',
    'www.dhlottery.co.kr',
    'm.dhlottery.co.kr',
    'qr.dhlottery.co.kr',
  };
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{8,2048}$');

  static bool allowsNavigation(Uri uri) =>
      uri.scheme == 'https' &&
      _hosts.contains(uri.host) &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);

  static Uri? fromScan(String raw) {
    final input = raw.trim();
    if (input.isEmpty || input.length > 4096) return null;
    try {
      final uri = Uri.tryParse(input);
      String? token;
      if (uri != null && uri.hasScheme) {
        if ((uri.scheme != 'http' && uri.scheme != 'https') ||
            !_hosts.contains(uri.host) ||
            uri.userInfo.isNotEmpty ||
            (uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80)) ||
            uri.hasFragment ||
            uri.queryParametersAll['v']?.length != 1) {
          return null;
        }
        final printed = uri.path.isEmpty || uri.path == '/';
        final legacy =
            uri.path == '/qr.do' &&
            uri.queryParametersAll['method']?.length == 1 &&
            uri.queryParameters['method'] == 'winQr';
        if (!printed && !legacy) return null;
        token = uri.queryParameters['v'];
      } else {
        token = input.startsWith('?v=')
            ? input.substring(3)
            : input.startsWith('v=')
            ? input.substring(2)
            : input;
      }
      if (token == null || !_tokenPattern.hasMatch(token)) return null;
      // Discard unrelated query parameters rather than forwarding redirect URLs.
      return Uri.https('qr.dhlottery.co.kr', '/', {'v': token});
    } on FormatException {
      return null;
    }
  }

  static int? round(Uri uri) {
    if (!allowsNavigation(uri)) return null;
    final token = uri.queryParameters['v'] ?? '';
    final match = RegExp(r'^(\d{4})').firstMatch(token);
    final round = match == null ? null : int.tryParse(match.group(1)!);
    return round != null && round > 0 ? round : null;
  }

  static List<List<int>>? games(Uri uri) {
    if (!allowsNavigation(uri)) return null;
    final token = uri.queryParameters['v'] ?? '';
    // Official tickets use 13-character slots: q (auto), m (manual),
    // s (semi-auto), n (unused), followed by the ticket serial number.
    // Parse the complete payload so a damaged slot cannot silently disappear.
    if (!RegExp(r'^\d{4}(?:[qmsn]\d{12}){1,5}\d{0,18}$').hasMatch(token)) {
      return null;
    }
    final games = <List<int>>[];
    final slots = RegExp(r'([qmsn])(\d{12})').allMatches(token.substring(4));
    for (final slot in slots) {
      final digits = slot.group(2)!;
      if (slot.group(1) == 'n') {
        if (digits != '000000000000') return null;
        continue;
      }
      games.add(
        List.generate(6, (i) => int.parse(digits.substring(i * 2, i * 2 + 2))),
      );
    }
    if (games.isEmpty || games.length > 5 || !games.every(isValidLottoGame)) {
      return null;
    }
    return games;
  }
}
