import '../models/scanned_ticket.dart';
import 'lotto_qr_policy.dart';

enum QrScanOutcome {
  added,
  queuedDuplicate,
  knownDuplicate,
  lookupOnly,
  invalid,
}

class QrScanFeedback {
  const QrScanFeedback(this.outcome, {this.ticket, this.lookupUri});

  final QrScanOutcome outcome;
  final ScannedTicket? ticket;
  final Uri? lookupUri;

  String get message => switch (outcome) {
    QrScanOutcome.added => '${ticket!.round}회 복권을 추가했어요.',
    QrScanOutcome.queuedDuplicate => '이미 대기 목록에 있는 복권입니다.',
    QrScanOutcome.knownDuplicate => '이미 등록한 복권입니다. 삭제했다면 구매내역 휴지통에서 복원해주세요.',
    QrScanOutcome.lookupOnly => '번호를 읽지 못했어요. 동행복권에서 결과를 확인할 수 있습니다.',
    QrScanOutcome.invalid => '동행복권 로또 QR 코드를 비춰 주세요.',
  };
}

/// Identical game numbers may belong to different purchased tickets. Only the
/// model's complete QR-token fingerprint decides whether a ticket is repeated.
class QrScanQueue {
  QrScanQueue({Set<String> knownFingerprints = const {}})
    : _known = Set.unmodifiable(knownFingerprints);

  final Set<String> _known;
  final Map<String, ScannedTicket> _tickets = {};

  List<ScannedTicket> get tickets => List.unmodifiable(_tickets.values);
  bool get isEmpty => _tickets.isEmpty;
  int get length => _tickets.length;
  int get gameCount =>
      _tickets.values.fold(0, (total, ticket) => total + ticket.games.length);

  QrScanFeedback add(String raw) {
    final uri = LottoQrPolicy.fromScan(raw);
    if (uri == null) return const QrScanFeedback(QrScanOutcome.invalid);
    final ticket = ScannedTicket.tryParse(raw);
    if (ticket == null) {
      return QrScanFeedback(QrScanOutcome.lookupOnly, lookupUri: uri);
    }
    if (_known.contains(ticket.fingerprint)) {
      return const QrScanFeedback(QrScanOutcome.knownDuplicate);
    }
    if (_tickets.containsKey(ticket.fingerprint)) {
      return const QrScanFeedback(QrScanOutcome.queuedDuplicate);
    }
    _tickets[ticket.fingerprint] = ticket;
    return QrScanFeedback(QrScanOutcome.added, ticket: ticket);
  }

  bool remove(String fingerprint) => _tickets.remove(fingerprint) != null;
}
