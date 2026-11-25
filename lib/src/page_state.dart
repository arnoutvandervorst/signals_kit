import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:signals_kit/src/firestore_snapshots.dart';
import 'package:signals_kit/src/has_id.dart';
import 'package:signals_kit/src/stream_recovery.dart';

const kPageSize = 20;

/// How much of the loaded window stays realtime.
enum PageLiveness {
  /// The whole loaded window is one snapshot listener: edits and deletions
  /// anywhere in it render live. Growing the window re-reads the loaded docs
  /// (~P²/2 · kPageSize reads for P pages) — right for lists that are
  /// shallow-scrolled or where staleness anywhere is unacceptable
  /// (moderation queues, inbox).
  window,

  /// Only the newest page is live; older pages are fetched once and frozen.
  /// Loading P pages costs P · kPageSize reads, but a reaction or deletion
  /// in the frozen tail stays stale until the screen reopens — right for
  /// chat, where churn concentrates on the newest messages and users scroll
  /// deep.
  firstPageOnly,
}

/// Shared paginated query state: ONE snapshot listener over a growing window.
///
//* Redesigned from a first-page-listener + one-shot `get()` pages model. That
//* split meant only the newest 20 docs were live, deletions were ignored
//* entirely ("reconciles on the next full fetch" — which nothing triggered),
//* edits beyond the window never rendered, and realtime inserts landed at a
//* first-page index clamped into the accumulated list. Several screens grew
//* hand-rolled removal callbacks to paper over the deletion gap.
//*
//* Now `fetchMore` simply grows the listener's `limit`; every emission
//* replaces `items` wholesale, so inserts, edits and deletions anywhere in
//* the loaded window are correct by construction — including latency-
//* compensated local writes, which the SDK reflects in the very next
//* emission. The cost is that growing the window re-reads the already-loaded
//* docs (server or local cache); at kPageSize granularity that is the price
//* of every loaded row being live.
class PageState<T extends HasId> {
  final Query<T>? query;
  final PageLiveness liveness;
  final StreamRecoveryController _streamRecovery = StreamRecoveryController(name: 'PageState');
  bool _isDisposed = false;

  late final Stream<List<T>> Function(int limit) _pages;
  late final Future<List<T>> Function(int pageIndex)? _tailPages;
  late final Signal<int> _limit;
  late final StreamSignal<List<T>?> _windowStream;
  EffectCleanup? _windowStreamEffect;

  //* firstPageOnly internals: the frozen tail and its cursor. The head list
  //* is whatever the live window last emitted; [items] is head + tail with
  //* head winning on id collisions (a doc sliding from tail into the live
  //* window must not render twice).
  List<T> _head = const [];
  final List<T> _tail = [];
  DocumentSnapshot<T>? _tailCursor;
  int _tailPageIndex = 0;

  //* Public signals. `items` stays externally writable: consumers may drop or
  //* replace an item synchronously for instant UI (swipe-archive, delete);
  //* the next emission confirms — and since their write also went to
  //* Firestore, it agrees.
  final hasMore = Signal<bool>(false);
  final isFetching = Signal<bool>(false);
  final items = Signal<List<T>>([]);

  //* `pages` / `tailPages` are the test seams: a window factory returning the
  //* loaded docs for a given limit, and (firstPageOnly) a one-shot fetch for
  //* tail page N. Production callers pass only `query` (+ `liveness`).
  PageState({
    this.query,
    this.liveness = PageLiveness.window,
    Stream<List<T>> Function(int limit)? pages,
    Future<List<T>> Function(int pageIndex)? tailPages,
  }) : assert(query != null || pages != null, 'PageState needs a query or a pages factory') {
    _pages = pages ?? ((limit) => query!.limit(limit).snapshots().map((snapshot) => snapshot.docs.mapToList));
    _tailPages = tailPages;
    _limit = Signal<int>(kPageSize, options: SignalOptions(name: 'PageState.limit'));

    isFetching.value = true;
    //* The factory reads `_limit`, so bumping it re-subscribes the recovery
    //* stream with the larger window — same rebinding pattern as
    //* CurrentUserState keying its stream off the session signal. In
    //* firstPageOnly mode the limit never grows, so the subscription is
    //* attached exactly once.
    _windowStream = _streamRecovery.watch<List<T>>(() => _pages(_limit.value), streamName: 'PageState.window');
    _windowStreamEffect = _windowStream.subscribe(_handleWindowState);
  }

