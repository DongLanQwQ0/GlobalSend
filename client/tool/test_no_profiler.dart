// Diagnostic entry point for the installed Flutter 3.47.2 test runner.
// Run using the SDK's flutter_tools package_config (not the app's config).
// This preserves TestCommand, FlutterTestRunner, test files and assertions;
// only the tester's CPU sampling profiler is disabled.
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_tools/runner.dart' as runner;
import 'package:flutter_tools/executable.dart' show LoggerFactory;
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_targets.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/test.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/hook_runner.dart';
import 'package:flutter_tools/src/build_system/targets/hook_runner_native.dart';
import 'package:flutter_tools/src/isolated/native_assets/test/native_assets.dart';
import 'package:flutter_tools/src/isolated/build_targets.dart';
import 'package:flutter_tools/src/isolated/mustache_template.dart';
import 'package:flutter_tools/src/native_assets.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/test/runner.dart';
import 'package:flutter_tools/src/test/test_time_recorder.dart';
import 'package:flutter_tools/src/test/test_wrapper.dart';
import 'package:flutter_tools/src/test/watcher.dart';

Future<void> main(List<String> args) async {
  Cache.flutterRoot = io.Platform.environment['FLUTTER_ROOT']!;
  await runner.run(
    ['--verbose', 'test', ...args],
    () => [
      TestCommand(
        verbose: true,
        testRunner: const _NoProfilerRunner(),
        nativeAssetsBuilder: globals.nativeAssetsBuilder,
      ),
    ],
    verbose: true,
    reportCrashes: false,
    shutdownHooks: globals.shutdownHooks,
    overrides: <Type, Generator>{
      FlutterHookRunner: () => FlutterHookRunnerNative(),
      TestCompilerNativeAssetsBuilder: () =>
          const TestCompilerNativeAssetsBuilderImpl(),
      TemplateRenderer: () => const MustacheTemplateRenderer(),
      BuildTargets: () => const BuildTargetsImpl(),
      Logger: () =>
          LoggerFactory(
            outputPreferences: globals.outputPreferences,
            terminal: globals.terminal,
            stdio: globals.stdio,
          ).createLogger(
            daemon: false,
            machine: false,
            verbose: true,
            prefixedErrors: false,
            windows: globals.platform.isWindows,
            widgetPreviews: false,
          ),
    },
  );
}

class _NoProfilerRunner implements FlutterTestRunner {
  const _NoProfilerRunner();

  @override
  Future<int> runTests(
    TestWrapper testWrapper,
    List<Uri> testFiles, {
    required DebuggingOptions debuggingOptions,
    List<String> names = const [],
    List<String> plainNames = const [],
    String? tags,
    String? excludeTags,
    bool enableVmService = false,
    bool machine = false,
    String? precompiledDillPath,
    Map<String, String>? precompiledDillFiles,
    bool updateGoldens = false,
    TestWatcher? watcher,
    required int? concurrency,
    String? testAssetDirectory,
    FlutterProject? flutterProject,
    String? icudtlPath,
    Directory? coverageDirectory,
    bool web = false,
    String? randomSeed,
    String? reporter,
    String? fileReporter,
    String? timeout,
    bool ignoreTimeouts = false,
    bool failFast = false,
    bool runSkipped = false,
    int? shardIndex,
    int? totalShards,
    Device? integrationTestDevice,
    String? integrationTestUserIdentifier,
    TestTimeRecorder? testTimeRecorder,
    TestCompilerNativeAssetsBuilder? nativeAssetsBuilder,
    required BuildInfo buildInfo,
  }) {
    // These are exactly the fields TestCommand supplies in this SDK. All other
    // fields retain the same enabled() defaults; the comparison below catches
    // drift instead of silently changing unrelated test settings.
    final original = debuggingOptions;
    final noProfiler = DebuggingOptions.enabled(
      original.buildInfo,
      startPaused: original.startPaused,
      disableServiceAuthCodes: original.disableServiceAuthCodes,
      disableServiceOriginCheck: original.disableServiceOriginCheck,
      disablePortPublication: original.disablePortPublication,
      enableDds: original.enableDds,
      usingCISystem: original.usingCISystem,
      enableImpeller: original.enableImpeller,
      enableFlutterGpu: original.enableFlutterGpu,
      debugLogsDirectoryPath: original.debugLogsDirectoryPath,
      webRenderer: original.webRenderer,
      webCrossOriginIsolation: original.webCrossOriginIsolation,
      printDtd: original.printDtd,
      webUseWasm: original.webUseWasm,
      enableHcpp: original.enableHcpp,
      uninstallApp: original.uninstallApp,
      enableDartProfiling: false,
    );
    final expected = original.toJson()..['enableDartProfiling'] = false;
    if (jsonEncode(expected) != jsonEncode(noProfiler.toJson()) ||
        original.testFlag != noProfiler.testFlag ||
        original.uninstallFirst != noProfiler.uninstallFirst ||
        original.iosProfileDebugger != noProfiler.iosProfileDebugger) {
      throw StateError(
        'SDK test options changed; diagnostic driver needs review.',
      );
    }
    globals.printStatus(
      'Diagnostic comparison: only enableDartProfiling=true -> false; '
      'all other TestCommand options unchanged.',
    );
    return const FlutterTestRunner().runTests(
      testWrapper,
      testFiles,
      debuggingOptions: noProfiler,
      names: names,
      plainNames: plainNames,
      tags: tags,
      excludeTags: excludeTags,
      enableVmService: enableVmService,
      machine: machine,
      precompiledDillPath: precompiledDillPath,
      precompiledDillFiles: precompiledDillFiles,
      updateGoldens: updateGoldens,
      watcher: watcher,
      concurrency: concurrency,
      testAssetDirectory: testAssetDirectory,
      flutterProject: flutterProject,
      icudtlPath: icudtlPath,
      coverageDirectory: coverageDirectory,
      web: web,
      randomSeed: randomSeed,
      reporter: reporter,
      fileReporter: fileReporter,
      timeout: timeout,
      ignoreTimeouts: ignoreTimeouts,
      failFast: failFast,
      runSkipped: runSkipped,
      shardIndex: shardIndex,
      totalShards: totalShards,
      integrationTestDevice: integrationTestDevice,
      integrationTestUserIdentifier: integrationTestUserIdentifier,
      testTimeRecorder: testTimeRecorder,
      nativeAssetsBuilder: nativeAssetsBuilder,
      buildInfo: buildInfo,
    );
  }

  // This narrow diagnostic entry point does not replace Flutter's experimental
  // multi-engine runner or silently turn it into a different kind of test.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Only the standard Flutter test runner is supported.',
  );
}
