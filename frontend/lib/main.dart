import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'Pages/login_page.dart';
import 'Pages/signup_page.dart';
import 'Pages/main_layout.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    Hive.init('');
  } else {
    await Hive.initFlutter();
  }
  try {
    await Hive.openBox('roadCache');
  } catch (e) {
    debugPrint('⚠️ Failed to open Hive box on web: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Auth Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      initialRoute: '/login',
      routes: {
        '/login': (_) => const LoginPage(),
        '/signup': (_) => const SignupPage(),
        '/home': (_) => const MainLayout(currentIndex: 0), // 👈 Home tab
        '/profile': (_) => const MainLayout(currentIndex: 1), // 👈 Profile tab
      },
    );
  }
}
