import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'sdk.dart';

/// The result of compiling a benchmark source file for a specific target.
final class const CompilationResult({
  /// Whether the compilation exited successfully with code 0.
  required final bool success,

  /// The target runtime compiled for.
  required final TargetRuntime runtime,

  /// The original Dart source file path.
  required final String sourcePath,

  /// The primary output binary or bytecode artifact path (e.g. `.exe`, `.wasm`,
  /// `.js`), or the source file path for JIT.
  final String? artifactPath,

  /// The runner script path (e.g. `.mjs` for Wasm, `.js` for JavaScript), or
  /// `null` if the artifact is directly executable.
  final String? runnerScriptPath,

  /// Total time spent compiling.
  required final Duration compilationDuration,

  /// Subprocess standard output stream from the compiler.
  required final String stdout,

  /// Subprocess standard error stream from the compiler.
  required final String stderr,

  /// Subprocess exit code.
  required final int exitCode,

  /// Whether this result was served from the compilation cache.
  final bool cacheHit = false,
}) {
  @override
  String toString() =>
      'CompilationResult($runtime, success: $success, '
      'artifact: $artifactPath, '
      'cacheHit: $cacheHit, '
      'duration: ${compilationDuration.inMilliseconds}ms)';
}

/// Orchestrates compilation of Dart benchmark source files into native, Wasm,
/// and JavaScript artifacts.
final class const TargetCompiler({final DartSdk sdk = const DartSdk()}) {
  /// Compiles [sourceFile] for [runtime] into [outputDir].
  ///
  /// For [TargetRuntime.jit], no compilation is performed and an immediate
  /// success [CompilationResult] pointing to [sourceFile] is returned.
  Future<CompilationResult> compile({
    required File sourceFile,
    required TargetRuntime runtime,
    Directory? outputDir,
    List<String> compilerFlags = const [],
    String? workingDirectory,
    bool useCache = true,
  }) async {
    final normalizedSource = p.normalize(sourceFile.absolute.path);

    final sdkError = sdk.explicitSdkError;
    if (sdkError != null) {
      return CompilationResult(
        success: false,
        runtime: runtime,
        sourcePath: normalizedSource,
        compilationDuration: Duration.zero,
        stdout: '',
        stderr: sdkError,
        exitCode: 1,
      );
    }

    if (runtime == TargetRuntime.jit) {
      return CompilationResult(
        success: true,
        runtime: runtime,
        sourcePath: normalizedSource,
        artifactPath: normalizedSource,
        runnerScriptPath: null,
        compilationDuration: Duration.zero,
        stdout: '',
        stderr: '',
        exitCode: 0,
      );
    }

    final targetDir =
        outputDir ??
        Directory(p.join('.dart_tool', 'bench_press', 'build', runtime.name));
    await targetDir.create(recursive: true);

    final dartExe = sdk.dartExecutable;
    if (dartExe == null) {
      return CompilationResult(
        success: false,
        runtime: runtime,
        sourcePath: normalizedSource,
        compilationDuration: Duration.zero,
        stdout: '',
        stderr: 'Error: Dart SDK executable not found on PATH or DART_SDK.',
        exitCode: 1,
      );
    }

    // `dart compile exe` leaves out the code assets of build hooks, so a
    // package graph with hooks is built as a `dart build cli` bundle.
    final hooked = runtime == TargetRuntime.aot
        ? packagesWithHooks(_packageConfigPath(workingDirectory))
        : const <String>[];
    if (hooked.isNotEmpty && compilerFlags.isNotEmpty) {
      return CompilationResult(
        success: false,
        runtime: runtime,
        sourcePath: normalizedSource,
        compilationDuration: Duration.zero,
        stdout: '',
        stderr:
            'Error: `dart build cli` takes no compiler flags '
            '(${compilerFlags.join(' ')}), and `dart compile exe` cannot '
            'build with the build hooks of ${hooked.join(', ')}.',
        exitCode: 1,
      );
    }

    final baseName = p.basenameWithoutExtension(sourceFile.path);
    final (args, artifactPath, runnerPath) = _buildCompilerArgs(
      runtime: runtime,
      sourcePath: normalizedSource,
      outputDir: targetDir.path,
      baseName: baseName,
      extraFlags: compilerFlags,
      buildCli: hooked.isNotEmpty,
    );
    // A hook rebuilds its assets from sources this cache does not see, and
    // `dart build cli` keeps a cache of its own for them.
    useCache = useCache && hooked.isEmpty;

    final expectedRunnerPath = switch (runtime) {
      TargetRuntime.wasm => p.normalize(
        p.join(targetDir.path, '$baseName.run.mjs'),
      ),
      TargetRuntime.js => p.normalize(
        p.join(targetDir.path, '$baseName.node.cjs'),
      ),
      _ => runnerPath,
    };

    final currentManifest = _computeCacheManifest(
      sourceFile: sourceFile,
      runtime: runtime,
      compilerFlags: compilerFlags,
      dartExe: dartExe,
      workingDirectory: workingDirectory,
    );
    final cacheKeyFile = File('$artifactPath.cache_key');

    if (useCache &&
        File(artifactPath).existsSync() &&
        (expectedRunnerPath == null || File(expectedRunnerPath).existsSync()) &&
        (runnerPath == null || File(runnerPath).existsSync()) &&
        cacheKeyFile.existsSync() &&
        cacheKeyFile.readAsStringSync() == currentManifest) {
      return CompilationResult(
        success: true,
        runtime: runtime,
        sourcePath: normalizedSource,
        artifactPath: artifactPath,
        runnerScriptPath: expectedRunnerPath,
        compilationDuration: Duration.zero,
        stdout: '',
        stderr: '',
        exitCode: 0,
        cacheHit: true,
      );
    }

    final stopwatch = Stopwatch()..start();
    try {
      final processResult = await Process.run(
        dartExe,
        args,
        workingDirectory: workingDirectory,
      );
      stopwatch.stop();

      final success = processResult.exitCode == 0;
      if (success) {
        _writeRunnerIfNeeded(
          runtime: runtime,
          outputDir: targetDir.path,
          baseName: baseName,
          runnerPath: runnerPath,
        );
        if (hooked.isEmpty) cacheKeyFile.writeAsStringSync(currentManifest);
      }

      return CompilationResult(
        success: success,
        runtime: runtime,
        sourcePath: normalizedSource,
        artifactPath: success ? artifactPath : null,
        runnerScriptPath: success ? expectedRunnerPath : null,
        compilationDuration: stopwatch.elapsed,
        stdout: processResult.stdout.toString(),
        stderr: processResult.stderr.toString(),
        exitCode: processResult.exitCode,
      );
    } on Object catch (e) {
      stopwatch.stop();
      return CompilationResult(
        success: false,
        runtime: runtime,
        sourcePath: normalizedSource,
        compilationDuration: stopwatch.elapsed,
        stdout: '',
        stderr: 'Compiler execution failed: $e',
        exitCode: 1,
      );
    }
  }

