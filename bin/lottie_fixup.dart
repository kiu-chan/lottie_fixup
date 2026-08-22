// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:lottie_fixup/core.dart';

const _usage = '''
Dùng:
  dart run lottie_fixup diagnose <file.json> [file khác...]
  dart run lottie_fixup fix <file.json> [file khác...]

  diagnose  chỉ báo cáo vấn đề, không sửa file.
  fix       sửa tại chỗ: gỡ layer audio/precomp rỗng gây crash, bake loopOut().
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
    stderr.writeln('Lệnh không hợp lệ: $command\n');
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
      print('$path: không phát hiện vấn đề.');
      continue;
    }
    print('$path:');
    if (report.audioLayers > 0) {
      print('  - ${report.audioLayers} layer audio (ty=6) có thể gây crash');
    }
    if (report.emptyPrecomps > 0) {
      print('  - ${report.emptyPrecomps} precomp rỗng');
    }
    if (report.loopOutOccurrences > 0) {
      print('  - ${report.loopOutOccurrences} biểu thức loopOut() chưa bake');
    }
  }
}

void _runFix(List<String> paths) {
  for (final path in paths) {
    final file = File(path);
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final result = fix(doc);

    if (!result.changed) {
      print('$path: không có gì để sửa.');
      continue;
    }

    file.writeAsStringSync(jsonEncode(doc));

    final parts = <String>[];
    if (result.sanitize.audioLayersRemoved > 0) {
      parts.add('gỡ ${result.sanitize.audioLayersRemoved} layer audio');
    }
    if (result.sanitize.emptyPrecompsRemoved > 0) {
      parts.add('gỡ ${result.sanitize.emptyPrecompsRemoved} precomp rỗng');
    }
    if (result.sanitize.unreferencedAssetsRemoved > 0) {
      parts.add(
        'gỡ ${result.sanitize.unreferencedAssetsRemoved} asset không còn tham chiếu',
      );
    }
    if (result.bake.propertiesBaked > 0) {
      parts.add(
        'bake ${result.bake.propertiesBaked} thuộc tính (${result.bake.totalLoops} vòng lặp)',
      );
    }
    print('$path: ${parts.join(', ')}.');

    for (final expr in result.bake.skippedExpressions.toSet()) {
      print('  ! bỏ qua expression chưa hỗ trợ: $expr');
    }
    for (final warning in result.sanitize.layersMissingTransform) {
      print('  ! layer thiếu "ks" (transform), có thể vẫn crash: $warning');
    }
  }
}
