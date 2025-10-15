import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  double _rotation = 0.0;
  final double _currentZoom = 17.0;
  
  // Threat markers rendered as red dots
  List<Marker> _threatMarkers = [];

  StreamSubscription<Position>? _positionStream;
  StreamSubscription<CompassEvent>? _compassStream;
  StreamSubscription<AccelerometerEvent>? _accelStream;
  StreamSubscription<GyroscopeEvent>? _gyroStream;
  StreamSubscription<MagnetometerEvent>? _magStream;
  StreamSubscription<List<ConnectivityResult>>? _connectivityStream;

  ConnectivityResult _connectivityStatus = ConnectivityResult.none;
  LatLng? _fusedPosition;
  DateTime? _lastTimestamp;
  double? _lastSpeed;
  double? _lastHeading;

  AccelerometerEvent? _lastAccel;
  GyroscopeEvent? _lastGyro;
  MagnetometerEvent? _lastMag;

  final String backendWsUrl = "wss://safety-backend-m5n6.onrender.com";
  WebSocketChannel? _ws;
  Timer? _sendTimer;

  Map<String, dynamic>? user;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await fetchUserProfile();
      _initLocation();
      _initConnectivity();
      _initCompass();
      _initSensors();
      _initWebSocket();
    });
  }

  Future<void> fetchUserProfile() async {
    print("fetchUserProfile: started");
    setState(() => isLoading = true);

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('accessToken');

    if (token == null) {
      print("fetchUserProfile: No token found");
      setState(() {
        user = null;
        isLoading = false;
      });
      return;
    }

    final url = Uri.parse(
      "https://safety-backend-m5n6.onrender.com/api/current",
    );

    try {
      final response = await http.get(
        url,
        headers: {
          "Authorization": "Bearer $token",
          "Accept": "application/json",
        },
      );

      print("fetchUserProfile: Response status=${response.statusCode}");
      print("fetchUserProfile: Response body=${response.body}");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          user = data['user'];
          isLoading = false;
        });
        print("fetchUserProfile: User data loaded successfully");
      } else if (response.statusCode == 401) {
        print("fetchUserProfile: Unauthorized, token may be expired");
        setState(() {
          user = null;
          isLoading = false;
        });
      } else {
        print(
          "fetchUserProfile: Unexpected status code ${response.statusCode}",
        );
        setState(() {
          user = null;
          isLoading = false;
        });
      }
    } catch (e) {
      print("fetchUserProfile: Exception caught -> $e");
      setState(() {
        user = null;
        isLoading = false;
      });
    }
  }

  Future<void> _initLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint("⚠️ Location services disabled.");
      return;
    }
    LocationPermission permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      debugPrint("⚠️ Location permission denied.");
      return;
    }

    Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.best,
    );
    _updatePosition(position, initial: true);

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 1,
      ),
    ).listen((pos) => _updatePosition(pos));
  }

  void _updatePosition(Position pos, {bool initial = false}) {
    _currentPosition = LatLng(pos.latitude, pos.longitude);
    try {
      if (mounted) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            _mapController.move(_currentPosition!, _currentZoom);
            debugPrint(
              '📍 Map Updated at: ${_currentPosition!.latitude}, ${_currentPosition!.longitude}',
            );
          }
        });
      }
    } catch (e) {
      debugPrint('⚠️ Map not ready yet: $e');
    }

    _lastTimestamp = pos.timestamp ?? DateTime.now();
    _lastSpeed = pos.speed;
    _lastHeading = pos.heading;

    _applyFusion(pos);
    setState(() {});
  }

  void _applyFusion(Position gps) {
    final now = gps.timestamp ?? DateTime.now();
    if (_fusedPosition == null) {
      _fusedPosition = LatLng(gps.latitude, gps.longitude);
      return;
    }

    double dt = _lastTimestamp != null
        ? (now.difference(_lastTimestamp!).inMilliseconds / 1000.0)
        : 0.0;

    if (_lastSpeed != null && _lastHeading != null && dt > 0) {
      double headingRad = _lastHeading! * pi / 180.0;
      double dx = _lastSpeed! * dt * sin(headingRad);
      double dy = _lastSpeed! * dt * cos(headingRad);
      const metersPerDegLat = 111320.0;
      final metersPerDegLon =
          metersPerDegLat * cos(_fusedPosition!.latitude * pi / 180.0);
      final dLat = dy / metersPerDegLat;
      final dLon = dx / (metersPerDegLon == 0 ? 1 : metersPerDegLon);
      LatLng deadReckon = LatLng(
        _fusedPosition!.latitude + dLat,
        _fusedPosition!.longitude + dLon,
      );
      const alpha = 0.85;
      double fusedLat =
          alpha * gps.latitude + (1 - alpha) * deadReckon.latitude;
      double fusedLon =
          alpha * gps.longitude + (1 - alpha) * deadReckon.longitude;
      _fusedPosition = LatLng(fusedLat, fusedLon);
    }
  }

  void _initCompass() {
    _compassStream = FlutterCompass.events?.listen((event) {
      if (event.heading != null) _rotation = event.heading!;
    });
  }

  void _initSensors() {
    _accelStream = accelerometerEvents.listen((e) => _lastAccel = e);
    _gyroStream = gyroscopeEvents.listen((e) => _lastGyro = e);
    _magStream = magnetometerEvents.listen((e) => _lastMag = e);
  }

  void _initConnectivity() {
    final conn = Connectivity();
    conn.checkConnectivity().then((res) => _onConnectivity(res));
    _connectivityStream = conn.onConnectivityChanged.listen(_onConnectivity);
  }

  void _onConnectivity(List<ConnectivityResult> results) {
    _connectivityStatus = results.first;
  }

  // ======================
  // WebSocket + Data Sender
  // ======================
  void _initWebSocket() {
    if (backendWsUrl.trim().isEmpty) {
      debugPrint('❌ WebSocket URL is empty');
      return;
    }
    try {
      _ws = WebSocketChannel.connect(Uri.parse(backendWsUrl));
      debugPrint('🔗 Connecting to WebSocket: $backendWsUrl');

      _ws!.stream.listen(
        (msg) {
          debugPrint('📥 WS Message: $msg');
          _handleWsMessage(msg);
        },
      
        onDone: () => debugPrint('ℹ️ WebSocket closed'),
        onError: (e) => debugPrint('❌ WebSocket error: $e'),
      );

      // Start sending data every second
      _sendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _sendWebSocket();
      });

      debugPrint('✅ WebSocket connected successfully');
    } catch (e) {
      debugPrint('❌ WebSocket connection failed: $e');
    }
  }

  void _handleWsMessage(dynamic msg) {
    try {
      final String text = msg is String ? msg : msg.toString();
      final dynamic payload = jsonDecode(text);

      // Expecting either { type: 'threats', positions: [ {id, lat, lng}, ... ] }
      // or a direct { threats: [ {id, lat, lng}, ... ] }
      final bool isThreatsType = payload is Map && payload['type'] == 'threats';
      final List<dynamic> positions =
          (payload is Map && payload['positions'] is List)
              ? (payload['positions'] as List)
              : (payload is Map && payload['threats'] is List)
                  ? (payload['threats'] as List)
                  : const [];

      if (isThreatsType || positions.isNotEmpty) {
        final List<Marker> markers = [];
        for (final p in positions) {
          if (p is! Map) continue;
          final num? latNum = p['lat'] as num?;
          final num? lngNum = p['lng'] as num?;
          if (latNum == null || lngNum == null) continue;

          markers.add(
            Marker(
              point: LatLng(latNum.toDouble(), lngNum.toDouble()),
              width: 18,
              height: 18,
              child: const Icon(
                Icons.circle,
                color: Colors.red,
                size: 12,
              ),
            ),
          );
        }

        if (mounted) {
          setState(() {
            _threatMarkers = markers;
          });
        }
      }
    } catch (e) {
      // ignore malformed messages
    }
  }

  void _sendWebSocket() {
    if (_ws == null || _fusedPosition == null) {
      debugPrint('⚠️ Cannot send — WebSocket or position not ready.');
      return;
    }

    final payload = {
      "userId": user?['_id'],
      "latitude": _fusedPosition!.latitude,
      "longitude": _fusedPosition!.longitude,
      "speed": _lastSpeed,
      "heading": _lastHeading,
      "accel": _lastAccel != null
          ? {"x": _lastAccel!.x, "y": _lastAccel!.y, "z": _lastAccel!.z}
          : null,
      "gyro": _lastGyro != null
          ? {"x": _lastGyro!.x, "y": _lastGyro!.y, "z": _lastGyro!.z}
          : null,
      "magnetometer": _lastMag != null
          ? {"x": _lastMag!.x, "y": _lastMag!.y, "z": _lastMag!.z}
          : null,
      "connectivity": _connectivityStatus.toString(),
      "timestamp": DateTime.now().toIso8601String(),
    };

    debugPrint("📤 Sending WebSocket data...");
    debugPrint(jsonEncode(payload));

    try {
      _ws!.sink.add(jsonEncode(payload));
      debugPrint("✅ Data sent successfully at ${DateTime.now()}");
    } catch (e) {
      debugPrint("❌ Failed to send data: $e");
    }
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _compassStream?.cancel();
    _accelStream?.cancel();
    _gyroStream?.cancel();
    _magStream?.cancel();
    _connectivityStream?.cancel();
    _sendTimer?.cancel();
    _ws?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _currentPosition == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(),
                  children: [
                    TileLayer(
                      urlTemplate:
                          "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                      userAgentPackageName: 'com.example.frontend',
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _currentPosition!,
                          width: 60,
                          height: 60,
                          rotate: true,
                          child: Transform.rotate(
                            angle: -_rotation * pi / 180,
                            child: const Icon(
                              Icons.navigation,
                              color: Colors.blue,
                              size: 45,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Threat markers layer (red dots)
                    if (_threatMarkers.isNotEmpty)
                      MarkerLayer(
                        markers: _threatMarkers,
                      ),
                  ],
                ),
                Positioned(
                  bottom: 20,
                  right: 20,
                  child: FloatingActionButton(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    onPressed: () {
                      if (_currentPosition != null) {
                        _mapController.move(_currentPosition!, _currentZoom);
                        debugPrint('🎯 Centered map to current location');
                      }
                    },
                    child: const Icon(Icons.my_location),
                  ),
                ),
              ],
            ),
    );
  }
}
