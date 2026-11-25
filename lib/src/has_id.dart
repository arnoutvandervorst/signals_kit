/// Something a list can tell apart by its id: a document model. `PageState`
/// merges pages on it.
abstract interface class HasId {
  String get id;
}
