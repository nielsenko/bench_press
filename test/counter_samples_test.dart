import 'package:bench_press/bench_press.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

const _samples = CounterSamples(
  source: 'perf_event_open',
  modes: 'user',
  instructionsPerOp: [100.0, 102.0, 98.0, 100.0],
  cyclesPerOp: [50.0, 51.0, 49.0, 50.0],
);

void main() {
  group('CounterSamples', () {
    test('summarizes the trials', () {
      check(_samples.meanInstructions).equals(100.0);
      check(_samples.meanCycles).equals(50.0);
      check(_samples.instructionsPerCycle).equals(2.0);
      check(_samples.instructionsCv).isCloseTo(0.0163, 0.0001);
      check(_samples.isStable).isTrue;
    });

    test('is unstable when the instruction counts spread past 5%', () {
      const noisy = CounterSamples(
        source: 'perf_event_open',
        modes: 'user',
        instructionsPerOp: [100.0, 140.0, 80.0, 120.0],
        cyclesPerOp: [50.0, 50.0, 50.0, 50.0],
      );

      check(noisy.isStable).isFalse;
    });

    test('round-trips through JSON', () {
      final decoded = CounterSamples.fromJson(_samples.toJson());

      check(decoded.source).equals('perf_event_open');
      check(decoded.modes).equals('user');
      check(decoded.instructionsPerOp).deepEquals(_samples.instructionsPerOp);
      check(decoded.cyclesPerOp).deepEquals(_samples.cyclesPerOp);
      check(decoded.processMeanInstructions).isEmpty;
    });

    test('rejects JSON with a different number of the two samples', () {
      check(
        () => CounterSamples.fromJson({
          'source': 'perf_event_open',
          'modes': 'user',
          'instructions_per_op': [1.0, 2.0],
          'cycles_per_op': [1.0],
        }),
      ).throws<FormatException>();
    });

    test('rejects JSON without a source', () {
      check(
        () => CounterSamples.fromJson({
          'modes': 'user',
          'instructions_per_op': [1.0],
          'cycles_per_op': [1.0],
        }),
      ).throws<FormatException>();
    });

    group('fromProcesses', () {
      const other = CounterSamples(
        source: 'perf_event_open',
        modes: 'user',
        instructionsPerOp: [110.0, 110.0],
        cyclesPerOp: [60.0, 60.0],
      );

      test('pools the trials and takes a mean per process', () {
        final pooled = CounterSamples.fromProcesses([_samples, other])!;

        check(pooled.instructionsPerOp).length.equals(6);
        check(pooled.processMeanInstructions).deepEquals([100.0, 110.0]);
        check(pooled.processMeanCycles).deepEquals([50.0, 60.0]);
        check(pooled.effectiveInstructions).deepEquals([100.0, 110.0]);
        check(CounterSamples.fromJson(pooled.toJson()).processMeanInstructions)
            .deepEquals([100.0, 110.0]);
      });

      test('returns the samples of a single process as they are', () {
        check(CounterSamples.fromProcesses([_samples])).identicalTo(_samples);
      });

      test('gives none when a process has none', () {
        check(CounterSamples.fromProcesses([_samples, null])).isNull;
        check(CounterSamples.fromProcesses([])).isNull;
      });

      test('gives none when the processes counted different modes', () {
        const allModes = CounterSamples(
          source: 'proc_pid_rusage',
          modes: 'user+kernel',
          instructionsPerOp: [100.0],
          cyclesPerOp: [50.0],
        );

        check(CounterSamples.fromProcesses([_samples, allModes])).isNull;
      });
    });
  });
}
