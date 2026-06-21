import 'dart:async';
import 'package:flutter_compass/flutter_compass.dart';

Stream<double>? getCompassHeadingStream() {
  return FlutterCompass.events?.map((event) => event.heading ?? 0.0);
}
