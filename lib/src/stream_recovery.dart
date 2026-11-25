import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:signals_kit/src/kit_log.dart';

/// Shared recovery controller for long-lived Firestore-backed streams.
class StreamRecoveryController {
  final String name;
  final Duration heartbeatInterval;
  final int maxBackoffExponent;

  final TimerSignal _heartbeat;
  late final Signal<int> _revision;

  Timer? _retryTimer;
  bool _disposed = false;
  int _retryAttempt = 0;

  StreamRecoveryController({
    required this.name,
    this.heartbeatInterval = const Duration(minutes: 5),
    this.maxBackoffExponent = 4,
  }) : _heartbeat = TimerSignal(every: heartbeatInterval) {
    _revision = trackedSignal<int>(0, options: TrackedSignalOptions(name: '$name.revision'));
  }

  StreamSignal<T> watch<T>(Stream<T> Function() builder, {String? streamName}) {
    return streamSignal<T>(() {
      _revision.value;
      _heartbeat.value;
      return builder();
    }, options: AsyncSignalOptions(name: streamName ?? name));
  }

  void observe(Object state) {
    switch (state) {
      case AsyncData():
        _markHealthy();
        break;
      case AsyncError(:final error, :final stackTrace):
        SignalsKitLog.error('$name stream error: $error');
        SignalsKitLog.exception('$name stream error', error, stackTrace);
        if (_shouldRetry(error)) {
          _scheduleRecovery();
        } else {
          _markHealthy();
        }
        break;
      default:
        break;
    }
  }

  void refresh() {
    if (_disposed) {
      return;
    }

    _cancelRetryTimer();
    _retryAttempt = 0;
    _bumpRevision();
  }

  void dispose() {
    _disposed = true;
    _cancelRetryTimer();
    _heartbeat.dispose();
    _revision.dispose();
  }

  void _scheduleRecovery({bool immediate = false}) {
    if (_disposed) {
      return;
    }

    if (_retryTimer?.isActive == true && !immediate) {
      return;
    }

    _cancelRetryTimer();

    if (immediate) {
      _retryAttempt = 0;
      _bumpRevision();
      return;
    }

    final delay = Duration(seconds: 1 << (_retryAttempt.clamp(0, maxBackoffExponent) + 1));
    _retryTimer = Timer(delay, () {
      _retryTimer = null;

      if (_disposed) {
        return;
      }

      _bumpRevision();
      if (_retryAttempt < maxBackoffExponent) {
        _retryAttempt++;
      }
    });
  }

  void _markHealthy() {
    _retryAttempt = 0;
    _cancelRetryTimer();
  }

  void _bumpRevision() {
    _revision.value++;
  }

  void _cancelRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  bool _shouldRetry(Object error) {
    if (error is FirebaseException) {
      return switch (error.code) {
        'aborted' ||
        'cancelled' ||
        'deadline-exceeded' ||
        'internal' ||
        'resource-exhausted' ||
        'unavailable' ||
        'unknown' => true,
        'failed-precondition' || 'permission-denied' || 'not-found' || 'already-exists' => false,
        _ => false,
      };
    }

    if (error is TimeoutException) {
      return true;
    }

    return false;
  }
}
