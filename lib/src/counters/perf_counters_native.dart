import 'dart:ffi';
import 'dart:io';

import 'package:meta/meta.dart';

import 'perf_counters.dart';

/// Opens the counters of [pids] through `proc_pid_rusage` on macOS and
/// `perf_event_open` on Linux.
///
/// With [softwareClocks], Linux counts the task clock in place of
/// instructions and the CPU clock in place of cycles, both in nanoseconds.
/// Those need no PMU, so a test can open, inherit and read counters on a
/// virtual machine.
PerfCounters? openPerfCounters({
  required List<int>? pids,
  required bool kernel,
  required void Function(String reason)? onUnavailable,
  @visibleForTesting bool softwareClocks = false,
}) {
  final targets = pids ?? [pid];
  final (symbols, open) = switch (Platform.operatingSystem) {
    'macos' => (
      const ['proc_pid_rusage'],
      () => _RusageCounters.open(targets, onUnavailable),
    ),
    'linux' => (
      const ['syscall', '__errno_location'],
      () => _PerfEventCounters.open(
        targets,
        kernel: kernel,
        onUnavailable: onUnavailable,
        softwareClocks: softwareClocks,
      ),
    ),
    _ => (const <String>[], null),
  };
  if (open == null) {
    onUnavailable?.call('no hardware counters on ${Platform.operatingSystem}');
    return null;
  }
  for (final symbol in symbols) {
    if (!_libc.providesSymbol(symbol)) {
      onUnavailable?.call('the C library has no $symbol');
      return null;
    }
  }
  return open();
}

final DynamicLibrary _libc = DynamicLibrary.process();

final Pointer<Void> Function(int, int) _calloc = _libc
    .lookupFunction<
      Pointer<Void> Function(Size, Size),
      Pointer<Void> Function(int, int)
    >('calloc', isLeaf: true);

final void Function(Pointer<Void>) _free = _libc
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'free',
      isLeaf: true,
    );

/// `proc_pid_rusage` with `RUSAGE_INFO_V4`, whose `ri_instructions` and
/// `ri_cycles` cover every thread of a process in user and kernel mode.
final class _RusageCounters(final List<int> _pids, final Pointer<Uint64> _words)
    implements PerfCounters {
  static const int _rusageInfoV4 = 4;

  /// `struct rusage_info_v4` is a 16 byte uuid and then 64-bit words, 296
  /// bytes in all. `ri_instructions` and `ri_cycles` are words 31 and 32.
  static const int _bufferWords = 64;
  static const int _instructionsWord = 31;
  static const int _cyclesWord = 32;

  static final int Function(int, int, Pointer<Void>) _procPidRusage = _libc
      .lookupFunction<
        Int32 Function(Int32, Int32, Pointer<Void>),
        int Function(int, int, Pointer<Void>)
      >('proc_pid_rusage', isLeaf: true);

  /// The last reading of each process, which stands in for it once it has
  /// exited.
  final Map<int, (int, int)> _last = {};

  static PerfCounters? open(
    List<int> pids,
    void Function(String reason)? onUnavailable,
  ) {
    final counters = _RusageCounters(
      List.of(pids),
      _calloc(_bufferWords, sizeOf<Uint64>()).cast(),
    );
    // A virtual machine without a PMU reports zero for both.
    if (counters.read().instructions == 0) {
      counters.close();
      onUnavailable?.call('proc_pid_rusage reports no instructions for $pids');
      return null;
    }
    return counters;
  }

  @override
  String get source => 'proc_pid_rusage';

  @override
  String get modes => 'user+kernel';

  @override
  CounterReading read() {
    var instructions = 0;
    var cycles = 0;
    for (final pid in _pids) {
      if (_procPidRusage(pid, _rusageInfoV4, _words.cast()) == 0) {
        _last[pid] = (_words[_instructionsWord], _words[_cyclesWord]);
      }
      final (i, c) = _last[pid] ?? (0, 0);
      instructions += i;
      cycles += c;
    }
    return CounterReading(instructions: instructions, cycles: cycles);
  }

  @override
  void close() => _free(_words.cast());
}

/// One `perf_event_open` counter and its last scaled value.
final class _Event(final int fd) {
  int last = 0;
}

