import 'perf_counters_stub.dart'
    if (dart.library.io) 'perf_counters_native.dart'
    as platform;

/// One reading of a [PerfCounters]: totals since the counters opened, or
/// since the processes started.
final class const CounterReading({
  /// Instructions retired, in the modes [PerfCounters.modes] names.
  required final int instructions,

  /// CPU cycles, in the modes [PerfCounters.modes] names.
  required final int cycles,

  /// Instructions retired in kernel mode, where the counters were opened with
  /// `kernel: true` and the platform counts kernel mode apart.
  final int? kernelInstructions,

  /// CPU cycles in kernel mode, as [kernelInstructions].
  final int? kernelCycles,
}) {
  @override
  String toString() =>
      'CounterReading(instructions: $instructions, cycles: $cycles'
      '${kernelInstructions == null ? '' : ', kernel: $kernelInstructions'})';
}

/// The hardware counters of one or more processes: instructions retired and
/// CPU cycles, summed over every thread.
///
/// Instructions retired barely move with the load on the machine, where wall
/// time does, so they compare two runs of the same code on a busy host.
///
/// macOS reads the counters with `proc_pid_rusage`. That takes no privilege
/// and counts user and kernel mode together, so [modes] is `user+kernel`.
///
/// Linux opens `perf_event_open` counters on every thread of each process,
/// inherited by the threads and processes they start later. [modes] is
/// `user`, and `kernel: true` adds counters for kernel mode beside them. The
/// machine needs a PMU, which most virtual machines hide, and
/// `kernel.perf_event_paranoid` at 2 or below for user mode and at 1 or below
/// for kernel mode. A container also needs `perf_event_open` allowed by its
/// seccomp profile.
abstract interface class PerfCounters() {
  /// Opens the counters of [pids], or of this process when [pids] is null.
  ///
  /// Returns null where the platform, the machine or its permissions give
  /// none, after passing the reason to [onUnavailable]. Compiled to JavaScript
  /// or WebAssembly there are none.
  static PerfCounters? open({
    List<int>? pids,
    bool kernel = false,
    void Function(String reason)? onUnavailable,
  }) => platform.openPerfCounters(
    pids: pids,
    kernel: kernel,
    onUnavailable: onUnavailable,
  );

  /// The system interface behind the counters: `proc_pid_rusage` or
  /// `perf_event_open`.
  String get source;

  /// The modes [CounterReading.instructions] and [CounterReading.cycles]
  /// count: `user` or `user+kernel`.
  String get modes;

  /// The totals so far. They never decrease, also when a process or thread
  /// among the counted ones has exited.
  CounterReading read();

  /// Releases the counters. [read] must not be called afterwards.
  void close();
}
