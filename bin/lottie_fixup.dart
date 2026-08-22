// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:lottie_fixup/core.dart';

const _usage = '''
Usage:
  dart run lottie_fixup diagnose [flags] <file.json> [other files...]
  dart run lottie_fixup fix [flags] <file.json> [other files...]

  diagnose  only reports issues, does not modify the file.
  fix       fixes in place: removes crashing audio layers/empty precomps, bakes loopOut()/loopIn().

Flags (each opts out of one approximation/judgment call in expression
baking; see BakeOptions in the library docs for details on each):
  --no-random-wiggle          Don't bake random()/wiggle() expressions.
  --no-keyframed-properties   Don't bake expressions on properties that already have real keyframes.
  --no-shape-path-wiggle      Don't bake wiggle() on a shape path's vertices.
  --no-approximate-easing     Don't bake ease()/easeIn()/easeOut() (linear() is unaffected).
''';

void main(List<String> args) {
  final paths = <String>[];
  var bakeRandomAndWiggle = true;
  var bakeOnKeyframedProperties = true;
  var bakeShapePathWiggle = true;
  var bakeApproximateEasing = true;

  if (args.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  final command = args.first;

  for (final arg in args.skip(1)) {
    switch (arg) {
      case '--no-random-wiggle':
        bakeRandomAndWiggle = false;
      case '--no-keyframed-properties':
        bakeOnKeyframedProperties = false;
      case '--no-shape-path-wiggle':
        bakeShapePathWiggle = false;
      case '--no-approximate-easing':
        bakeApproximateEasing = false;
      default:
        if (arg.startsWith('--')) {
          stderr.writeln('Unknown flag: $arg\n');
          stderr.writeln(_usage);
          exitCode = 64;
          return;
        }
        paths.add(arg);
    }
  }

  if (paths.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  final options = BakeOptions(
    bakeRandomAndWiggle: bakeRandomAndWiggle,
    bakeOnKeyframedProperties: bakeOnKeyframedProperties,
    bakeShapePathWiggle: bakeShapePathWiggle,
    bakeApproximateEasing: bakeApproximateEasing,
  );

  if (command == 'diagnose') {
    _runDiagnose(paths, options);
  } else if (command == 'fix') {
    _runFix(paths, options);
  } else {
    stderr.writeln('Invalid command: $command\n');
    stderr.writeln(_usage);
    exitCode = 64;
  }
}

void _runDiagnose(List<String> paths, BakeOptions options) {
  for (final path in paths) {
    final raw = File(path).readAsStringSync();
    final doc = jsonDecode(raw) as Map<String, dynamic>;
    final report = diagnose(raw, doc, options: options);

    if (!report.hasIssues) {
      print('$path: no issues detected.');
      continue;
    }
    print('$path:');
    if (report.audioLayers > 0) {
      print('  - ${report.audioLayers} audio layer(s) (ty=6) that may crash');
    }
    if (report.emptyPrecomps > 0) {
      print('  - ${report.emptyPrecomps} empty precomp(s)');
    }
    if (report.loopExpressionsToBake > 0) {
      print(
        '  - ${report.loopExpressionsToBake} unbaked loopOut()/loopIn() expression(s)',
      );
    }
    if (report.propertyExpressionsToBake > 0) {
      print(
        '  - ${report.propertyExpressionsToBake} unbaked property expression(s) '
        '(cross-layer link, time-based, random()/wiggle())',
      );
    }
    for (final expr in report.unsupportedExpressions.toSet()) {
      print('  ! unsupported expression, will be left as-is: $expr');
    }
  }
}

void _runFix(List<String> paths, BakeOptions options) {
  for (final path in paths) {
    final file = File(path);
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final result = fix(doc, options: options);

    if (!result.changed) {
      print('$path: nothing to fix.');
      continue;
    }

    file.writeAsStringSync(jsonEncode(doc));

    final parts = <String>[];
    if (result.sanitize.audioLayersRemoved > 0) {
      parts.add('removed ${result.sanitize.audioLayersRemoved} audio layer(s)');
    }
    if (result.sanitize.emptyPrecompsRemoved > 0) {
      parts.add(
        'removed ${result.sanitize.emptyPrecompsRemoved} empty precomp(s)',
      );
    }
    if (result.sanitize.unreferencedAssetsRemoved > 0) {
      parts.add(
        'removed ${result.sanitize.unreferencedAssetsRemoved} unreferenced asset(s)',
      );
    }
    if (result.bake.propertiesBaked > 0) {
      parts.add(
        'baked ${result.bake.propertiesBaked} propert(y/ies) (${result.bake.totalLoops} loop(s))',
      );
    }
    if (result.propertyBake.propertiesBaked > 0) {
      parts.add(
        'baked ${result.propertyBake.propertiesBaked} property expression(s)',
      );
    }
    print('$path: ${parts.join(', ')}.');

    for (final expr in result.propertyBake.skippedExpressions.toSet()) {
      print('  ! skipped unsupported expression: $expr');
    }
    for (final warning in result.sanitize.layersMissingTransform) {
      print('  ! layer missing "ks" (transform), may still crash: $warning');
    }
  }
}
