// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:lottie_fixup/lottie_fixup.dart';

void main(List<String> args) {
  final path = args.isNotEmpty ? args.first : 'animation.json';
  final file = File(path);
  final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  final result = fix(doc);
  if (!result.changed) {
    print('Nothing to fix.');
    return;
  }

  file.writeAsStringSync(jsonEncode(doc));
  print('Removed ${result.sanitize.audioLayersRemoved} audio layer(s), '
      'baked ${result.bake.propertiesBaked} looping propertie(s).');
}
