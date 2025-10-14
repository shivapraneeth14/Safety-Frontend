import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _formKey = GlobalKey<FormState>();
  String username = '', email = '', password = '', phoneNumber = '';
  bool loading = false;

  Future<void> registerUser() async {
    setState(() => loading = true);

    final response = await http.post(
      Uri.parse("https://safety-backend-m5n6.onrender.com/api/register"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "username": username,
        "email": email,
        "password": password,
        "phoneNumber": phoneNumber,
      }),
    );

    setState(() => loading = false);
    final data = jsonDecode(response.body);

    if (response.statusCode == 201) {
      Navigator.pushReplacementNamed(context, '/login');
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Sign Up")),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    decoration: InputDecoration(labelText: "Username"),
                    onChanged: (val) => username = val,
                    validator: (val) => val!.isEmpty ? "Enter username" : null,
                  ),
                  TextFormField(
                    decoration: InputDecoration(labelText: "Email"),
                    onChanged: (val) => email = val,
                    validator: (val) => val!.isEmpty ? "Enter email" : null,
                  ),
                  TextFormField(
                    decoration: InputDecoration(labelText: "Password"),
                    obscureText: true,
                    onChanged: (val) => password = val,
                    validator: (val) => val!.isEmpty ? "Enter password" : null,
                  ),
                  TextFormField(
                    decoration: InputDecoration(labelText: "Phone Number"),
                    onChanged: (val) => phoneNumber = val,
                  ),
                  SizedBox(height: 20),
                  loading
                      ? CircularProgressIndicator()
                      : ElevatedButton(
                          onPressed: () {
                            if (_formKey.currentState!.validate()) {
                              registerUser();
                            }
                          },
                          child: Text("Sign Up"),
                        ),
                ],
              ),
            ),
            SizedBox(height: 20),
            TextButton(
              onPressed: () {
                Navigator.pushReplacementNamed(context, '/login');
              },
              child: Text("Already have an account? Login"),
            ),
          ],
        ),
      ),
    );
  }
}
