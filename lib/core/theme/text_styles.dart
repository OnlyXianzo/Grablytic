import 'package:flutter/material.dart';

extension GrablyticTextStyles on TextTheme {
  TextStyle get mono => const TextStyle(
    fontFamily: 'IosevkaCharonMono',
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
  );
}