  void _writeRunnerIfNeeded({
    required TargetRuntime runtime,
    required String outputDir,
    required String baseName,
    required String? runnerPath,
  }) {
    if (runtime == TargetRuntime.wasm) {
      _writeWasmRunner(
        outputDir: outputDir,
        baseName: baseName,
        loaderPath: runnerPath!,
      );
    } else if (runtime == TargetRuntime.js) {
      // `dart compile js` output assumes a browser (or worker) global scope and
      // feature-detects microtask/timer scheduling off the bare `self` global —
      // present in browsers/workers, absent in Node.js. Any benchmark that
      // genuinely suspends on `await` (not just trampolines through synchronous
      // work) hits that scheduler, throws `ReferenceError: self is not
      // defined`, and the resulting rejected Future is dropped silently (no
      // crash, no telemetry).
      //
      // Separately, the compiled output invokes `main` with a hardcoded empty
      // arguments array (`dartMainRunner(s,[])`) — CLI args like `--target js`
      // or `--trials N` never reach Dart's `main(args)` no matter what's passed
      // on the command line. `dartMainRunner` is dart2js's documented embedder
      // hook for this: if defined as a global before the compiled script runs,
      // dart2js calls it instead of invoking `main` directly, letting us supply
      // the real args ourselves.
      //
      // `.node.cjs` is used instead of `.node.js` so Node.js treats the script
      // unconditionally as CommonJS, even inside packages configured with
      // `"type": "module"`.
      final compiledFileName = p.basename(runnerPath!);
      final jsRunnerPath = p.normalize(p.join(outputDir, '$baseName.node.cjs'));
      final encodedCompiledFile = jsonEncode('./$compiledFileName');
      File(jsRunnerPath).writeAsStringSync('''
process.on('unhandledRejection', (err) => {
  console.error(err);
  process.exit(1);
});

if (typeof self === 'undefined') {
  globalThis.self = globalThis;
}
globalThis.dartMainRunner = (main, _ignoredArgs) => {
  try {
    main(process.argv.slice(2));
  } catch (err) {
    console.error(err);
    process.exit(1);
  }
};
require($encodedCompiledFile);
''');
    }
  }

