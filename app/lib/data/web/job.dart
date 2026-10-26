import 'dart:async';

/// Thrown inside a [Job] that was cancelled, to unwind it at its next suspension point.
class Cancelled implements Exception {
  const Cancelled();
}

/// A piece of work that can be called off, the counterpart of a Kotlin coroutine Job in `GroupSession`. Everything
/// runs on the one event loop, so handlers and jobs only interleave where a job waits.
class Job {
  Job._();

  bool _cancelled = false;
  bool _finished = false;
  final _done = Completer<void>();
  final _called = Completer<void>();
  final _sleepers = <Completer<void>>[];

  /// Runs [body] now, until it ends or is cancelled. Errors other than the cancellation go to [onError].
  static Job launch(
    Future<void> Function(Job job) body, {
    void Function(Object error, StackTrace stack)? onError,
  }) {
    final job = Job._();
    () async {
      try {
        await body(job);
      } on Cancelled {
        // Called off: nothing to report
      } catch (e, s) {
        if (onError != null) onError(e, s);
      } finally {
        job._finished = true;
        job._done.complete();
      }
    }();
    return job;
  }

  bool get isActive => !_cancelled && !_finished;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _called.complete();
    for (final s in _sleepers.toList()) {
      if (!s.isCompleted) s.complete();
    }
  }

  /// Completes when the job is cancelled, for work that waits on something else and must not outlast the job.
  Future<void> get cancelled => _called.future;

  /// Completes when the work ended or was cancelled.
  Future<void> join() => _done.future;

  /// Throws [Cancelled] when the job was called off; the work calls it after every wait.
  void check() {
    if (_cancelled) throw const Cancelled();
  }

  /// Waits for [duration]; a cancellation ends the wait at once.
  Future<void> delay(Duration duration) async {
    check();
    final wake = Completer<void>();
    _sleepers.add(wake);
    final timer = Timer(duration, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
    _sleepers.remove(wake);
    check();
  }

  /// Waits for [work], then throws if the job was called off meanwhile.
  Future<T> guard<T>(Future<T> work) async {
    try {
      final value = await work;
      check();
      return value;
    } catch (_) {
      // Work that failed because the job was called off is the cancellation, not a failure
      check();
      rethrow;
    }
  }
}
