import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:lottie_fixup/lottie_fixup.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Lottie.asset(
            'assets/raw_export.json',
            decoder: fixupLottieDecoder,
          ),
        ),
      ),
    );
  }
}