  void _handleWindowState(Object state) {
    _streamRecovery.observe(state);

    if (_isDisposed) {
      return;
    }

    //* Don't leave the spinner stuck when an emission is an error;
    //* StreamRecoveryController handles the retry.
    if (state is AsyncError) {
      isFetching.value = false;
      return;
    }

    if (state is! AsyncData<List<T>?>) {
      return;
    }

    final docs = state.value;
    if (docs == null) {
      return;
    }

    _bridgeSlideOuts(docs);
    _head = List<T>.of(docs);
    _recompose();
    //* A full window means there may be more; a short one means the query is
    //* exhausted at this limit. With a frozen tail, exhaustion is owned by
    //* the tail fetches instead once any have run.
    if (_tail.isEmpty) {
      hasMore.value = docs.length >= _limit.value;
    }
    isFetching.value = false;
  }

  //* Boundary gap repair for firstPageOnly: when K new docs arrive at the top
  //* of the live window, the K docs at its bottom slide out — into the void
  //* between head and the already-fetched tail, which would render as a hole
  //* mid-list. Bridge exactly those trailing slide-outs into the tail front.
  //* Deletions bridge nothing: a deleted doc refills the window from below
  //* (no new ids at the top), so arrivals == 0 and it vanishes correctly.
  void _bridgeSlideOuts(List<T> newHead) {
    if (liveness != PageLiveness.firstPageOnly || _tail.isEmpty || _head.isEmpty) {
      return;
    }

    final oldIds = {for (final item in _head) item.id};
    var arrivals = 0;
    for (final item in newHead) {
      if (oldIds.contains(item.id)) break;
      arrivals++;
    }
    if (arrivals == 0) return;

    final newIds = {for (final item in newHead) item.id};
    final tailIds = {for (final item in _tail) item.id};
    final slidOut = _head.reversed
        .where((item) => !newIds.contains(item.id) && !tailIds.contains(item.id))
        .take(arrivals)
        .toList()
        .reversed
        .toList();
    _tail.insertAll(0, slidOut);
  }

  void _recompose() {
    if (_tail.isEmpty) {
      items.value = _head;
      return;
    }
    final headIds = {for (final item in _head) item.id};
    items.value = [
      ..._head,
      for (final item in _tail)
        if (!headIds.contains(item.id)) item,
    ];
  }

  /// Loads one more page: by growing the live window, or (firstPageOnly) by
  /// fetching a frozen tail page once.
  Future<void> fetchMore() async {
    if (_isDisposed || isFetching.value || !hasMore.value) {
      return;
    }

    if (liveness == PageLiveness.window) {
      isFetching.value = true;
      _limit.value = _limit.value + kPageSize;
      return;
    }

    isFetching.value = true;
    try {
      final List<T> page;
      if (_tailPages != null) {
        page = await _tailPages(_tailPageIndex);
      } else {
        //* Cursor: after the last tail doc, or after the last LIVE doc for the
        //* first tail fetch. The live head can shift under the cursor when new
        //* docs arrive, but only towards older docs already covered by the
        //* head — the id dedup in _recompose absorbs the overlap.
        final cursor = _tailCursor ?? await _headCursor();
        if (cursor == null) {
          hasMore.value = false;
          return;
        }
        final snapshot = await query!.startAfterDocument(cursor).limit(kPageSize).get();
        page = snapshot.docs.mapToList;
        if (snapshot.docs.isNotEmpty) {
          _tailCursor = snapshot.docs.last;
        }
      }

      if (_isDisposed) return;

      _tailPageIndex++;
      _tail.addAll(page);
      _recompose();
      hasMore.value = page.length >= kPageSize;
    } finally {
      if (!_isDisposed) {
        isFetching.value = false;
      }
    }
  }

  //* One extra read: re-fetch the head's last doc as a DocumentSnapshot so the
  //* tail query can start after it (the mapped stream carries models, not
  //* snapshots).
  Future<DocumentSnapshot<T>?> _headCursor() async {
    if (_head.isEmpty) return null;
    final snapshot = await query!.limit(_head.length).get();
    return snapshot.docs.isEmpty ? null : snapshot.docs.last;
  }

  /// Disposes the pagination signals and the realtime subscription.
  void dispose() {
    _isDisposed = true;
    _windowStreamEffect?.call();
    _streamRecovery.dispose();
    _windowStream.dispose();
    _limit.dispose();
    hasMore.dispose();
    isFetching.dispose();
    items.dispose();
  }
}
