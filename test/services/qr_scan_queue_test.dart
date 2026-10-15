import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/models/scanned_ticket.dart';
import 'package:my_app/services/qr_scan_queue.dart';

void main() {
  const first = '1230q0102030405060000000001';
  const second = '1230q0102030405060000000002';

  test('same-ticket URL variants deduplicate but identical games do not', () {
    final queue = QrScanQueue();
    expect(queue.add(first).outcome, QrScanOutcome.added);
    expect(
      queue.add('http://m.dhlottery.co.kr/qr.do?method=winQr&v=$first').outcome,
      QrScanOutcome.queuedDuplicate,
    );
    expect(queue.add(second).outcome, QrScanOutcome.added);
    expect(queue.length, 2);
    expect(queue.gameCount, 2);
    expect(queue.tickets[0].games, queue.tickets[1].games);
  });

  test('known fingerprints including deleted tickets are not queued', () {
    final ticket = ScannedTicket.tryParse(first)!;
    final queue = QrScanQueue(knownFingerprints: {ticket.fingerprint});
    final feedback = queue.add(first);
    expect(feedback.outcome, QrScanOutcome.knownDuplicate);
    expect(feedback.message, contains('구매내역 휴지통에서 복원'));
    expect(queue.isEmpty, true);
  });

  test('foreign QR is rejected and valid unparseable QR stays lookup-only', () {
    final queue = QrScanQueue();
    final bad = queue.add('https://evil.invalid/qr.do?method=winQr&v=$first');
    expect(bad.outcome, QrScanOutcome.invalid);
    expect(bad.lookupUri, isNull);
    final lookup = queue.add('1230m010101010101');
    expect(lookup.outcome, QrScanOutcome.lookupOnly);
    expect(lookup.lookupUri!.host, 'qr.dhlottery.co.kr');
    expect(lookup.lookupUri!.scheme, 'https');
    expect(queue.isEmpty, true);
  });

  test('remove changes only the unsaved queue and permits explicit re-add', () {
    final queue = QrScanQueue();
    queue.add(first);
    final fingerprint = queue.tickets.single.fingerprint;
    expect(queue.remove(fingerprint), true);
    expect(queue.remove(fingerprint), false);
    expect(queue.isEmpty, true);
    expect(queue.add(first).outcome, QrScanOutcome.added);
  });

  test('save snapshot is immutable and isolated from later queue changes', () {
    final queue = QrScanQueue()..add(first);
    final snapshot = queue.tickets;
    queue.add(second);
    expect(snapshot, hasLength(1));
    expect(() => snapshot.clear(), throwsUnsupportedError);
  });
}
