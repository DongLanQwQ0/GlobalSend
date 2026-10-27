import 'dart:async';

class TransferStopped implements Exception {
  const TransferStopped();
  @override
  String toString() => '传输已停止';
}

/// One file owns its requests and sockets, never the center's shared session.
class TransferOperation {
  static final Object _key = Object();
  static TransferOperation? get current =>
      Zone.current[_key] as TransferOperation?;
  final stopped = Completer<void>();
  final finished = Completer<void>();
  final List<FutureOr<void> Function()> _stops = [];
  final List<void Function()> _dispose = [];
  final Map<Object, Object> _resources = {};
  Future<void>? _canceling;
  bool get isStopped => stopped.isCompleted;
  void check() {
    if (isStopped) throw const TransferStopped();
  }

  void onCancel(FutureOr<void> Function() stop) {
    if (isStopped) {
      unawaited(Future<void>.sync(stop).catchError((Object _) {}));
    } else {
      _stops.add(stop);
    }
  }

  T resource<T extends Object>(
    Object key,
    T Function() create,
    void Function(T) close,
  ) {
    return _resources.putIfAbsent(key, () {
      final value = create();
      var closed = false;
      void finish() {
        if (!closed) {
          closed = true;
          close(value);
        }
      }

      onCancel(finish);
      _dispose.add(finish);
      return value;
    }) as T;
  }

  Future<void> cancel() {
    if (!stopped.isCompleted) stopped.complete();
    return _canceling ??= Future.wait(
      _stops.map((stop) => Future<void>.sync(stop).catchError((Object _) {})),
    ).then((_) {});
  }

  Future<T> wait<T>(Future<T> work) async {
    check();
    final value = await Future.any<T>([
      work,
      stopped.future.then<T>((_) => throw const TransferStopped()),
    ]);
    check();
    return value;
  }

  Future<T> run<T>(Future<T> Function() work) =>
      runZoned(() => Future<T>.sync(work), zoneValues: {_key: this});
  Future<void> dispose() async {
    await _canceling;
    for (final close in _dispose) close();
  }
}
