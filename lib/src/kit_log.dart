import 'package:flutter/foundation.dart';

/// Where the kit reports what went wrong (a stream that errored, an action
/// that failed). An app points both at its own log once, before `runApp`;
/// until then they print.
abstract final class SignalsKitLog {
  static void Function(String message) error = _printError;

  static Future<void> Function(String message, Object error, StackTrace? stackTrace) exception = _printException;

  static void _printError(String message) => debugPrint(message);

  static Future<void> _printException(String message, Object error, StackTrace? stackTrace) async =>
      debugPrint('$message: $error');
}
