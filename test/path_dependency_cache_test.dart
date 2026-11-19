@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  test('bench_press run -t aot rebuilds a cached executable when a path '
      'dependency changes, and only then', () async {
    final repository = Directory.current.path;
    await d.dir('dep', [
      d.file('pubspec.yaml', '''
name: dep
publish_to: none
environment:
  sdk: ^3.13.0
'''),
      d.dir('lib', [d.file('dep.dart', 'int work() => 1;')]),
    ]).create();
    await d.dir('app', [
      d.file('pubspec.yaml', '''
name: app
publish_to: none
environment:
  sdk: ^3.13.0
dependencies:
  bench_press:
    path: ${jsonEncode(repository)}
  dep:
    path: ../dep
'''),
      d.dir('benchmark', [
        d.file('dep_benchmark.dart', '''
import 'package:bench_press/bench_press.dart';
import 'package:dep/dep.dart';

final class Work() extends Benchmark {
  this : super('work');

  @override
  void run() => Blackhole.consume(work());
}

void main(List<String> args) => mainBenchmark(Work(), args);
'''),
      ]),
    ]).create();
    final app = d.path('app');
    final get = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
    ], workingDirectory: app);
    check(because: '${get.stdout}\n${get.stderr}', get.exitCode).equals(0);

    Future<DateTime> runAot() async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bench_press',
        'run',
        '-t',
        'aot',
        '--no-save',
        '--trials',
        '2',
        'benchmark/',
      ], workingDirectory: app);
      check(
        because: '${result.stdout}\n${result.stderr}',
        result.exitCode,
      ).equals(0);
      return File(
        p.join(
          app,
          '.dart_tool',
          'bench_press',
          'build',
          'aot',
          Platform.isWindows ? 'dep_benchmark.exe' : 'dep_benchmark',
        ),
      ).lastModifiedSync();
    }

    final first = await runAot();
    final unchanged = await runAot();
    // File times have a resolution of a second on some file systems.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    File(p.join(d.sandbox, 'dep', 'lib', 'dep.dart'))
        .writeAsStringSync('int work() => 20 + 22;');
    final changed = await runAot();

    check(unchanged).equals(first);
    check(changed.isAfter(first)).isTrue;
  }, timeout: const Timeout(Duration(minutes: 5)));
}
