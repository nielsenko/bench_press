import 'package:bench_press/bench_press.dart';
import 'package:bench_press/src/batch_runner.dart';
import 'package:bench_press/src/runner.dart';
import 'package:bench_press/src/telemetry/schema.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

/// Counters that advance by a fixed step with every reading, so each batch,
/// which reads twice, spans exactly one step.
final class _SteppingCounters() implements PerfCounters {
  static const int instructionsPerBatch = 6000000;
  static const int cyclesPerBatch = 2000000;

  int reads = 0;

  @override
  String get source => 'test';

  @override
  String get modes => 'user';

  @override
  CounterReading read() {
    reads++;
    return CounterReading(
      instructions: reads * instructionsPerBatch,
      cycles: reads * cyclesPerBatch,
    );
  }

  @override
  void close() {}
}

final class _Work(super.name) extends Benchmark {
  int count = 0;

  @override
  BenchmarkConfig get config => const BenchmarkConfig(
    trials: 4,
    minWarmupIterations: 2,
    maxWarmupIterations: 4,
    targetBatchDuration: Duration(milliseconds: 2),
  );

  @override
  void run() => Blackhole.consume(count++);
}

final class _AsyncWork(super.name) extends AsyncBenchmark {
  int count = 0;

  @override
  BenchmarkConfig get config => const BenchmarkConfig(
    trials: 4,
    minWarmupIterations: 2,
    maxWarmupIterations: 4,
    targetBatchDuration: Duration(milliseconds: 2),
  );

  @override
  Future<void> run() async => Blackhole.consume(count++);
}

void main() {
  late _SteppingCounters counters;

  setUp(() {
    counters = _SteppingCounters();
    BatchCounters.instance = counters;
  });
  tearDown(BatchCounters.reset);

  group('BatchRunner', () {
    test('runSync divides the counts of the batch by its iterations', () {
      final measurement = BatchRunner.runSync(_Work('sync'), 100);

      check(counters.reads).equals(2);
      check(measurement.instructionsPerOp).equals(60000.0);
      check(measurement.cyclesPerOp).equals(20000.0);
    });

    test(
      'runAsync divides the counts of the batch by its iterations',
      () async {
        final measurement = await BatchRunner.runAsync(_AsyncWork('async'), 50);

        check(measurement.instructionsPerOp).equals(120000.0);
        check(measurement.cyclesPerOp).equals(40000.0);
      },
    );

    test('runVariantSync and runVariantAsync count their batches', () async {
      final variant = BenchmarkVariant('variant', () => 1);

      final sync = BatchRunner.runVariantSync(variant, 10);
      final async = await BatchRunner.runVariantAsync(variant, 20);

      check(sync.instructionsPerOp).equals(600000.0);
      check(async.instructionsPerOp).equals(300000.0);
    });

    test('measures no counts when the counters are disabled', () {
      BatchCounters.enabled = false;

      final measurement = BatchRunner.runSync(_Work('off'), 100);

      check(counters.reads).equals(0);
      check(measurement.instructionsPerOp).isNull();
      check(measurement.cyclesPerOp).isNull();
    });
  });

  group('BenchmarkRunner', () {
    void checkSamples(BenchmarkResult result) {
      final samples = result.counters;
      final iterations = result.calibratedBatch.iterations;
      check(samples).isNotNull();
      check(samples!.source).equals('test');
      check(samples.modes).equals('user');
      check(samples.instructionsPerOp).length
          .equals(result.rawTrialLatenciesNs.length);
      for (final perOp in samples.instructionsPerOp) {
        check(perOp * iterations)
            .isCloseTo(_SteppingCounters.instructionsPerBatch.toDouble(), 1e-3);
      }
      for (final perOp in samples.cyclesPerOp) {
        check(perOp * iterations)
            .isCloseTo(_SteppingCounters.cyclesPerBatch.toDouble(), 1e-3);
      }
    }

    test('run records one counter sample per trial', () {
      checkSamples(BenchmarkRunner.run(_Work('sync')));
    });

    test('runAsync records one counter sample per trial', () async {
      checkSamples(await BenchmarkRunner.runAsync(_AsyncWork('async')));
    });

    test('runVariants records one counter sample per trial of every variant, '
        'sync and async', () async {
      const config = BenchmarkConfig(
        trials: 4,
        minWarmupIterations: 2,
        maxWarmupIterations: 4,
        targetBatchDuration: Duration(milliseconds: 2),
      );

      final results = await BenchmarkRunner.runVariants([
        BenchmarkVariant('sync', () => 1, isBaseline: true),
        BenchmarkVariant('async', () async => 1),
      ], config: config);

      check(results).length.equals(2);
      results.forEach(checkSamples);
    });

    test('run records no counter samples when the counters are disabled', () {
      BatchCounters.enabled = false;

      final result = BenchmarkRunner.run(_Work('off'));

      check(result.counters).isNull();
      check(result.toJson().containsKey('counters')).isFalse();
    });

    test('the result carries its counter samples into JSON', () {
      final json = BenchmarkRunner.run(_Work('json')).toJson();

      final counters = json['counters'] as Map<String, Object?>;
      check(counters['source']).equals('test');
      check(counters['instructions_per_op'])
          .isA<List<double>>()
          .length
          .equals(4);
    });
  });

  group('BenchmarkEntry', () {
    test('fromResult keeps the counter samples through JSON', () {
      final entry = BenchmarkEntry.fromResult(BenchmarkRunner.run(_Work('a')));

      final decoded = BenchmarkEntry.fromJson(entry.toJson());

      check(decoded.counters).isNotNull();
      check(decoded.counters!.instructionsPerOp)
          .deepEquals(entry.counters!.instructionsPerOp);
      check(decoded.copyWith(isBaseline: true).counters).isNotNull();
    });

    test('fromProcesses aggregates the counter samples of the processes', () {
      final first = BenchmarkEntry.fromResult(BenchmarkRunner.run(_Work('a')));
      final second = BenchmarkEntry.fromResult(BenchmarkRunner.run(_Work('a')));

      final aggregated = BenchmarkEntry.fromProcesses([first, second]);

      check(aggregated.counters).isNotNull();
      check(aggregated.counters!.instructionsPerOp).length.equals(8);
      check(aggregated.counters!.processMeanInstructions).length.equals(2);
    });

    test('fromJson rejects counters that are not a map', () {
      final json = BenchmarkEntry.fromResult(BenchmarkRunner.run(_Work('a')))
          .toJson();
      json['counters'] = 'none';

      check(() => BenchmarkEntry.fromJson(json)).throws<FormatException>();
    });
  });
}
