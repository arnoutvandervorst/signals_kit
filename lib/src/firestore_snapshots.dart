import 'package:cloud_firestore/cloud_firestore.dart';

extension StreamDocumentSnapshotExtension<T> on Stream<DocumentSnapshot<T>> {
  Stream<T> get mapToStream =>
      map((doc) => doc.exists ? doc.data()! : throw Exception('Document ${doc.id} does not exist'));
}

extension DocumentSnapshotListExtension<T> on List<DocumentSnapshot<T>> {
  List<T> get mapToList =>
      map((doc) => doc.exists ? doc.data()! : throw Exception('Document ${doc.id} does not exist')).toList();
}

extension DocumentSnapshotExtension<T> on DocumentSnapshot<T> {
  T get mapToElement => exists ? data()! : throw Exception('Document $id does not exist');
}
