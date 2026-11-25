import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:signals_kit/signals_kit.dart';
import 'package:signals_flutter/signals_flutter.dart';

void main() {
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('sending while the write runs, waiting until the backend confirms, then idle', () async {
    final actions = PendingActions<String>();
    addTearDown(actions.dispose);
    final done = signal(false);
    final write = Completer<void>();

    final run = actions.run('t1', write: () => write.future, confirmed: () => done.value);
    expect(actions.phaseOf('t1'), ActionPhase.sending);
    write.complete();
    expect(await run, isTrue);
    expect(actions.phaseOf('t1'), ActionPhase.waiting);
    expect(actions.phaseOf('t2'), ActionPhase.idle, reason: 'per key');

    done.value = true;
    await settle();
    expect(actions.phaseOf('t1'), ActionPhase.idle);
  });

  test('a second run on a busy key does nothing', () async {
    final actions = PendingActions<String>();
    addTearDown(actions.dispose);
    var writes = 0;
    final first = actions.run('t1', write: () async => writes++, confirmed: () => false);
    expect(await actions.run('t1', write: () async => writes++), isFalse);
    await first;
    expect(await actions.run('t1', write: () async => writes++), isFalse, reason: 'still waiting');
    expect(writes, 1);
  });

  test('a failed write (throws or returns false) goes back to idle', () async {
    final actions = PendingActions<String>();
    addTearDown(actions.dispose);
    expect(await actions.run('t1', write: () async => throw StateError('offline'), confirmed: () => false), isFalse);
    expect(actions.phaseOf('t1'), ActionPhase.idle);
    expect(await actions.run('t1', write: () async => false, confirmed: () => false), isFalse);
    expect(actions.phaseOf('t1'), ActionPhase.idle);
  });

  test('already confirmed, or nothing to confirm: straight back to idle', () async {
    final actions = PendingActions<String>();
    addTearDown(actions.dispose);
    expect(await actions.run('t1', write: () async => null, confirmed: () => true), isTrue);
    expect(actions.phaseOf('t1'), ActionPhase.idle);
    expect(await actions.run('t2', write: () async => null), isTrue);
    expect(actions.phaseOf('t2'), ActionPhase.idle);
  });

  test('the backend never confirms: let go after the timeout', () async {
    final actions = PendingActions<String>(timeout: const Duration(milliseconds: 20));
    addTearDown(actions.dispose);
    await actions.run('t1', write: () async => null, confirmed: () => false);
    expect(actions.phaseOf('t1'), ActionPhase.waiting);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(actions.phaseOf('t1'), ActionPhase.idle);
  });

  test('dispose stops the watches; a late write leaves no state behind', () async {
    final actions = PendingActions<String>();
    final write = Completer<void>();
    final run = actions.run('t1', write: () => write.future, confirmed: () => false);
    actions.dispose();
    write.complete();
    expect(await run, isTrue);
  });
}
