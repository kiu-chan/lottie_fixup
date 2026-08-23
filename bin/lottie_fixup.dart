// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:lottie_fixup/core.dart';

const _usage = '''
Usage:
  dart run lottie_fixup diagnose [flags] <file.json> [other files...]
  dart run lottie_fixup fix [flags] <file.json> [other files...]

  diagnose  only reports issues, does not modify the file.
  fix       fixes in place: removes/repairs crashing layers, assets, masks,
            and shape content, bakes loopOut()/loopIn() and other expressions.

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
    if (report.sanitize.precompLayersWithBadRefRemoved > 0) {
      print(
        '  - ${report.sanitize.precompLayersWithBadRefRemoved} precomp '
        'layer(s) with an unresolvable refId that may crash',
      );
    }
    if (report.sanitize.textLayersMissingDataRemoved > 0) {
      print(
        '  - ${report.sanitize.textLayersMissingDataRemoved} text layer(s) '
        'missing document data that may crash',
      );
    }
    if (report.sanitize.assetsMissingIdRemoved > 0) {
      print(
        '  - ${report.sanitize.assetsMissingIdRemoved} asset(s) with no '
        'usable id that may crash',
      );
    }
    if (report.sanitize.maskEntriesRemoved > 0) {
      print(
        '  - ${report.sanitize.maskEntriesRemoved} malformed mask '
        'entrie(s) that may crash',
      );
    }
    if (report.sanitize.malformedShapeContentRemoved > 0) {
      print(
        '  - ${report.sanitize.malformedShapeContentRemoved} malformed '
        'gradient/stroke shape item(s) that may crash',
      );
    }
    if (report.sanitize.invalidStrokeCapsOrJoinsFixed > 0) {
      print(
        '  - ${report.sanitize.invalidStrokeCapsOrJoinsFixed} stroke(s) '
        'with an out-of-range cap/join value',
      );
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
    for (final warning in report.sanitize.layersMissingTransform) {
      print('  ! layer missing "ks" (transform), may still crash: $warning');
    }
    for (final warning in report.sanitize.propertiesWithEmptyKeyframes) {
      print(
        '  ! animatable value with no keyframes, may still crash: $warning',
      );
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
    } else {
      file.writeAsStringSync(jsonEncode(doc));

      final parts = <String>[];
      if (result.sanitize.audioLayersRemoved > 0) {
        parts.add(
          'removed ${result.sanitize.audioLayersRemoved} audio layer(s)',
        );
      }
      if (result.sanitize.emptyPrecompsRemoved > 0) {
        parts.add(
          'removed ${result.sanitize.emptyPrecompsRemoved} empty precomp(s)',
        );
      }
      if (result.sanitize.unreferencedAssetsRemoved > 0) {
        parts.add(
          'removed ${result.sanitize.unreferencedAssetsRemoved} '
          'unreferenced asset(s)',
        );
      }
      if (result.sanitize.precompLayersWithBadRefRemoved > 0) {
        parts.add(
          'removed ${result.sanitize.precompLayersWithBadRefRemoved} '
          'precomp layer(s) with an unresolvable refId',
        );
      }
      if (result.sanitize.textLayersMissingDataRemoved > 0) {
        parts.add(
          'removed ${result.sanitize.textLayersMissingDataRemoved} text '
          'layer(s) missing document data',
        );
      }
      if (result.sanitize.assetsMissingIdRemoved > 0) {
        parts.add(
          'removed ${result.sanitize.assetsMissingIdRemoved} asset(s) with '
          'no usable id',
        );
      }
      if (result.sanitize.maskEntriesRemoved > 0) {
        parts.add(
          'removed ${result.sanitize.maskEntriesRemoved} malformed mask '
          'entrie(s)',
        );
      }
      if (result.sanitize.malformedShapeContentRemoved > 0) {
        parts.add(
          'removed ${result.sanitize.malformedShapeContentRemoved} '
          'malformed gradient/stroke shape item(s)',
        );
      }
      if (result.sanitize.invalidStrokeCapsOrJoinsFixed > 0) {
        parts.add(
          'fixed ${result.sanitize.invalidStrokeCapsOrJoinsFixed} stroke(s) '
          'with an out-of-range cap/join value',
        );
      }
      if (result.bake.propertiesBaked > 0) {
        parts.add(
          'baked ${result.bake.propertiesBaked} propert(y/ies) '
          '(${result.bake.totalLoops} loop(s))',
        );
      }
      if (result.propertyBake.propertiesBaked > 0) {
        parts.add(
          'baked ${result.propertyBake.propertiesBaked} property '
          'expression(s)',
        );
      }
      print('$path: ${parts.join(', ')}.');
    }

    // Printed regardless of whether anything was actually changed above --
    // these are all diagnostics fix() never touches (see SanitizeResult's
    // docs on why each is report-only), so a file with nothing else to fix
    // can still have one of these worth a human looking at.
    for (final expr in result.propertyBake.skippedExpressions.toSet()) {
      print('  ! skipped unsupported expression: $expr');
    }
    for (final warning in result.sanitize.layersMissingTransform) {
      print('  ! layer missing "ks" (transform), may still crash: $warning');
    }
    for (final warning in result.sanitize.propertiesWithEmptyKeyframes) {
      print(
        '  ! animatable value with no keyframes, may still crash: $warning',
      );
    }
  }
}
