import 'package:bench_press/bench_press.dart';
import 'package:bench_press/src/telemetry/markdown_reporter.dart';
import 'package:bench_press/src/telemetry/schema.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

import 'test_helpers.dart';

CounterSamples _counters(
  List<double> instructions, {
  String source = 'perf_event_open',
  String modes = 'user',
}) => CounterSamples(
  source: source,
  modes: modes,
  instructionsPerOp: instructions,
  cyclesPerOp: [for (final i in instructions) i / 2],
);

BenchmarkEntry _entry(
  String name, {
  CounterSamples? counters,
  String? group,
  bool isBaseline = false,
}) => BenchmarkEntry(
  name: name,
  target: 'jit',
  mode: 'sync',
  samples: 4,
  metrics: createSampleMetrics(),
  rawTrialsNs: const [100.0, 101.0, 99.0, 100.0],
  coordinates: BenchmarkCoordinates({'group': ?group}),
  isBaseline: isBaseline,
  counters: counters,
);

void main() {
  group('MarkdownReporter.renderCounterTable', () {
    test('compares the instructions of a candidate with its baseline', () {
      final suite = createSampleSuite(
        benchmarks: [
          _entry(
            'map',
            group: 'headers',
            isBaseline: true,
            counters: _counters(const [2000.0, 2002.0, 1998.0, 2000.0]),
          ),
          _entry(
            'bytes',
            group: 'headers',
            counters: _counters(const [1000.0, 1001.0, 999.0, 1000.0]),
          ),
        ],
      );

      final table = MarkdownReporter.renderCounterTable(suite);

      check(table).contains('### Hardware Counters');
      check(table).contains(
        '| headers / map (Baseline) | `jit` | 2.00k (±0.08%) | 1.00k | 2.00 | '
        'ref | - |',
      );
      check(table).contains(
        '| headers / bytes | `jit` | 1.00k (±0.08%) | 500.0 | 2.00 | -50.00% | '
        '[-50.',
      );
      check(table).contains(
        '> Counted in `user` mode by `perf_event_open`, over every thread of '
        'the process.',
      );
    });

    test('shows a lone benchmark without a comparison', () {
      final suite = createSampleSuite(
        benchmarks: [
          _entry('solo', counters: _counters(const [1500000.0, 1500000.0])),
        ],
      );

      final table = MarkdownReporter.renderCounterTable(suite);

      check(
        table,
      ).contains('| solo | `jit` | 1.50M (±0.00%) | 750.00k | 2.00 | - | - |');
    });

    test(
      'withholds the interval while the instruction counts are unstable',
      () {
        final suite = createSampleSuite(
          benchmarks: [
            _entry(
              'base',
              group: 'g',
              isBaseline: true,
              counters: _counters(const [1000.0, 1400.0, 800.0, 1200.0]),
            ),
            _entry(
              'candidate',
              group: 'g',
              counters: _counters(const [550.0, 551.0, 549.0, 550.0]),
            ),
          ],
        );

        final table = MarkdownReporter.renderCounterTable(suite);

        check(table).contains('| g / candidate | `jit` |');
        check(table).contains('| -50.00% | [N/A] |');
      },
    );

    test('does not compare counts taken in different modes', () {
      final suite = createSampleSuite(
        benchmarks: [
          _entry(
            'base',
            group: 'g',
            isBaseline: true,
            counters: _counters(const [1000.0, 1000.0]),
          ),
          _entry(
            'candidate',
            group: 'g',
            counters: _counters(
              const [900.0, 900.0],
              source: 'proc_pid_rusage',
              modes: 'user+kernel',
            ),
          ),
        ],
      );

      final table = MarkdownReporter.renderCounterTable(suite);

      check(table).contains('| - | [N/A] |');
      check(table).contains(
        '> Counted in `user` mode by `perf_event_open` and in `user+kernel` '
        'mode by `proc_pid_rusage`',
      );
    });

    test('lists only the benchmarks that have samples', () {
      final suite = createSampleSuite(
        benchmarks: [
          _entry('counted', counters: _counters(const [10.0, 10.0])),
          _entry('uncounted'),
        ],
      );

      final table = MarkdownReporter.renderCounterTable(suite);

      check(table).contains('| counted |');
      check(table).not(.it()..contains('uncounted'));
    });

    test('is empty when no benchmark has samples', () {
      final suite = createSampleSuite(benchmarks: [_entry('uncounted')]);

      check(MarkdownReporter.renderCounterTable(suite)).isEmpty;
    });
  });

  group('MarkdownReporter.renderSuite', () {
    test('ends with the counter table when a benchmark has samples', () {
      final suite = createSampleSuite(
        benchmarks: [
          _entry('solo', counters: _counters(const [10.0, 10.0])),
        ],
      );

      final report = MarkdownReporter.renderSuite(suite);

      check(report).contains('### All Benchmarks');
      check(report).contains('### Hardware Counters');
      check(report.indexOf('### Hardware Counters'))
          .isGreaterThan(report.indexOf('### All Benchmarks'));
    });

    test('ends a grouped suite with the counter table', () {
      final suite = createSampleSuite(
        benchmarks: [
          _entry(
            'a',
            group: 'g',
            isBaseline: true,
            counters: _counters(const [10.0, 10.0]),
          ),
          _entry('b', group: 'g', counters: _counters(const [20.0, 20.0])),
        ],
      );

      final report = MarkdownReporter.renderSuite(suite);

      check(report).contains('### Hardware Counters');
      check(report).contains('| g / b | `jit` |');
    });

    test('has no counter table when no benchmark has samples', () {
      final suite = createSampleSuite(benchmarks: [_entry('uncounted')]);

      check(MarkdownReporter.renderSuite(suite))
          .not(.it()..contains('Hardware Counters'));
    });
  });

  group('MarkdownReporter.renderDeltaTable', () {
    test('compares the instructions of the two runs', () {
      final baseline = createSampleSuite(
        benchmarks: [
          _entry('parse', counters: _counters(const [1000.0, 1001.0, 999.0])),
        ],
      );
      final current = createSampleSuite(
        benchmarks: [
          _entry('parse', counters: _counters(const [900.0, 901.0, 899.0])),
        ],
      );

      final report = MarkdownReporter.renderDeltaTable(
        baseline: baseline,
        current: current,
      );

      check(report).contains('#### Instructions per Operation');
      check(report).contains(
        '| Benchmark | Target | Baseline | Current | Delta (%) | '
        '95% CI (Fieller) |',
      );
      check(report)
          .contains('| parse | `jit` | 1.00k | 900.0 | -10.00% | [-10.');
    });

    test('notes runs counted in different modes', () {
      final baseline = createSampleSuite(
        benchmarks: [
          _entry('parse', counters: _counters(const [1000.0, 1000.0])),
        ],
      );
      final current = createSampleSuite(
        benchmarks: [
          _entry(
            'parse',
            counters: _counters(
              const [900.0, 900.0],
              source: 'proc_pid_rusage',
              modes: 'user+kernel',
            ),
          ),
        ],
      );

      final report = MarkdownReporter.renderDeltaTable(
        baseline: baseline,
        current: current,
      );

      check(report).contains('| parse | `jit` | 1.00k | 900.0 | - | [N/A] |');
      check(report).contains(
        '> Runs counted by different interfaces or in different modes are '
        'not compared.',
      );
    });

    test('has no instruction table when either run has no samples', () {
      final baseline = createSampleSuite(
        benchmarks: [
          _entry('parse', counters: _counters(const [1000.0, 1000.0])),
        ],
      );
      final current = createSampleSuite(benchmarks: [_entry('parse')]);

      final report = MarkdownReporter.renderDeltaTable(
        baseline: baseline,
        current: current,
      );

      check(report).not(.it()..contains('Instructions per Operation'));
    });
  });
}
