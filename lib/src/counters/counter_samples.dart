import '../stats/metrics.dart';
import 'perf_counters.dart';

/// The hardware counter samples of one benchmark: instructions retired and
/// CPU cycles per operation, one of each per measurement trial.
final class const CounterSamples({
  /// The system interface the counts came from, [PerfCounters.source].
  required final String source,

  /// The modes counted, [PerfCounters.modes].
  required final String modes,

  /// Instructions retired per operation, one value per trial.
  required final List<double> instructionsPerOp,

  /// CPU cycles per operation, one value per trial.
  required final List<double> cyclesPerOp,

  /// The mean of [instructionsPerOp] within each OS process, when the samples
  /// were aggregated from more than one.
  final List<double> processMeanInstructions = const [],

  /// The mean of [cyclesPerOp] within each OS process, as
  /// [processMeanInstructions].
  final List<double> processMeanCycles = const [],
}) {
  /// The independent instruction samples for an interval estimate:
  /// [processMeanInstructions] when there are any, [instructionsPerOp]
  /// otherwise.
  List<double> get effectiveInstructions => processMeanInstructions.isNotEmpty
      ? processMeanInstructions
      : instructionsPerOp;

  /// The mean instructions retired per operation over all trials.
  double get meanInstructions => _mean(instructionsPerOp);

  /// The mean CPU cycles per operation over all trials.
  double get meanCycles => _mean(cyclesPerOp);

  /// The coefficient of variation of [effectiveInstructions].
  double get instructionsCv =>
      BenchmarkMetrics.fromSamples(effectiveInstructions).cv;

  /// Whether [instructionsCv] is within [BenchmarkMetrics.maxCvThreshold].
  bool get isStable => instructionsCv <= BenchmarkMetrics.maxCvThreshold;

  /// Instructions retired per CPU cycle.
  double get instructionsPerCycle => meanInstructions / meanCycles;

  static double _mean(List<double> values) {
    if (values.isEmpty) return double.nan;
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }

  /// Aggregates the samples of `P` independent OS processes: the trials are
  /// pooled and each process contributes its means.
  ///
  /// Returns null unless every process has samples from the same [source]
  /// in the same [modes].
  static CounterSamples? fromProcesses(List<CounterSamples?> processes) {
    final present = processes.nonNulls.toList();
    if (present.isEmpty || present.length != processes.length) return null;
    final first = present.first;
    if (present.length == 1) return first;
    if (present.any(
      (p) => p.source != first.source || p.modes != first.modes,
    )) {
      return null;
    }
    return CounterSamples(
      source: first.source,
      modes: first.modes,
      instructionsPerOp: List.unmodifiable([
        for (final p in present) ...p.instructionsPerOp,
      ]),
      cyclesPerOp: List.unmodifiable([
        for (final p in present) ...p.cyclesPerOp,
      ]),
      processMeanInstructions: List.unmodifiable([
        for (final p in present) p.meanInstructions,
      ]),
      processMeanCycles: List.unmodifiable([
        for (final p in present) p.meanCycles,
      ]),
    );
  }

  /// Converts the samples to a canonical JSON map.
  Map<String, Object?> toJson() => {
    'source': source,
    'modes': modes,
    'instructions_per_op': instructionsPerOp,
    'cycles_per_op': cyclesPerOp,
    if (processMeanInstructions.isNotEmpty)
      'process_mean_instructions': processMeanInstructions,
    if (processMeanCycles.isNotEmpty) 'process_mean_cycles': processMeanCycles,
  };

  /// Constructs [CounterSamples] from a JSON map with schema validation.
  factory fromJson(Map<String, Object?> json) {
    final instructions = _parseSamples(json, 'instructions_per_op');
    final cycles = _parseSamples(json, 'cycles_per_op');
    if (instructions.isEmpty || instructions.length != cycles.length) {
      throw FormatException(
        'Invalid "counters": ${instructions.length} "instructions_per_op" and '
        '${cycles.length} "cycles_per_op" samples (expected the same '
        'non-zero number of each)',
      );
    }
    return CounterSamples(
      source: _parseString(json, 'source'),
      modes: _parseString(json, 'modes'),
      instructionsPerOp: instructions,
      cyclesPerOp: cycles,
      processMeanInstructions: _parseSamples(json, 'process_mean_instructions'),
      processMeanCycles: _parseSamples(json, 'process_mean_cycles'),
    );
  }

  static String _parseString(Map<String, Object?> json, String key) =>
      switch (json[key]) {
        final String s when s.isNotEmpty => s,
        final other => throw FormatException(
          'Invalid "$key" in "counters": expected a non-empty String, '
          'got $other',
        ),
      };

  static List<double> _parseSamples(Map<String, Object?> json, String key) =>
      switch (json[key]) {
        null => const <double>[],
        final List<Object?> values => List.unmodifiable([
          for (final v in values)
            if (v is num)
              v.toDouble()
            else
              throw FormatException(
                'Invalid sample $v in "$key" of "counters" (expected num)',
              ),
        ]),
        final other => throw FormatException(
          'Invalid "$key" in "counters": expected List, '
          'got ${other.runtimeType}',
        ),
      };

  @override
  String toString() =>
      'CounterSamples(${meanInstructions.toStringAsFixed(1)} instructions/op, '
      '${meanCycles.toStringAsFixed(1)} cycles/op, $modes, $source)';
}
