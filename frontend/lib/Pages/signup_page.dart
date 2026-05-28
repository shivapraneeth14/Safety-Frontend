import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../Config/app_config.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _formKey = GlobalKey<FormState>();
  String username = '', email = '', password = '', phoneNumber = '';
  bool loading = false;
  bool obscurePassword = true; // 👁️ toggle

  Future<void> registerUser() async {
    setState(() => loading = true);

    final response = await http.post(
      Uri.parse("${AppConfig.baseUrl}/api/register"),
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
      backgroundColor: Colors.grey[100],
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Card(
              elevation: 10,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_add, size: 60),
                      SizedBox(height: 10),
                      Text(
                        "Create Account",
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 20),

                      TextFormField(
                        decoration: InputDecoration(
                          labelText: "Username",
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onChanged: (val) => username = val,
                        validator: (val) =>
                            val!.isEmpty ? "Enter username" : null,
                      ),

                      SizedBox(height: 15),

                      TextFormField(
                        decoration: InputDecoration(
                          labelText: "Email",
                          prefixIcon: Icon(Icons.email_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onChanged: (val) => email = val,
                        validator: (val) =>
                            val!.isEmpty ? "Enter email" : null,
                      ),

                      SizedBox(height: 15),

                      TextFormField(
                        obscureText: obscurePassword,
                        decoration: InputDecoration(
                          labelText: "Password",
                          prefixIcon: Icon(Icons.lock_outline),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () {
                              setState(() {
                                obscurePassword = !obscurePassword;
                              });
                            },
                          ),
                        ),
                        onChanged: (val) => password = val,
                        validator: (val) =>
                            val!.isEmpty ? "Enter password" : null,
                      ),

                      SizedBox(height: 15),

                      TextFormField(
                        decoration: InputDecoration(
                          labelText: "Phone Number",
                          prefixIcon: Icon(Icons.phone_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onChanged: (val) => phoneNumber = val,
                      ),

                      SizedBox(height: 22),

                      loading
                          ? CircularProgressIndicator()
                          : SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  padding:
                                      EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () {
                                  if (_formKey.currentState!.validate()) {
                                    registerUser();
                                  }
                                },
                                child: Text("Sign Up"),
                              ),
                            ),

                      SizedBox(height: 10),

                      TextButton(
                        onPressed: () {
                          Navigator.pushReplacementNamed(context, '/login');
                        },
                        child: Text("Already have an account? Login"),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
