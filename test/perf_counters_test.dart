@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:bench_press/bench_press.dart';
import 'package:bench_press/src/counters/perf_counters_native.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

int _burn(int iterations) {
  var x = 0;
  for (var i = 0; i < iterations; i++) {
    x += i & 7;
  }
  return x;
}

/// The counters of [pids], or null after marking the test skipped where the
/// machine has none.
PerfCounters? _open({List<int>? pids, bool kernel = false}) {
  String? reason;
  final counters = PerfCounters.open(
    pids: pids,
    kernel: kernel,
    onUnavailable: (r) => reason = r,
  );
  if (counters == null) {
    markTestSkipped('No hardware counters: $reason');
    return null;
  }
  addTearDown(counters.close);
  return counters;
}

Future<Process> _busyProcess() async {
  final process = await Process.start('sh', ['-c', 'while :; do :; done']);
  addTearDown(process.kill);
  return process;
}

void main() {
  group('PerfCounters', () {
    test('counts the instructions and cycles of a loop in this process', () {
      final counters = _open();
      if (counters == null) return;

      final before = counters.read();
      Blackhole.consume(_burn(10000000));
      final after = counters.read();

      check(after.instructions - before.instructions).isGreaterThan(10000000);
      check(after.cycles).isGreaterThan(before.cycles);
    });

    test('counts another process', () async {
      final process = await _busyProcess();
      final counters = _open(pids: [process.pid]);
      if (counters == null) return;

      final before = counters.read();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final after = counters.read();

      check(after.instructions).isGreaterThan(before.instructions);
      check(after.cycles).isGreaterThan(before.cycles);
    });

    test('keeps the totals of a process that has exited', () async {
      final process = await _busyProcess();
      final counters = _open(pids: [process.pid]);
      if (counters == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final running = counters.read();

      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      final exited = counters.read();

      check(exited.instructions).isGreaterOrEqual(running.instructions);
      check(exited.cycles).isGreaterOrEqual(running.cycles);
    });

    test('names its source and the modes it counts', () {
      final counters = _open();
      if (counters == null) return;

      check(counters.source)
          .equals(Platform.isMacOS ? 'proc_pid_rusage' : 'perf_event_open');
      check(counters.modes).equals(Platform.isMacOS ? 'user+kernel' : 'user');
    });

    test('splits kernel mode off where the platform does', () {
      final counters = _open(kernel: true);
      if (counters == null) return;

      final reading = counters.read();

      if (Platform.isMacOS) {
        check(reading.kernelInstructions).isNull;
        check(reading.kernelCycles).isNull;
      } else {
        // Null where the process may count user mode only.
        check(reading.kernelInstructions)
            .anyOf([.it()..isNull, .it()..isNotNull().isGreaterOrEqual(0)]);
      }
    });

    test('gives the reason when a process cannot be counted', () {
      String? reason;

      final counters = PerfCounters.open(
        pids: const [0x7ffffff0],
        onUnavailable: (r) => reason = r,
      );

      check(counters).isNull;
      check(reason).isNotNull().isNotEmpty;
    });
  });

  // perf_event_open with the software clocks in place of the hardware
  // events, which a virtual machine without a PMU still has.
  group('perf_event_open with software clocks', () {
    PerfCounters? open({List<int>? pids, bool kernel = false}) {
      String? reason;
      final counters = openPerfCounters(
        pids: pids,
        kernel: kernel,
        onUnavailable: (r) => reason = r,
        softwareClocks: true,
      );
      if (counters == null) {
        markTestSkipped('perf_event_open is not usable: $reason');
        return null;
      }
      addTearDown(counters.close);
      return counters;
    }

    test('counts the CPU time of a loop in this process', () {
      final counters = open();
      if (counters == null) return;

      final watch = Stopwatch()..start();
      final before = counters.read();
      Blackhole.consume(_burn(200000000));
      final after = counters.read();
      final wallNs = watch.elapsedMicroseconds * 1000;

      // The loop holds one CPU. Other threads of the process only add.
      check(after.instructions - before.instructions)
          .isGreaterThan(wallNs ~/ 2);
      check(after.cycles).isGreaterThan(before.cycles);
    });

    test('counts a thread started after the counters opened', () async {
      final counters = open();
      if (counters == null) return;

      final before = counters.read();
      final watch = Stopwatch()..start();
      await Isolate.run(() => _burn(400000000));
      final isolateNs = watch.elapsedMicroseconds * 1000;
      final after = counters.read();

      check(after.instructions - before.instructions)
          .isGreaterThan(isolateNs ~/ 2);
    });

    test(
      'counts another process and keeps its totals after it exits',
      () async {
        final process = await _busyProcess();
        final counters = open(pids: [process.pid]);
        if (counters == null) return;

        final before = counters.read();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final after = counters.read();
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        final exited = counters.read();

        check(after.instructions - before.instructions)
            .isGreaterThan(100 * 1000 * 1000);
        check(exited.instructions).isGreaterOrEqual(after.instructions);
      },
    );

    test('counts kernel mode apart when permitted', () {
      final counters = open(kernel: true);
      if (counters == null) return;

      final file = File('/dev/urandom').openSync();
      addTearDown(file.closeSync);
      final before = counters.read();
      for (var i = 0; i < 50; i++) {
        file.readSync(1 << 20);
      }
      final after = counters.read();

      final kernelBefore = before.kernelInstructions;
      final kernelAfter = after.kernelInstructions;
      if (kernelBefore == null || kernelAfter == null) {
        markTestSkipped('Kernel mode is not permitted here');
        return;
      }
      check(kernelAfter).isGreaterThan(kernelBefore);
    });
  }, testOn: 'linux');
}
