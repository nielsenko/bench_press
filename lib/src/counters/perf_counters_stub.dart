import 'perf_counters.dart';

/// No hardware counters where `dart:ffi` is missing.
PerfCounters? openPerfCounters({
  required List<int>? pids,
  required bool kernel,
  required void Function(String reason)? onUnavailable,
}) {
  onUnavailable?.call('no hardware counters without dart:ffi');
  return null;
}
