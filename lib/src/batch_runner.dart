import 'dart:async';

import 'package:meta/meta.dart';

import 'blackhole.dart';
import 'counters/perf_counters.dart';
import 'harness.dart';

/// Result from executing a single calibrated measurement batch.
final class const BatchMeasurement({
  /// The calibrated iteration count executed during the batch.
  required final int iterations,

  /// Total elapsed time in microseconds for the entire batch.
  required final int totalElapsedMicroseconds,

  /// Derived per-operation latency in nanoseconds.
  required final double perOpNanoseconds,

  /// Instructions retired per operation over the batch, or null without
  /// hardware counters.
  final double? instructionsPerOp,

  /// CPU cycles per operation over the batch, or null without hardware
  /// counters.
  final double? cyclesPerOp,
}) {
  /// The measurement of [iterations] operations that took [elapsedUs], with
  /// the counter readings taken right [before] and [after] them.
  factory timed(
    int iterations,
    int elapsedUs,
    CounterReading? before,
    CounterReading? after,
  ) => BatchMeasurement(
    iterations: iterations,
    totalElapsedMicroseconds: elapsedUs,
    perOpNanoseconds: (elapsedUs * 1000.0) / iterations,
    instructionsPerOp: before == null || after == null
        ? null
        : (after.instructions - before.instructions) / iterations,
    cyclesPerOp: before == null || after == null
        ? null
        : (after.cycles - before.cycles) / iterations,
  );
}

/// The hardware counters every measurement batch of this process reads.
abstract final class BatchCounters() {
  static bool _opened = false;
  static PerfCounters? _counters;

  /// Whether batches read the counters (default: true).
  static bool enabled = true;

  /// The counters of this process, opened on first use, or null where the
  /// machine has none or [enabled] is false.
  static PerfCounters? get instance {
    if (!enabled) return null;
    if (!_opened) {
      _opened = true;
      _counters = PerfCounters.open();
    }
    return _counters;
  }

  /// Replaces the counters batches read, for a test with scripted readings.
  @visibleForTesting
  static set instance(PerfCounters? counters) {
    _opened = true;
    _counters = counters;
  }

  /// Forgets the counters and the [enabled] setting, so the next batch opens
  /// the counters of this process again.
  @visibleForTesting
  static void reset() {
    _opened = false;
    _counters = null;
    enabled = true;
  }
}

/// Executes monomorphic inner measurement batch loops.
abstract final class BatchRunner() {
  /// Runs a single synchronous measurement batch for [benchmark] with
  /// [iterations].
  static BatchMeasurement runSync(Benchmark benchmark, int iterations) {
    final stopwatch = Stopwatch();
    final counters = BatchCounters.instance;

    // The counters are read outside the timed region.
    final before = counters?.read();
    stopwatch.start();
    for (var i = 0; i < iterations; i++) {
      benchmark.run();
    }
    stopwatch.stop();
    final after = counters?.read();

    // Drain the Blackhole to prevent dead-store elimination of writes
    Blackhole.drain();

    return BatchMeasurement.timed(
      iterations,
      stopwatch.elapsedMicroseconds,
      before,
      after,
    );
  }

  /// Runs a single asynchronous measurement batch for [benchmark] with
  /// [iterations].
  static Future<BatchMeasurement> runAsync(
    AsyncBenchmark benchmark,
    int iterations,
  ) async {
    final stopwatch = Stopwatch();
    final counters = BatchCounters.instance;

    final before = counters?.read();
    stopwatch.start();
    for (var i = 0; i < iterations; i++) {
      await benchmark.run();
    }
    stopwatch.stop();
    final after = counters?.read();

    Blackhole.drain();

    return BatchMeasurement.timed(
      iterations,
      stopwatch.elapsedMicroseconds,
      before,
      after,
    );
  }

  /// Runs a synchronous measurement batch for a [variant].
  static BatchMeasurement runVariantSync(
    BenchmarkVariant variant,
    int iterations,
  ) {
    final stopwatch = Stopwatch();
    final counters = BatchCounters.instance;

    final before = counters?.read();
    stopwatch.start();
    for (var i = 0; i < iterations; i++) {
      variant.executeSync();
    }
    stopwatch.stop();
    final after = counters?.read();

    Blackhole.drain();

    return BatchMeasurement.timed(
      iterations,
      stopwatch.elapsedMicroseconds,
      before,
      after,
    );
  }

  /// Runs an asynchronous measurement batch for a [variant].
  static Future<BatchMeasurement> runVariantAsync(
    BenchmarkVariant variant,
    int iterations,
  ) async {
    final stopwatch = Stopwatch();
    final counters = BatchCounters.instance;

    final before = counters?.read();
    stopwatch.start();
    for (var i = 0; i < iterations; i++) {
      await variant.executeAsync();
    }
    stopwatch.stop();
    final after = counters?.read();

    Blackhole.drain();

    return BatchMeasurement.timed(
      iterations,
      stopwatch.elapsedMicroseconds,
      before,
      after,
    );
  }
}
