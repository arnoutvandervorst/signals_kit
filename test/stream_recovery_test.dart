import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:signals_kit/signals_kit.dart';

/// The recovery controller behind every long-lived Firestore stream.
///
//* The observable is the builder call count: `watch` re-runs its builder
//* whenever the revision bumps or the heartbeat ticks, so "the retry fired"
//* is "the stream was rebuilt". Time is fully synthetic via fake_async, which
//* is what makes exponential delays and cancellation assertable at all.
//* `FirebaseException` here is plain construction — no app, no channel; the
//* logging path checks `Firebase.apps` which is an empty static list in tests.
void main() {
  FirebaseException retryable() => FirebaseException(plugin: 'test', code: 'unavailable');
  FirebaseException fatal() => FirebaseException(plugin: 'test', code: 'permission-denied');
  AsyncError<int> errorState(Object error) => AsyncError<int>(error, StackTrace.current);

  ({StreamRecoveryController controller, int Function() builds, void Function() cleanup}) harness({
    Duration heartbeatInterval = const Duration(hours: 1),
    int maxBackoffExponent = 4,
  }) {
    final controller = StreamRecoveryController(
      name: 'test',
      heartbeatInterval: heartbeatInterval,
      maxBackoffExponent: maxBackoffExponent,
    );

    var builds = 0;
    final stream = controller.watch<int>(() {
      builds++;
      return const Stream<int>.empty();
    });
    //* An active subscriber makes revision bumps re-run the builder
    //* synchronously — exactly how GroupAuthState wires `subscribe(observe)`.
    final unsubscribe = stream.subscribe((_) {});

    return (
      controller: controller,
      builds: () => builds,
      cleanup: () {
        unsubscribe();
        controller.dispose();
        stream.dispose();
      },
    );
  }

  group('exponential backoff', () {
    test('the first retryable error rebuilds after 2 seconds, not before', () {
      fakeAsync((async) {
        final h = harness();
        expect(h.builds(), 1, reason: 'initial subscription');

        h.controller.observe(errorState(retryable()));

        async.elapse(const Duration(milliseconds: 1999));
        expect(h.builds(), 1, reason: 'still inside the backoff window');

        async.elapse(const Duration(milliseconds: 1));
        expect(h.builds(), 2, reason: 'retry fired at 1 << (0 + 1) seconds');

        h.cleanup();
      });
    });

    test('repeated failures double the delay: 2s, 4s, 8s', () {
      fakeAsync((async) {
        final h = harness();

        for (final expectedSeconds in [2, 4, 8]) {
          final before = h.builds();
          h.controller.observe(errorState(retryable()));

          async.elapse(Duration(seconds: expectedSeconds) - const Duration(milliseconds: 1));
          expect(h.builds(), before, reason: 'no early fire for the ${expectedSeconds}s attempt');

          async.elapse(const Duration(milliseconds: 1));
          expect(h.builds(), before + 1, reason: 'fired at ${expectedSeconds}s');
        }

        h.cleanup();
      });
    });

    test('maxBackoffExponent caps the delay — it stops doubling', () {
      fakeAsync((async) {
        final h = harness(maxBackoffExponent: 2);

        //* Exponent 2 caps the delay at 1 << (2 + 1) = 8s; the attempt counter
        //* also stops climbing, so every later failure stays at 8s.
        for (final expectedSeconds in [2, 4, 8, 8, 8]) {
          final before = h.builds();
          h.controller.observe(errorState(retryable()));
          async.elapse(Duration(seconds: expectedSeconds) - const Duration(milliseconds: 1));
          expect(h.builds(), before, reason: 'capped delay must still be ${expectedSeconds}s');
          async.elapse(const Duration(milliseconds: 1));
          expect(h.builds(), before + 1);
        }

        h.cleanup();
      });
    });

    test('an error while a retry is already pending does not reschedule it', () {
      fakeAsync((async) {
        final h = harness();

        h.controller.observe(errorState(retryable()));
        async.elapse(const Duration(seconds: 1));
        //* A second failure mid-window must not push the deadline out.
        h.controller.observe(errorState(retryable()));

        async.elapse(const Duration(seconds: 1));
        expect(h.builds(), 2, reason: 'fired on the ORIGINAL 2s schedule');

        h.cleanup();
      });
    });

    test('healthy data resets the backoff to the first rung', () {
      fakeAsync((async) {
        final h = harness();

        //* Climb to attempt 1 (next delay would be 4s)...
        h.controller.observe(errorState(retryable()));
        async.elapse(const Duration(seconds: 2));
        expect(h.builds(), 2);

        //* ...then recover, then fail again: back to 2s, not 4s.
        h.controller.observe(const AsyncData<int>(1));
        h.controller.observe(errorState(retryable()));
        async.elapse(const Duration(seconds: 2));
        expect(h.builds(), 3, reason: 'reset backoff fires at 2s again');

        h.cleanup();
      });
    });
  });

  group('error classification', () {
    test('a non-retryable Firebase error schedules nothing', () {
      fakeAsync((async) {
        final h = harness();

        h.controller.observe(errorState(fatal()));

        async.elapse(const Duration(minutes: 30));
        expect(h.builds(), 1, reason: 'permission-denied is not a transport blip');

        h.cleanup();
      });
    });

    test('an unclassified non-Firebase error schedules nothing', () {
      fakeAsync((async) {
        final h = harness();

        h.controller.observe(errorState(StateError('boom')));

        async.elapse(const Duration(minutes: 30));
        expect(h.builds(), 1);

        h.cleanup();
      });
    });

    test('a TimeoutException IS retryable', () {
      fakeAsync((async) {
        final h = harness();

        h.controller.observe(errorState(TimeoutException('slow')));

        async.elapse(const Duration(seconds: 2));
        expect(h.builds(), 2);

        h.cleanup();
      });
    });

    test('non-async states are ignored', () {
      fakeAsync((async) {
        final h = harness();

        h.controller.observe('not an async state');
        h.controller.observe(const AsyncLoading<int>());

        async.elapse(const Duration(minutes: 30));
        expect(h.builds(), 1);

        h.cleanup();
      });
    });
  });

  group('heartbeat', () {
    test('each heartbeat tick re-runs the builder', () {
      fakeAsync((async) {
        final h = harness(heartbeatInterval: const Duration(minutes: 5));
        expect(h.builds(), 1);

        async.elapse(const Duration(minutes: 5));
        expect(h.builds(), 2);

        async.elapse(const Duration(minutes: 5));
        expect(h.builds(), 3);

        h.cleanup();
      });
    });
  });

  group('refresh', () {
    test('rebuilds immediately and cancels a pending retry', () {
      fakeAsync((async) {
        final h = harness();

        h.controller.observe(errorState(retryable()));
        expect(async.nonPeriodicTimerCount, 1, reason: 'a retry is pending');

        h.controller.refresh();

        expect(h.builds(), 2, reason: 'refresh bumps synchronously');
        expect(async.nonPeriodicTimerCount, 0, reason: 'the pending retry was cancelled');

        //* And the cancelled retry never double-fires.
        async.elapse(const Duration(minutes: 1));
        expect(h.builds(), 2);

        h.cleanup();
      });
    });

    test('also resets the backoff ladder', () {
      fakeAsync((async) {
        final h = harness();

        //* Climb to attempt 1, then refresh, then fail: 2s again, not 4s.
        h.controller.observe(errorState(retryable()));
        async.elapse(const Duration(seconds: 2));
        h.controller.refresh();
        final before = h.builds();

        h.controller.observe(errorState(retryable()));
        async.elapse(const Duration(seconds: 2));
        expect(h.builds(), before + 1);

        h.cleanup();
      });
    });
  });

  group('dispose', () {
    test('cancels the pending retry timer and the heartbeat', () {
      fakeAsync((async) {
        final controller = StreamRecoveryController(name: 'test', heartbeatInterval: const Duration(minutes: 5));
        var builds = 0;
        final stream = controller.watch<int>(() {
          builds++;
          return const Stream<int>.empty();
        });
        final unsubscribe = stream.subscribe((_) {});

        controller.observe(errorState(retryable()));
        expect(async.nonPeriodicTimerCount, 1);
        expect(async.periodicTimerCount, 1, reason: 'the heartbeat is running');

        unsubscribe();
        controller.dispose();
        stream.dispose();

        expect(async.nonPeriodicTimerCount, 0, reason: 'retry timer cancelled on dispose');
        expect(async.periodicTimerCount, 0, reason: 'heartbeat cancelled on dispose');

        //* Nothing left to fire into the disposed controller.
        async.elapse(const Duration(hours: 2));
        expect(builds, 1);
      });
    });

    test('refresh after dispose is a no-op', () {
      fakeAsync((async) {
        final h = harness();
        final before = h.builds();
        h.cleanup();

        h.controller.refresh();

        expect(h.builds(), before);
      });
    });

    test('a late error after dispose schedules nothing', () {
      fakeAsync((async) {
        final h = harness();
        h.cleanup();

        h.controller.observe(errorState(retryable()));

        expect(async.nonPeriodicTimerCount, 0);
      });
    });
  });
}
