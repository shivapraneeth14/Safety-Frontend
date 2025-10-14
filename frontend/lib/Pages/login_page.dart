import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  String loginname = '', password = '';
  bool loading = false;

  Future<void> loginUser() async {
    setState(() => loading = true);

    final response = await http.post(
      Uri.parse("https://safety-backend-m5n6.onrender.com/api/Login"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"loginname": loginname, "password": password}),
    );

    setState(() => loading = false);
    final data = jsonDecode(response.body);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("accessToken", data['accessToken']);
    await prefs.setString("refreshToken", data['refreshToken']);

    print("Saved AccessToken: ${prefs.getString("accessToken")}");

    if (response.statusCode == 200) {
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Login")),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    decoration: InputDecoration(labelText: "Username or Email"),
                    onChanged: (val) => loginname = val,
                    validator: (val) =>
                        val!.isEmpty ? "Enter username/email" : null,
                  ),
                  TextFormField(
                    decoration: InputDecoration(labelText: "Password"),
                    obscureText: true,
                    onChanged: (val) => password = val,
                    validator: (val) => val!.isEmpty ? "Enter password" : null,
                  ),
                  SizedBox(height: 20),
                  loading
                      ? CircularProgressIndicator()
                      : ElevatedButton(
                          onPressed: () {
                            if (_formKey.currentState!.validate()) {
                              loginUser();
                            }
                          },
                          child: Text("Login"),
                        ),
                ],
              ),
            ),
            SizedBox(height: 20),
            TextButton(
              onPressed: () {
                Navigator.pushReplacementNamed(context, '/signup');
              },
              child: Text("Don't have an account? Sign Up"),
            ),
          ],
        ),
      ),
    );
  }
}
