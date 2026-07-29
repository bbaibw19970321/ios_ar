import 'package:flutter/material.dart';
import 'ar_measure_page.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '测距测面积1',
      theme: ThemeData.dark(),
      home: const ARMeasurePage(),
    );
  }
}