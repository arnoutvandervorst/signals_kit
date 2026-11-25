# signals_kit

State building blocks for a signals + Firestore app, shared by the apps and
the sibling app so a fix lands once.

- `LoadPhase` (`lib/src/load_phase.dart`): loading / error / missing / ready for a document-backed state.
- `ActionPhase`, `PendingActions<K>` (`action_phase.dart`): an action that waits for the backend, once per key.
- `StreamRecovery` (`stream_recovery.dart`): a Firestore stream that comes back after an error.
- `PageState<T extends HasId>` (`page_state.dart`): a paged list with a live first page.
- `guardedFutureSignal`, `disposeFutureSignal`, `Signal.setIfAlive`: no write into a disposed signal.
- Snapshot helpers (`firestore_snapshots.dart`): `mapToList`, `mapToStream`, `mapToElement`.
- `SignalsKitLog`: where the kit reports errors. Point both hooks at the app's log before `runApp`.

## Use

```yaml
dependencies:
  signals_kit:
    git:
      url: https://github.com/<owner>/signals_kit.git
      ref: v0.1.0
```

A fix here reaches an app when that app raises `ref`.

## Check

```bash
flutter pub get
flutter analyze
flutter test
```