/// `perf_event_open` counters for instructions and cycles on every thread of
/// the processes, in user mode and, when asked for and permitted, in kernel
/// mode.
final class _PerfEventCounters(
  final Pointer<Uint64> _words, {
  required final bool softwareClocks,
}) implements PerfCounters {
  /// `PERF_TYPE_HARDWARE` with `PERF_COUNT_HW_INSTRUCTIONS` and
  /// `PERF_COUNT_HW_CPU_CYCLES`, or `PERF_TYPE_SOFTWARE` with
  /// `PERF_COUNT_SW_TASK_CLOCK` and `PERF_COUNT_SW_CPU_CLOCK`.
  late final int _type = softwareClocks ? 1 : 0;
  late final int _configInstructions = 1;
  late final int _configCycles = 0;

  /// `PERF_ATTR_SIZE_VER0`, the first 64 bytes of `struct perf_event_attr`:
  /// type and size as 32-bit words, then config, sample_period, sample_type,
  /// read_format and the flag bits as 64-bit words.
  static const int _attrSize = 64;
  static const int _attrConfigWord = 1;
  static const int _attrReadFormatWord = 4;
  static const int _attrFlagsWord = 5;

  /// `PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING`: a
  /// read is the count, the time the counter was enabled and the time it was
  /// on the PMU.
  static const int _readFormat = 3;
  static const int _readWords = 3;

  static const int _flagInherit = 1 << 1;
  static const int _flagExcludeUser = 1 << 4;
  static const int _flagExcludeKernel = 1 << 5;
  static const int _flagExcludeHv = 1 << 6;

  /// `PERF_FLAG_FD_CLOEXEC`.
  static const int _openCloexec = 1 << 3;

  static const int _esrch = 3;

  static final int Function(int, Pointer<Void>, int, int, int, int) _syscall =
      _libc.lookupFunction<
        Int64 Function(
          Int64,
          VarArgs<(Pointer<Void>, Int32, Int32, Int32, Uint64)>,
        ),
        int Function(int, Pointer<Void>, int, int, int, int)
      >('syscall', isLeaf: true);

  static final int Function(int, Pointer<Void>, int) _read = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, Size),
        int Function(int, Pointer<Void>, int)
      >('read', isLeaf: true);

  static final int Function(int) _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>(
        'close',
        isLeaf: true,
      );

  static final Pointer<Int32> Function() _errnoLocation = _libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
        isLeaf: true,
      );

  /// The number of the `perf_event_open` system call, or null on an
  /// architecture this does not know.
  static int? get _perfEventOpen => switch (Abi.current()) {
    Abi.linuxX64 => 298,
    Abi.linuxArm64 || Abi.linuxRiscv64 => 241,
    Abi.linuxIA32 => 336,
    Abi.linuxArm => 364,
    _ => null,
  };

  final List<_Event> _userInstructions = [];
  final List<_Event> _userCycles = [];
  final List<_Event> _kernelInstructions = [];
  final List<_Event> _kernelCycles = [];
  bool _kernel = false;

  static PerfCounters? open(
    List<int> pids, {
    required bool kernel,
    required void Function(String reason)? onUnavailable,
    required bool softwareClocks,
  }) {
    final number = _perfEventOpen;
    if (number == null) {
      onUnavailable?.call('perf_event_open is unknown on ${Abi.current()}');
      return null;
    }
    final counters = _PerfEventCounters(
      _calloc(_attrSize ~/ sizeOf<Uint64>(), sizeOf<Uint64>()).cast(),
      softwareClocks: softwareClocks,
    ).._kernel = kernel;
    final failure = counters._openThreads(number, pids);
    if (failure != null) {
      counters.close();
      onUnavailable?.call(failure);
      return null;
    }
    return counters;
  }

  /// Opens the counters of every thread of [pids] and returns why that
  /// failed, or null.
  ///
  /// A thread started between the listing and the open of its parent is in
  /// neither, so the listing repeats until it finds no new thread.
  String? _openThreads(int number, List<int> pids) {
    final seen = <int>{};
    for (var pass = 0; pass < 4; pass++) {
      var added = false;
      for (final pid in pids) {
        for (final tid in _threads(pid)) {
          if (!seen.add(tid)) continue;
          added = true;
          final failure = _openThread(number, tid);
          if (failure != null) return failure;
        }
      }
      if (!added) break;
    }
    if (_userInstructions.isEmpty) return 'no thread of $pids to count';
    return null;
  }

  static List<int> _threads(int pid) {
    try {
      return [
        for (final entry in Directory('/proc/$pid/task').listSync())
          ?int.tryParse(entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty)),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  String? _openThread(int number, int tid) {
    const user = _flagInherit | _flagExcludeKernel | _flagExcludeHv;
    const kernel = _flagInherit | _flagExcludeUser | _flagExcludeHv;
    final instructions = _openEvent(number, _configInstructions, user, tid);
    if (instructions < 0) {
      final errno = _errnoLocation().value;
      // The thread exited since the listing.
      if (errno == _esrch) return null;
      return 'perf_event_open failed for instructions, errno $errno'
          '${_hint(errno)}';
    }
    _userInstructions.add(_Event(instructions));
    final cycles = _openEvent(number, _configCycles, user, tid);
    if (cycles < 0) {
      final errno = _errnoLocation().value;
      if (errno == _esrch) return null;
      return 'perf_event_open failed for cycles, errno $errno${_hint(errno)}';
    }
    _userCycles.add(_Event(cycles));
    if (!_kernel) return null;
    final kernelInstructions = _openEvent(
      number,
      _configInstructions,
      kernel,
      tid,
    );
    final kernelCycles = kernelInstructions < 0
        ? -1
        : _openEvent(number, _configCycles, kernel, tid);
    if (kernelInstructions < 0 || kernelCycles < 0) {
      if (_errnoLocation().value == _esrch) return null;
      // Kernel mode takes more privilege than user mode. Without it the
      // counters cover user mode alone.
      if (kernelInstructions >= 0) _close(kernelInstructions);
      _closeAll(_kernelInstructions);
      _closeAll(_kernelCycles);
      _kernel = false;
      return null;
    }
    _kernelInstructions.add(_Event(kernelInstructions));
    _kernelCycles.add(_Event(kernelCycles));
    return null;
  }

  int _openEvent(int number, int config, int flags, int tid) {
    for (var i = 0; i < _attrSize ~/ sizeOf<Uint64>(); i++) {
      _words[i] = 0;
    }
    _words.cast<Uint32>()[0] = _type;
    _words.cast<Uint32>()[1] = _attrSize;
    _words[_attrConfigWord] = config;
    _words[_attrReadFormatWord] = _readFormat;
    _words[_attrFlagsWord] = flags;
    // Any CPU, no group.
    return _syscall(number, _words.cast(), tid, -1, -1, _openCloexec);
  }

  static String _hint(int errno) => switch (errno) {
    1 || 13 =>
      ' (not permitted: check kernel.perf_event_paranoid and the seccomp '
          'profile)',
    2 || 19 || 95 => ' (this machine exposes no PMU)',
    24 => ' (out of file descriptors)',
    _ => '',
  };

  @override
  String get source => 'perf_event_open';

  @override
  String get modes => 'user';

  @override
  CounterReading read() => CounterReading(
    instructions: _sum(_userInstructions),
    cycles: _sum(_userCycles),
    kernelInstructions: _kernel ? _sum(_kernelInstructions) : null,
    kernelCycles: _kernel ? _sum(_kernelCycles) : null,
  );

  /// The counts of [events] together. A count is scaled up by the share of
  /// its enabled time the counter spent off the PMU, as `perf stat` does.
  int _sum(List<_Event> events) {
    var total = 0;
    for (final event in events) {
      const bytes = _readWords * 8;
      if (_read(event.fd, _words.cast(), bytes) == bytes) {
        final count = _words[0];
        final enabled = _words[1];
        final running = _words[2];
        event.last = running > 0 && running < enabled
            ? (count * (enabled / running)).round()
            : count;
      }
      total += event.last;
    }
    return total;
  }

  static void _closeAll(List<_Event> events) {
    for (final event in events) {
      _close(event.fd);
    }
    events.clear();
  }

  @override
  void close() {
    _closeAll(_userInstructions);
    _closeAll(_userCycles);
    _closeAll(_kernelInstructions);
    _closeAll(_kernelCycles);
    _free(_words.cast());
  }
}