  String _computeCacheManifest({
    required File sourceFile,
    required TargetRuntime runtime,
    required List<String> compilerFlags,
    required String dartExe,
    String? workingDirectory,
  }) {
    final buffer = StringBuffer()
      ..writeln('runtime:${runtime.name}')
      ..writeln('dartExe:$dartExe');

    void addFileStat(String label, File file) {
      if (!file.existsSync()) return;
      try {
        final stat = file.statSync();
        buffer.writeln(
          '$label:${stat.modified.microsecondsSinceEpoch}:${stat.size}',
        );
      } on FileSystemException {
        // Ignore inaccessible files.
      }
    }

    addFileStat('dartExeStat', File(dartExe));
    for (final flag in compilerFlags) {
      buffer.writeln('flag:$flag');
    }

    final baseDir = workingDirectory ?? Directory.current.path;
    addFileStat('pkgConfig', File(_packageConfigPath(workingDirectory)));

    final dartFiles = <String, File>{
      p.normalize(sourceFile.absolute.path): sourceFile,
    };
    _collectDartFiles(Directory(p.join(baseDir, 'lib')), dartFiles);
    _collectDartFiles(sourceFile.parent, dartFiles);
    // The sources of path dependencies change in place, as the benchmark's
    // own do. A package in the pub cache changes only with the package
    // configuration.
    final roots = _packageRoots(_packageConfigPath(workingDirectory));
    for (final root in roots.values) {
      if (_isInPubCache(root)) continue;
      _collectDartFiles(Directory(p.join(root, 'lib')), dartFiles);
    }

    final sortedPaths = dartFiles.keys.toList()..sort();
    for (final path in sortedPaths) {
      addFileStat(path, dartFiles[path]!);
    }

    return buffer.toString();
  }

  /// The package configuration a compilation in [workingDirectory] resolves
  /// against.
  String _packageConfigPath(String? workingDirectory) =>
      sdk.packageConfigPath ??
      p.join(
        workingDirectory ?? Directory.current.path,
        '.dart_tool',
        'package_config.json',
      );

  /// The names of the packages in the package configuration at
  /// [packageConfigPath] that have a build or link hook, sorted.
  ///
  /// Empty when the file is missing or is not a package configuration.
  @visibleForTesting
  static List<String> packagesWithHooks(String packageConfigPath) {
    final hooked = <String>[];
    for (final MapEntry(key: name, value: root) in _packageRoots(
      packageConfigPath,
    ).entries) {
      if (File(p.join(root, 'hook', 'build.dart')).existsSync() ||
          File(p.join(root, 'hook', 'link.dart')).existsSync()) {
        hooked.add(name);
      }
    }
    return hooked..sort();
  }

  /// The root directory of every package in the package configuration at
  /// [packageConfigPath], by package name.
  ///
  /// Empty when the file is missing or is not a package configuration.
  static Map<String, String> _packageRoots(String packageConfigPath) {
    final file = File(packageConfigPath);
    if (!file.existsSync()) return const {};
    final Object? config;
    try {
      config = jsonDecode(file.readAsStringSync());
    } on FormatException {
      return const {};
    }
    if (config is! Map<String, Object?>) return const {};
    final packages = config['packages'];
    if (packages is! List<Object?>) return const {};
    final roots = <String, String>{};
    for (final package in packages) {
      if (package is! Map<String, Object?>) continue;
      final name = package['name'];
      final rootUri = package['rootUri'];
      if (name is! String || rootUri is! String) continue;
      // A relative root is relative to the directory of the configuration.
      final root = file.absolute.uri.resolve(
        rootUri.endsWith('/') ? rootUri : '$rootUri/',
      );
      if (root.scheme != 'file') continue;
      roots[name] = p.normalize(root.toFilePath());
    }
    return roots;
  }

