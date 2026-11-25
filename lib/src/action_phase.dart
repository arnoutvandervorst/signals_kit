import 'dart:async';

import 'package:signals_kit/src/kit_log.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// Where a user action stands, the action twin of `LoadPhase`:
///
/// - [idle]:    nothing running — the button works.
/// - [sending]: the write or call is on its way — busy, not tappable.
/// - [waiting]: saved; a backend trigger still has to answer (a task flips,
///   an order settles) — not tappable, optionally "being processed".
//* Without it the button came back between the write and the trigger, and a
//* second tap wrote again.
enum ActionPhase { idle, sending, waiting }

extension ActionPhaseX on ActionPhase {
  bool get isIdle => this == ActionPhase.idle;
  bool get isSending => this == ActionPhase.sending;
  bool get isWaiting => this == ActionPhase.waiting;

  /// Sending or waiting: the action can't be started again.
  bool get isBusy => this != ActionPhase.idle;
}

/// The [ActionPhase] of every running action of one state class, per key
/// (usually the task or doc id). The state class owns and disposes it.
///
/// `run(key, write:, confirmed:)` writes once per key: a second run while
/// the key is busy does nothing. After the write it waits until `confirmed()`
/// (read from the state's own signals: the listener shows the task done)
/// turns true, or until [timeout] — then the screen just shows what the
/// backend says. A failed write (throws, or returns `false`) goes straight
/// back to idle.
class PendingActions<K> {
  final Duration timeout;
  final String name;
  final _phases = signal<Map<K, ActionPhase>>(const {});
  final _watches = <K, ({EffectCleanup stop, Timer timer})>{};
  bool _disposed = false;

  PendingActions({this.timeout = const Duration(seconds: 30), this.name = 'PendingActions'});

  /// Every busy key (idle keys are absent).
  ReadonlySignal<Map<K, ActionPhase>> get phases => _phases;

  ActionPhase phaseOf(K key) => _phases.value[key] ?? ActionPhase.idle;

  /// True when the write went through (the backend may still be answering).
  Future<bool> run(K key, {required Future<Object?> Function() write, bool Function()? confirmed}) async {
    if (_disposed || phaseOf(key).isBusy) return false;
    _set(key, ActionPhase.sending);
    try {
      final result = await write();
      if (result == false) {
        _release(key);
        return false;
      }
    } catch (error, stack) {
      SignalsKitLog.exception('$name: action failed', error, stack);
      _release(key);
      return false;
    }
    if (_disposed) return true;
    if (confirmed == null || untracked(confirmed)) {
      _release(key);
      return true;
    }
    _set(key, ActionPhase.waiting);
    final stop = effect(() {
      //* Released after this run: an effect can't dispose itself mid-run.
      if (confirmed()) scheduleMicrotask(() => _release(key));
    });
    _watches[key] = (stop: stop, timer: Timer(timeout, () => _release(key)));
    return true;
  }

  void _set(K key, ActionPhase phase) => _phases.value = {..._phases.value, key: phase};

  void _release(K key) {
    if (_disposed) return;
    final watch = _watches.remove(key);
    watch?.stop();
    watch?.timer.cancel();
    if (_phases.value.containsKey(key)) _phases.value = {..._phases.value}..remove(key);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final watch in _watches.values) {
      watch.stop();
      watch.timer.cancel();
    }
    _watches.clear();
    _phases.dispose();
  }
}
