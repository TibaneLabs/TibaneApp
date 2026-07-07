import 'dart:async';

/// Runs an async task while collapsing overlapping calls: at most one run is in
/// flight at a time, and any number of calls that arrive while one is running
/// trigger exactly **one** catch-up run afterwards (not one per call).
///
/// Used to absorb bursty refresh triggers — e.g. libwallet's balance poller can
/// echo several `balanceTick`s per cycle — into a single reload plus one
/// follow-up that reflects the latest state, instead of fanning out a redundant
/// network fetch per tick. See BALANCES_STORE_MIGRATION.md.
class Coalescer {
  Coalescer(this._task);

  final Future<void> Function() _task;
  bool _inFlight = false;
  bool _queued = false;
  bool _cancelled = false;

  /// True while a run is executing.
  bool get isRunning => _inFlight;

  /// Trigger a run. If one is already in flight, mark that a catch-up is needed
  /// and return immediately; the catch-up fires once the current run finishes.
  Future<void> run() async {
    if (_inFlight) {
      _queued = true;
      return;
    }
    _inFlight = true;
    try {
      await _task();
    } finally {
      _inFlight = false;
      if (_queued && !_cancelled) {
        _queued = false;
        unawaited(run());
      }
    }
  }

  /// Stop scheduling further catch-up runs (e.g. on dispose). A run already in
  /// flight still completes.
  void cancel() => _cancelled = true;
}
