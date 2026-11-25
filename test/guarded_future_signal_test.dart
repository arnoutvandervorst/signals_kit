import 'dart:async';

import 'package:signals_kit/signals_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// A page closed while its data loads: the state is disposed, then the load
/// lands. signals_core 7.0.0 writes that late value into the disposed
/// FutureSignal (SignalsWriteAfterDisposeError); [guardedFutureSignal] drops
/// it.
void main() {
  test('a plain futureSignal writes a late load into the disposed signal', () async {
    final load = Completer<int>();
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final value = futureSignal(() => load.future);
      value.value;
      value.dispose();
      load.complete(1);
      await Future<void>.delayed(Duration.zero);
    }, (error, _) => errors.add(error));
    expect(errors.single, isA<SignalsWriteAfterDisposeError>());
  });

  test('a guarded one drops the late load and the late error', () async {
    final errors = <Object>[];
    //* Inside the zone: an error is only delivered within its own error zone.
    await runZonedGuarded(() async {
      final load = Completer<int>();
      final failing = Completer<int>();
      final value = guardedFutureSignal(() => load.future);
      final failed = guardedFutureSignal(() => failing.future);
      value.value;
      failed.value;
      value.dispose();
      failed.dispose();
      load.complete(1);
      failing.completeError(StateError('offline'));
      await Future<void>.delayed(Duration.zero);
    }, (error, _) => errors.add(error));
    expect(errors, isEmpty);
  });

  test('alive, it loads, fails, refreshes and follows its dependencies like futureSignal', () async {
    final id = signal(1);
    final value = guardedFutureSignal(() async => id.value * 10, options: AsyncSignalOptions<int>(dependencies: [id]));
    expect(await value.future, 10);
    id.value = 2;
    expect(await value.future, 20);
    await value.refresh();
    expect(value.value.value, 20);
    final failed = guardedFutureSignal<int>(() async => throw StateError('offline'));
    await expectLater(failed.future, throwsStateError);
    expect(failed.value.hasError, isTrue);
    value.dispose();
    failed.dispose();
    id.dispose();
  });
}
