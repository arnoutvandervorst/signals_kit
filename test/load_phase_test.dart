import 'package:flutter_test/flutter_test.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:signals_kit/signals_kit.dart';

void main() {
  test('loading, error, missing and ready are four distinct answers', () {
    expect(loadPhaseOf<String>(const AsyncLoading<String?>()), LoadPhase.loading);
    expect(loadPhaseOf<String>(AsyncError<String?>(StateError('x'), StackTrace.empty)), LoadPhase.error);
    expect(loadPhaseOf<String>(const AsyncData<String?>(null)), LoadPhase.missing);
    expect(loadPhaseOf<String>(const AsyncData<String?>('doc')), LoadPhase.ready);
  });

  test('convenience getters agree with the phase', () {
    expect(LoadPhase.loading.isLoading, isTrue);
    expect(LoadPhase.error.hasError, isTrue);
    expect(LoadPhase.missing.isMissing, isTrue);
    expect(LoadPhase.ready.isReady, isTrue);
    expect(LoadPhase.ready.isLoading || LoadPhase.ready.hasError || LoadPhase.ready.isMissing, isFalse);
  });
}
