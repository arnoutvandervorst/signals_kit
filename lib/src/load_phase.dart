import 'package:signals_flutter/signals_flutter.dart';

/// Where a single-document stream stands. Four different answers that must
/// never render the same way:
///
/// - [loading]: don't know yet — skeleton, say nothing.
/// - [error]:   the stream failed — error column, not "Unknown".
/// - [missing]: loaded, and the doc does not exist — "gone" empty state.
/// - [ready]:   real data.
//* Before this every model state painted its null fallbacks ("Expired",
//* "Unknown", '') for all three non-ready phases, so a slow network, a
//* permission error and a deleted document looked identical on screen.
enum LoadPhase { loading, error, missing, ready }

/// Classifies an `AsyncState` of a nullable document.
LoadPhase loadPhaseOf<T>(AsyncState<T?> state) => switch (state) {
  AsyncLoading<T?>() => LoadPhase.loading,
  AsyncError<T?>() => LoadPhase.error,
  AsyncData<T?>(:final value) => value == null ? LoadPhase.missing : LoadPhase.ready,
};

extension LoadPhaseX on LoadPhase {
  bool get isLoading => this == LoadPhase.loading;
  bool get hasError => this == LoadPhase.error;
  bool get isMissing => this == LoadPhase.missing;
  bool get isReady => this == LoadPhase.ready;
}
