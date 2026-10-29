import 'dart:async';

/// Read-only probes may run together; only the returned choice may open a file
/// grant/writer. Unknown (including legacy/background RTC) remains usable.
class TransferRouteChoice {
  TransferRouteChoice({
    required this.phase,
    required this.label,
    required this.run,
    this.latency,
    bool? ready,
    Future<bool?>? readiness,
  }) : ready = ready,
       pending = readiness != null {
    readiness?.then(
      (value) {
        this.ready = value;
        pending = false;
        _changed?.call();
      },
      onError: (Object _, StackTrace __) {
        // A failed signaling request is unknown, not proof of an unreachable IP.
        pending = false;
        _changed?.call();
      },
    );
  }

  final String phase, label;
  final Future<bool> Function() run;
  final int? Function()? latency;
  bool? ready;
  bool pending;
  bool attempted = false;
  void Function()? _changed;
}

class TransferRouteSelection {
  TransferRouteSelection(this.choices) {
    for (final choice in choices) {
      choice._changed = _changed;
    }
  }
  final List<TransferRouteChoice> choices;
  Completer<void> _wake = Completer<void>();

  void _changed() {
    if (!_wake.isCompleted) _wake.complete();
    _wake = Completer<void>();
  }

  bool readyIn(String phase) => choices.any(
    (choice) =>
        choice.phase == phase && !choice.attempted && choice.ready == true,
  );

  /// Prefer already proven transports in this scope over an unmeasured one.
  /// Pending probes get a bounded head start, never a fresh per-transport wait.
  Future<TransferRouteChoice?> next(String phase, Duration wait) async {
    final watch = Stopwatch()..start();
    while (true) {
      final remaining = choices
          .where(
            (choice) =>
                choice.phase == phase &&
                !choice.attempted &&
                choice.ready != false,
          )
          .toList();
      final proven = remaining.where((choice) => choice.ready == true).toList();
      proven.sort((a, b) {
        final timing = (a.latency?.call() ?? 0x7fffffff).compareTo(
          b.latency?.call() ?? 0x7fffffff,
        );
        return timing != 0
            ? timing
            : choices.indexOf(a).compareTo(choices.indexOf(b));
      });
      final ready = proven.firstOrNull;
      if (ready != null) return ready;
      final budget = wait - watch.elapsed;
      if (!remaining.any((choice) => choice.pending) ||
          budget <= Duration.zero) {
        return remaining.firstOrNull;
      }
      await _wake.future.timeout(budget, onTimeout: () {});
    }
  }

  Duration attemptBudget(TransferRouteChoice choice, Duration remaining) {
    if (choice.ready == true) {
      // The one-second decision races read-only probes. A selected, proven
      // path still needs a center grant and a fresh TLS/file handshake; slicing
      // those round trips between alternatives creates false relay fallbacks.
      final handshakeMs = ((choice.latency?.call() ?? 0) * 4 + 100).clamp(
        1000,
        3000,
      );
      return Duration(milliseconds: handshakeMs);
    }
    final alternatives = choices
        .where(
          (value) =>
              value.phase == choice.phase &&
              !value.attempted &&
              value.ready != false,
        )
        .length;
    // An unknown transport must not exhaust a scope before another probe can
    // finish. Proven choices retain a useful handshake window, not tiny slices.
    return alternatives <= 1
        ? remaining
        : Duration(microseconds: remaining.inMicroseconds ~/ alternatives);
  }

  void close() {
    for (final choice in choices) {
      choice._changed = null;
    }
  }
}
