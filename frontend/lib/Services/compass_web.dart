import 'dart:async';
import 'dart:html' as html;

Stream<double>? getCompassHeadingStream() {
  final controller = StreamController<double>.broadcast();
  html.window.onDeviceOrientation.listen((event) {
    if (event.alpha != null) {
      controller.add(event.alpha!.toDouble());
    }
  });
  return controller.stream;
}
