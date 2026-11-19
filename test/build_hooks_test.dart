@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bench_press/src/cli/compiler.dart';
import 'package:bench_press/src/cli/sdk.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

String _packageConfig(Map<String, String> roots) => jsonEncode({
  'configVersion': 2,
  'packages': [
    for (final MapEntry(:key, :value) in roots.entries)
      {'name': key, 'rootUri': value, 'packageUri': 'lib/'},
  ],
});

void main() {
  group('TargetCompiler.packagesWithHooks', () {
    test('names the packages with a build or link hook, sorted', () async {
      await d.dir('app', [
        d.dir('.dart_tool', [
          d.file(
            'package_config.json',
            _packageConfig({
              'plain': '../../plain',
              'linked': '../../linked',
              'built': Uri.directory(d.path('built')).toString(),
              'app': '../',
            }),
          ),
        ]),
      ]).create();
      await d.dir('plain', [
        d.dir('lib', [d.file('plain.dart', '')]),
      ]).create();
      await d.dir('built', [
        d.dir('hook', [d.file('build.dart', 'void main() {}')]),
      ]).create();
      await d.dir('linked', [
        d.dir('hook', [d.file('link.dart', 'void main() {}')]),
      ]).create();

      final hooked = TargetCompiler.packagesWithHooks(
        d.path(p.join('app', '.dart_tool', 'package_config.json')),
      );

      check(hooked).deepEquals(['built', 'linked']);
    });

    test('finds none in a graph without hooks', () async {
      await d.dir('app', [
        d.dir('.dart_tool', [
          d.file('package_config.json', _packageConfig({'app': '../'})),
        ]),
      ]).create();

      check(
        TargetCompiler.packagesWithHooks(
          d.path(p.join('app', '.dart_tool', 'package_config.json')),
        ),
      ).isEmpty();
    });

    test('finds none without a package configuration', () async {
      await d.file('package_config.json', 'not json').create();

      check(TargetCompiler.packagesWithHooks(d.path('missing.json'))).isEmpty();
      check(TargetCompiler.packagesWithHooks(d.path('package_config.json')))
          .isEmpty();
    });
  });

  group('bench_press run -t aot with a build hook in the graph', () {
    /// A package `app` whose dependency `hooked` has a build hook, and one
    /// benchmark in it.
    Future<String> createHookedPackage() async {
      final repository = Directory.current.path;
      await d.dir('hooked', [
        d.file('pubspec.yaml', '''
name: hooked
publish_to: none
environment:
  sdk: ^3.13.0
dependencies:
  hooks: ^2.0.0
'''),
        d.dir('hook', [
          d.file('build.dart', '''
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {});
}
'''),
        ]),
        d.dir('lib', [d.file('hooked.dart', 'int hooked() => 42;')]),
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
  hooked:
    path: ../hooked
'''),
        d.dir('benchmark', [
          d.file('hooked_benchmark.dart', '''
import 'package:bench_press/bench_press.dart';
import 'package:hooked/hooked.dart';

final class Hooked() extends Benchmark {
  this : super('hooked');

  @override
  void run() => Blackhole.consume(hooked());
}

void main(List<String> args) => mainBenchmark(Hooked(), args);
'''),
        ]),
      ]).create();
      final app = d.path('app');
      final get = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'get',
      ], workingDirectory: app);
      check(because: '${get.stdout}\n${get.stderr}', get.exitCode).equals(0);
      return app;
    }

    Future<ProcessResult> benchPress(String app, List<String> args) =>
        Process.run(Platform.resolvedExecutable, [
          'run',
          'bench_press',
          'run',
          '-t',
          'aot',
          '--no-save',
          '--trials',
          '2',
          ...args,
          'benchmark/',
        ], workingDirectory: app);

    test('builds a dart build cli bundle and runs it', () async {
      final app = await createHookedPackage();

      final result = await benchPress(app, const []);

      check(
        because: '${result.stdout}\n${result.stderr}',
        result.exitCode,
      ).equals(0);
      check(result.stdout as String).contains('| hooked | `aot` |');
      final executable = Platform.isWindows
          ? 'hooked_benchmark.exe'
          : 'hooked_benchmark';
      check(
        File(
          p.join(
            app,
            '.dart_tool',
            'bench_press',
            'build',
            'aot',
            'hooked_benchmark',
            'bundle',
            'bin',
            executable,
          ),
        ).existsSync(),
      ).isTrue();
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
      'refuses compiler flags, which dart build cli does not take',
      () async {
        final app = await createHookedPackage();

        final result = await benchPress(app, const ['--compiler-flag=-O2']);

        check('${result.stdout}\n${result.stderr}').contains(
          '`dart build cli` takes no compiler flags (-O2), and '
          '`dart compile exe` cannot build with the build hooks of hooked.',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  test('an AOT build without hooks in the graph is a dart compile exe '
      'executable', () async {
    await d.file('plain_bench.dart', '''
import 'package:bench_press/bench_press.dart';

void main(List<String> args) => mainBenchmarkSuite([], args);
''').create();

    const compiler = TargetCompiler();
    final result = await compiler.compile(
      sourceFile: File(d.path('plain_bench.dart')),
      runtime: TargetRuntime.aot,
      outputDir: Directory(d.path('out')),
    );

    check(because: result.stderr, result.success).isTrue();
    check(result.artifactPath).equals(
      p.normalize(
        d.path(
          p.join('out', Platform.isWindows ? 'plain_bench.exe' : 'plain_bench'),
        ),
      ),
    );
  });
}
