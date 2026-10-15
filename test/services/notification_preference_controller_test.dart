import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/notification_preference_controller.dart';

void main() {
  late bool stored;
  late List<bool> syncs;
  late List<Object> errors;
  late NotificationPreferenceController controller;
  Future<bool> Function() permission = () async => true;
  Future<void> Function(bool) sync = (_) async {};
  setUp(() {
    stored = false;
    syncs = [];
    errors = [];
    permission = () async => true;
    sync = (_) async {};
    controller = NotificationPreferenceController(
      read: () async => stored,
      save: (value) async {
        stored = value;
      },
      requestPermission: () => permission(),
      sync: (value) async {
        syncs.add(value);
        await sync(value);
      },
      onSyncError: (e, _) => errors.add(e),
    );
  });
  tearDown(() => controller.enabled.dispose());

  test('a slow remote request cannot hold the next local toggle', () async {
    final gate = Completer<void>();
    sync = (_) => gate.future;
    final first = controller.setEnabled(true);
    expect(controller.enabled.value, true);
    await first;
    expect(stored, true);
    await controller.setEnabled(false);
    expect(stored, false);
    expect(controller.enabled.value, false);
    expect(syncs, [true, false]);
    gate.complete();
  });
  test('late permission response cannot undo a newer OFF request', () async {
    final gate = Completer<bool>();
    permission = () => gate.future;
    final first = controller.setEnabled(true);
    await controller.setEnabled(false);
    gate.complete(true);
    await first;
    expect(stored, false);
    expect(syncs, [false]);
  });
  test('denied permission returns switch to OFF', () async {
    permission = () async => false;
    expect(await controller.setEnabled(true), false);
    expect(stored, false);
    expect(controller.enabled.value, false);
  });
  test('network errors retain the saved intent', () async {
    sync = (_) async => throw StateError('offline');
    await controller.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(stored, true);
    expect(controller.enabled.value, true);
    expect(errors, hasLength(1));
  });
  test(
    'loading preferences during permission request does not revert the tap',
    () async {
      final gate = Completer<bool>();
      permission = () => gate.future;
      final first = controller.setEnabled(true);
      await controller.load();
      expect(controller.enabled.value, true);
      gate.complete(true);
      await first;
    },
  );
  test('local write failure restores the last persisted value', () async {
    final c = NotificationPreferenceController(
      read: () async => false,
      save: (_) async => throw StateError('disk'),
      requestPermission: () async => true,
      sync: (_) async => fail('Must not sync failed local write'),
      onSyncError: (_, _) {},
    );
    await expectLater(c.setEnabled(true), throwsStateError);
    expect(c.enabled.value, false);
    c.enabled.dispose();
  });
  testWidgets('switch and whole row respond while remote delivery is blocked', (
    tester,
  ) async {
    final gate = Completer<void>();
    sync = (_) => gate.future;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: controller.enabled,
            builder: (_, value, _) => SwitchListTile(
              title: const Text('추첨 결과 알림'),
              value: value,
              onChanged: controller.setEnabled,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, true);
    await tester.tap(find.text('추첨 결과 알림'));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, false);
    expect(stored, false);
    gate.complete();
    await tester.pumpAndSettle();
  });
}
