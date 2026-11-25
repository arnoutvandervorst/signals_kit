import 'package:signals_flutter/signals_flutter.dart';

/// Writes after an `await` in a screen state (the `finally` that clears a
/// busy flag, a result that lands late): the screen may have closed and
/// disposed the state meanwhile, and signals_core 7 throws
/// `SignalsWriteAfterDisposeError` on such a write.
extension SetIfAlive<T> on Signal<T> {
  /// Sets [value] unless this signal was disposed; then the value is dropped.
  void setIfAlive(T value) {
    if (!disposed) this.value = value;
  }
}
