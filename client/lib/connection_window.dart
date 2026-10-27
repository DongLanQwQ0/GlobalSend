import 'dart:async';

/// One connection-decision deadline, shared by all routes of a file. Once a
/// route has really connected its data stream is no longer timed by this gate.
class RouteDeadline {
  RouteDeadline({this.limit = const Duration(seconds: 1)}) {
    watch.start();
  }
  final Duration limit;
  final Stopwatch watch = Stopwatch();
  Duration get remaining => limit - watch.elapsed;
  bool get expired => remaining <= Duration.zero;
  ConnectionWindow next(int choicesLeft) => ConnectionWindow(
    Duration(microseconds: remaining.inMicroseconds ~/ choicesLeft),
  );

  Duration scopeBudget({
    required bool last,
    bool verified = false,
    bool nextVerified = false,
  }) {
    if (last) return remaining;
    final fraction = !verified && nextVerified ? .35 : .6;
    return Duration(
      microseconds: (remaining.inMicroseconds * fraction).floor(),
    );
  }
}

class ConnectionWindow {
  ConnectionWindow(this.limit);
  final Duration limit;
  static final Object _zoneKey = Object();
  static ConnectionWindow? get current =>
      Zone.current[_zoneKey] as ConnectionWindow?;
  final Stopwatch _watch = Stopwatch();
  final _stops = <FutureOr<void> Function()>[];
  final _resources = <Object, Object>{};
  final _dispose = <FutureOr<void> Function()>[];
  final _timeout = Completer<Never>();
  Timer? _timer;
  Future<void>? _canceling;
  bool canceled = false, established = false;
  bool _timedOut = false;
  Duration get remaining => limit - _watch.elapsed;

  void check() {
    if (canceled || !established && remaining <= Duration.zero) {
      throw TimeoutException('连接探测预算已用完', limit);
    }
  }

  void connected() {
    check();
    established = true;
    _timer?.cancel();
  }

  void onCancel(FutureOr<void> Function() stop) {
    if (canceled) {
      unawaited(Future<void>.sync(stop));
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

  Future<void> cancel() => _canceling ??= () async {
    canceled = true;
    _timer?.cancel();
    await Future.wait(_stops.map((stop) => Future<void>.sync(stop)));
  }();

  Future<T> run<T>(Future<T> Function() work) async {
    _watch.start();
    final future = runZoned(
      () => Future<T>.sync(work),
      zoneValues: {_zoneKey: this},
    );
    _timer = Timer(limit > Duration.zero ? limit : Duration.zero, () {
      if (established) return;
      _timedOut = true;
      unawaited(cancel());
      if (!_timeout.isCompleted)
        _timeout.completeError(TimeoutException('连接探测预算已用完', limit));
    });
    try {
      return await Future.any([future, _timeout.future]);
    } catch (_) {
      await cancel();
      if (_timedOut) throw TimeoutException('连接探测预算已用完', limit);
      rethrow;
    } finally {
      _timer?.cancel();
      await Future.wait(_dispose.map((close) => Future<void>.sync(close)));
    }
  }
}

/// Teardown control messages are best-effort and never inherit the expired
/// attempt. Local socket/writer shutdown must precede this background work.
void cleanupConnection(Future<void> Function() cleanup) {
  unawaited(
    runZoned(() async {
      try {
        await ConnectionWindow(const Duration(milliseconds: 300)).run(cleanup);
      } catch (_) {
        /* A new attempt/relay also fences the old remote attempt ID. */
      }
    }, zoneValues: {ConnectionWindow._zoneKey: null}),
  );
}
