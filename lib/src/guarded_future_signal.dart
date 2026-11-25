import 'dart:async';

import 'package:signals_flutter/signals_flutter.dart';

/// [futureSignal] that drops a load landing after dispose. signals_core 7.0.0
/// keeps the pending future through `dispose()`, so a page closed while it
/// loads writes the late value into a disposed signal
/// (SignalsWriteAfterDisposeError, rodydavis/signals.dart#507). Every load passes a gate that stays open
/// until the signal is disposed; after that the result (or error) is dropped
/// and the gate never completes.
///
/// [fn] runs synchronously inside the signal's own call, so reading signals
/// before its first `await` still tracks them, as with [futureSignal].
FutureSignal<T> guardedFutureSignal<T>(Future<T> Function() fn, {AsyncSignalOptions<T>? options}) =>
    GuardedFutureSignal._(_LoadGate(), fn, options);

/// The [FutureSignal] behind [guardedFutureSignal]: closes its gate on dispose.
class GuardedFutureSignal<T> extends FutureSignal<T> {
  final _LoadGate _gate;

  GuardedFutureSignal._(this._gate, Future<T> Function() fn, AsyncSignalOptions<T>? options)
    : super(() => _gate.pass(fn()), options: options);

  @override
  void dispose() {
    _gate.close();
    super.dispose();
  }
}

/// Lets loads through until [close]; after that they never complete.
class _LoadGate {
  var _closed = false;

  void close() => _closed = true;

  Future<T> pass<T>(Future<T> load) {
    final gate = Completer<T>();
    load.then(
      (result) {
        if (!_closed) gate.complete(result);
      },
      onError: (Object error, StackTrace stack) {
        if (!_closed) gate.completeError(error, stack);
      },
    );
    return gate.future;
  }
}
