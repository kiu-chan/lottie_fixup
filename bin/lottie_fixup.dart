// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:lottie_fixup/core.dart';

const _usage = '''
Usage:
  dart run lottie_fixup diagnose <file.json> [other files...]
  dart run lottie_fixup fix <file.json> [other files...]

  diagnose  only reports issues, does not modify the file.
  fix       fixes in place: removes crashing audio layers/empty precomps, bakes loopOut()/loopIn().
''';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  final command = args.first;
  final paths = args.skip(1).toList();

  if (command == 'diagnose') {
    _runDiagnose(paths);
  } else if (command == 'fix') {
    _runFix(paths);
  } else {
    stderr.writeln('Invalid command: $command\n');
    stderr.writeln(_usage);
    exitCode = 64;
  }
}

void _runDiagnose(List<String> paths) {
  for (final path in paths) {
    final raw = File(path).readAsStringSync();
    final doc = jsonDecode(raw) as Map<String, dynamic>;
    final report = diagnose(raw, doc);

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
    for (final expr in report.unsupportedExpressions.toSet()) {
      print('  ! unsupported expression, will be left as-is: $expr');
    }
  }
}

void _runFix(List<String> paths) {
  for (final path in paths) {
    final file = File(path);
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final result = fix(doc);

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
    print('$path: ${parts.join(', ')}.');

    for (final expr in result.bake.skippedExpressions.toSet()) {
      print('  ! skipped unsupported expression: $expr');
    }
    for (final warning in result.sanitize.layersMissingTransform) {
      print('  ! layer missing "ks" (transform), may still crash: $warning');
    }
  }
}