  /// Whether [path] lies in a pub cache: under `PUB_CACHE`, or under a
  /// directory with one of the names a pub cache has (`.pub-cache`,
  /// `pub_cache`, `Pub\Cache`).
  static bool _isInPubCache(String path) {
    final configured = Platform.environment['PUB_CACHE'];
    if (configured != null &&
        configured.isNotEmpty &&
        p.isWithin(configured, path)) {
      return true;
    }
    final segments = [for (final s in p.split(path)) s.toLowerCase()];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment == '.pub-cache' ||
          segment == 'pub_cache' ||
          segment == 'pub-cache') {
        return true;
      }
      if (segment == 'pub' &&
          i + 1 < segments.length &&
          segments[i + 1] == 'cache') {
        return true;
      }
    }
    return false;
  }

  void _collectDartFiles(Directory dir, Map<String, File> out) {
    if (!dir.existsSync()) return;
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          out[p.normalize(entity.absolute.path)] = entity;
        }
      }
    } on FileSystemException {
      // Ignore inaccessible directories.
    }
  }

  /// `dart compile wasm` emits a bare loader module (`compile`/
  /// `compileStreaming` exports) — running it directly with Node does
  /// nothing, since nothing in it calls `instantiate`/`invokeMain`. Node.js
  /// benchmarks need that boilerplate wired up explicitly, so this writes a
  /// small `.run.mjs` next to the loader that does the compile → instantiate
  /// → invokeMain dance and forwards CLI args, and returns its path for use
  /// as the actual runner script.
  String _writeWasmRunner({
    required String outputDir,
    required String baseName,
    required String loaderPath,
  }) {
    final wasmFileName = '$baseName.wasm';
    final loaderFileName = p.basename(loaderPath);
    final runnerPath = p.normalize(p.join(outputDir, '$baseName.run.mjs'));
    final encodedLoaderFile = jsonEncode(loaderFileName);
    final encodedWasmFile = jsonEncode(wasmFileName);
    File(runnerPath).writeAsStringSync('''
import { readFile } from 'node:fs/promises';

process.on('unhandledRejection', (err) => {
  console.error(err);
  process.exit(1);
});

try {
  const init = await import(new URL($encodedLoaderFile, import.meta.url).href);
  const bytes = await readFile(new URL($encodedWasmFile, import.meta.url));
  const compiledApp = await init.compile(bytes);
  const instantiatedApp = await compiledApp.instantiate({});
  await instantiatedApp.invokeMain(...process.argv.slice(2));
} catch (err) {
  console.error(err);
  process.exit(1);
}
''');
    return runnerPath;
  }

  (List<String> args, String artifactPath, String? runnerPath)
  _buildCompilerArgs({
    required TargetRuntime runtime,
    required String sourcePath,
    required String outputDir,
    required String baseName,
    required List<String> extraFlags,
    bool buildCli = false,
  }) {
    final pkgConfig = sdk.packageConfigPath;
    final pkgFlag = pkgConfig != null ? ['--packages=$pkgConfig'] : <String>[];

    switch (runtime) {
      case TargetRuntime.jit:
        return (<String>[], sourcePath, null);

      case TargetRuntime.aot when buildCli:
        // `dart build cli` writes `bundle/bin/<name>` with the hooks' code
        // assets in `bundle/lib/` beside it.
        final exeExt = Platform.isWindows ? '.exe' : '';
        final bundleParent = p.normalize(p.join(outputDir, baseName));
        final outPath = p.join(
          bundleParent,
          'bundle',
          'bin',
          '$baseName$exeExt',
        );
        final args = <String>[
          'build',
          'cli',
          ...pkgFlag,
          '--target',
          sourcePath,
          '--output',
          bundleParent,
        ];
        return (args, outPath, null);

      case TargetRuntime.aot:
        final exeExt = Platform.isWindows ? '.exe' : '';
        final outPath = p.normalize(p.join(outputDir, '$baseName$exeExt'));
        final args = <String>[
          'compile',
          'exe',
          ...pkgFlag,
          ...extraFlags,
          sourcePath,
          '-o',
          outPath,
        ];
        return (args, outPath, null);

      case TargetRuntime.wasm:
        final wasmPath = p.normalize(p.join(outputDir, '$baseName.wasm'));
        final mjsPath = p.normalize(p.join(outputDir, '$baseName.mjs'));
        final args = <String>[
          'compile',
          'wasm',
          ...pkgFlag,
          ...extraFlags,
          sourcePath,
          '-o',
          wasmPath,
        ];
        return (args, wasmPath, mjsPath);

      case TargetRuntime.js:
        final jsPath = p.normalize(p.join(outputDir, '$baseName.js'));
        final args = <String>[
          'compile',
          'js',
          ...pkgFlag,
          '-O4',
          ...extraFlags,
          sourcePath,
          '-o',
          jsPath,
        ];
        return (args, jsPath, jsPath);
    }
  }
}
