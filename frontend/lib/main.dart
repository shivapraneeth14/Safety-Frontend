import 'package:flutter/material.dart';
import 'Pages/login_page.dart';
import 'Pages/signup_page.dart';
import 'Pages/main_layout.dart'; // 👈 Import this

void main() {
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
