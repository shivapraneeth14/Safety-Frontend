class AppConfig {
  static const bool isLocal = false;

  static String get baseUrl {
    if (isLocal) {
      return 'http://192.168.1.100:5001';
    }
    return 'https://safety-backend-m5n6.onrender.com';
  }

  static String get wsUrl {
    if (isLocal) {
      return 'ws://192.168.1.100:5001';
    }
    return 'wss://safety-backend-m5n6.onrender.com';
  }
}
