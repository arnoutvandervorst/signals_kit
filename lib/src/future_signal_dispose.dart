import 'package:signals_flutter/signals_flutter.dart';

/// Disposes [signal], after the load it is running has settled.
///
/// signals_core 7 still writes a FutureSignal's result after dispose, which
/// throws an uncaught SignalsWriteAfterDisposeError. A section that is
/// removed while it loads would hit it.
void disposeFutureSignal<T>(FutureSignal<T> signal) {
  if (!signal.peek().isLoading) return signal.dispose();
  signal.future.then<void>((_) {}, onError: (Object _) {}).whenComplete(signal.dispose);
}
