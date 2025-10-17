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
  bool _userHasInteracted = false;
  bool _hasCompassHeading = false;
  // Smoothed heading we actually render (degrees 0..360)
  double _displayHeadingDeg = 0.0;
  // Source selector: when moving use GPS course; when stationary use compass
  bool _usingGpsCourse = false;
  // User calibration offset, applied to heading (degrees, can be negative)
  double _calibrationOffsetDeg = -42.0;
  
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
  
  // Status indicators
  bool _isConnected = false;
  bool _isSendingData = false;
  DateTime? _lastDataSent;
  String _connectionStatus = 'Connecting...';
  
  // Data viewer
  bool _showDataViewer = false;
  Map<String, dynamic>? _lastSentData;

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
      // Using fixed calibration set in code
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
        print("User ID: ${user?['_id']}");
        print("User name: ${user?['name'] ?? 'Unknown'}");
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
    debugPrint("📍 Initializing location services...");
    
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    debugPrint("📍 Location service enabled: $serviceEnabled");
    if (!serviceEnabled) {
      debugPrint("⚠️ Location services disabled.");
      return;
    }
    
    LocationPermission permission = await Geolocator.requestPermission();
    debugPrint("📍 Location permission: $permission");
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      debugPrint("⚠️ Location permission denied: $permission");
      return;
    }

    Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    _updatePosition(position, initial: true);

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0, // No distance filter for web accuracy
      ),
    ).listen((pos) => _updatePosition(pos));
  }

  void _updatePosition(Position pos, {bool initial = false}) {
    _currentPosition = LatLng(pos.latitude, pos.longitude);
    
    // For web, use GPS directly without fusion to avoid drift
    _fusedPosition = _currentPosition;
    
    // Only auto-center the map during initial location fetch or if user hasn't interacted yet
    try {
      if (mounted && (initial || !_userHasInteracted)) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            _mapController.move(_currentPosition!, _currentZoom);
            debugPrint(
              '📍 Map Updated at: ${_currentPosition!.latitude}, ${_currentPosition!.longitude}',
            );
          }
        });
      } else {
        debugPrint(
          '📍 Location Updated (no auto-center): ${_currentPosition!.latitude}, ${_currentPosition!.longitude}',
        );
      }
    } catch (e) {
      debugPrint('⚠️ Map not ready yet: $e');
    }

    _lastTimestamp = pos.timestamp ?? DateTime.now();
    _lastSpeed = pos.speed;
    _lastHeading = pos.heading;
    _updateHeadingFromSources();

    // Skip fusion on web to prevent location drift
    // _applyFusion(pos);
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
      if (event.heading != null) {
        _hasCompassHeading = true;
        _rotation = event.heading!; // raw compass degrees
        _updateHeadingFromSources();
        if (mounted) setState(() {});
      }
    });
  }

  // Decide which heading to use and smooth it for display
  void _updateHeadingFromSources() {
    // Normalize helper to 0..360
    double normalize(double d) {
      double n = d % 360.0;
      if (n < 0) n += 360.0;
      return n;
    }

    double? gpsCourseDeg = (_lastHeading != null && _lastHeading! >= 0)
        ? normalize(_lastHeading!)
        : null;

    double? compassDeg = _hasCompassHeading ? normalize(_rotation) : null;

    // If moving > ~2.5 m/s (~9 km/h), prefer GPS course as it's usually more stable while driving
    final bool movingFast = (_lastSpeed ?? 0) > 2.5;
    double? chosen;
    if (movingFast && gpsCourseDeg != null) {
      _usingGpsCourse = true;
      chosen = gpsCourseDeg;
    } else if (compassDeg != null) {
      _usingGpsCourse = false;
      chosen = compassDeg;
    } else if (gpsCourseDeg != null) {
      _usingGpsCourse = true;
      chosen = gpsCourseDeg;
    }

    if (chosen == null) return;

    // Apply user calibration offset before smoothing
    chosen = normalize(chosen + _calibrationOffsetDeg);

    // Smooth with exponential moving average to reduce jitter
    const double alpha = 0.25; // higher = more responsive, lower = smoother
    // Handle wrap-around (e.g., 359 to 1 should average across 0)
    double current = _displayHeadingDeg;
    double delta = chosen - current;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    double next = current + alpha * delta;
    _displayHeadingDeg = normalize(next);
  }

  // Calibration persistence disabled; using fixed offset above

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
    _connectWebSocket();
  }

  void _connectWebSocket() {
    try {
      _ws?.sink.close(); // Close existing connection if any
      _ws = WebSocketChannel.connect(Uri.parse(backendWsUrl));
      debugPrint('🔗 Connecting to WebSocket: $backendWsUrl');

      _ws!.stream.listen(
        (msg) {
          debugPrint('📥 WS Message: $msg');
          _handleWsMessage(msg);
          setState(() {
            _isConnected = true;
            _connectionStatus = 'Connected';
          });
        },
      
        onDone: () {
          debugPrint('ℹ️ WebSocket closed - attempting to reconnect...');
          setState(() {
            _isConnected = false;
            _connectionStatus = 'Reconnecting...';
          });
          _reconnectWebSocket();
        },
        onError: (e) {
          debugPrint('❌ WebSocket error: $e - attempting to reconnect...');
          setState(() {
            _isConnected = false;
            _connectionStatus = 'Connection Error';
          });
          _reconnectWebSocket();
        },
      );

      // Start sending data every second
      _sendTimer?.cancel();
      _sendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _sendWebSocket();
      });

      debugPrint('✅ WebSocket connected successfully');
      setState(() {
        _isConnected = true;
        _connectionStatus = 'Connected';
      });
    } catch (e) {
      debugPrint('❌ WebSocket connection failed: $e - will retry...');
      _reconnectWebSocket();
    }
  }

  void _reconnectWebSocket() {
    Timer(const Duration(seconds: 3), () {
      debugPrint('🔄 Attempting to reconnect WebSocket...');
      _connectWebSocket();
    });
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
      debugPrint('❌ Failed to parse WebSocket message: $e');
      debugPrint('Raw message: $msg');
    }
  }

  void _sendWebSocket() {
    if (_ws == null || _fusedPosition == null) {
      debugPrint('⚠️ Cannot send — WebSocket or position not ready.');
      return;
    }

    // Ensure userId is available before sending
    if (user?['_id'] == null) {
      debugPrint('⚠️ Cannot send — User ID not available.');
      debugPrint('User object: $user');
      return;
    }
    
    debugPrint('👤 User ID: ${user!['_id']}');
    debugPrint('🌍 Position: ${_fusedPosition!.latitude}, ${_fusedPosition!.longitude}');

    // WebSocket connection will be checked in the try-catch block below

    final payload = {
      "userId": user!['_id'],
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
      setState(() {
        _isSendingData = true;
      });
      
      _ws!.sink.add(jsonEncode(payload));
      _lastDataSent = DateTime.now();
      _lastSentData = payload; // Store the data for viewing
      
      setState(() {
        _isSendingData = false;
      });
      
      debugPrint("✅ Data sent successfully at ${DateTime.now()}");
    } catch (e) {
      setState(() {
        _isSendingData = false;
        _isConnected = false;
        _connectionStatus = 'Send Error';
      });
      debugPrint("❌ Failed to send data: $e - attempting to reconnect...");
      _reconnectWebSocket();
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
                // Status Bar at the top
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: SafeArea(
                      child: Row(
                        children: [
                          // Connection Status
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: _isConnected ? Colors.green : Colors.red,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isConnected ? Icons.wifi : Icons.wifi_off,
                                  color: Colors.white,
                                  size: 16,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _connectionStatus,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Data Transmission Indicator
                          if (_isSendingData)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.blue,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                    ),
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    'Sending...',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Spacer(),
                          // User Info
                          if (user != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'ID: ${user!['_id']?.toString().substring(0, 8) ?? 'Unknown'}...',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          const SizedBox(width: 8),
                          // Last Data Sent
                          if (_lastDataSent != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.8),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '✓ ${_lastDataSent!.toString().substring(11, 19)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          const SizedBox(width: 8),
                          // Heading Indicator (fixed calibration; controls removed)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.explore, color: Colors.white, size: 14),
                                const SizedBox(width: 4),
                                Text(
                                  '${_displayHeadingDeg.toStringAsFixed(0)}° ${_usingGpsCourse ? 'gps' : (_hasCompassHeading ? 'compass' : 'n/a')} (+42°)',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Map with top padding for status bar
                Positioned(
                  top: 80, // Space for status bar
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      onTap: (tapPosition, point) {
                        _userHasInteracted = true;
                      },
                      onPointerDown: (event, point) {
                        _userHasInteracted = true;
                      },
                      onPointerUp: (event, point) {
                        _userHasInteracted = true;
                      },
                    ),
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
                          rotate: false,
                          child: AnimatedRotation(
                            turns: ((_displayHeadingDeg % 360) / 360),
                            duration: const Duration(milliseconds: 150),
                            curve: Curves.easeOut,
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
                ),
                // My Location Button
                Positioned(
                  bottom: 20,
                  right: 20,
                  child: FloatingActionButton(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    onPressed: () {
                      if (_currentPosition != null) {
                        _userHasInteracted = false; // Reset flag to allow auto-centering again
                        _mapController.move(_currentPosition!, _currentZoom);
                        debugPrint('🎯 Centered map to current location');
                      }
                    },
                    child: const Icon(Icons.my_location),
                  ),
                ),
                // Data Viewer Button
                Positioned(
                  bottom: 90,
                  right: 20,
                  child: FloatingActionButton(
                    backgroundColor: _showDataViewer ? Colors.blue : Colors.white,
                    foregroundColor: _showDataViewer ? Colors.white : Colors.black,
                    onPressed: () {
                      setState(() {
                        _showDataViewer = !_showDataViewer;
                      });
                    },
                    child: Icon(_showDataViewer ? Icons.close : Icons.data_usage),
                  ),
                ),
                // Data Viewer Overlay
                if (_showDataViewer)
                  Positioned(
                    top: 100,
                    left: 20,
                    right: 20,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Header
                          Row(
                            children: [
                              const Icon(Icons.data_usage, color: Colors.white),
                              const SizedBox(width: 8),
                              const Text(
                                'Data Being Sent',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                onPressed: () {
                                  setState(() {
                                    _showDataViewer = false;
                                  });
                                },
                                icon: const Icon(Icons.close, color: Colors.white),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Data Content
                          if (_lastSentData != null) ...[
                            _buildDataItem('User ID', _lastSentData!['userId']?.toString() ?? 'N/A'),
                            _buildDataItem('Latitude', _lastSentData!['latitude']?.toString() ?? 'N/A'),
                            _buildDataItem('Longitude', _lastSentData!['longitude']?.toString() ?? 'N/A'),
                            _buildDataItem('Speed', _lastSentData!['speed']?.toString() ?? 'N/A'),
                            _buildDataItem('Heading', _lastSentData!['heading']?.toString() ?? 'N/A'),
                            _buildDataItem('Connectivity', _lastSentData!['connectivity']?.toString() ?? 'N/A'),
                            _buildDataItem('Timestamp', _lastSentData!['timestamp']?.toString() ?? 'N/A'),
                            // Sensor data
                            if (_lastSentData!['accel'] != null)
                              _buildDataItem('Accelerometer', 'X: ${_lastSentData!['accel']['x']?.toStringAsFixed(2)}, Y: ${_lastSentData!['accel']['y']?.toStringAsFixed(2)}, Z: ${_lastSentData!['accel']['z']?.toStringAsFixed(2)}'),
                            if (_lastSentData!['gyro'] != null)
                              _buildDataItem('Gyroscope', 'X: ${_lastSentData!['gyro']['x']?.toStringAsFixed(4)}, Y: ${_lastSentData!['gyro']['y']?.toStringAsFixed(4)}, Z: ${_lastSentData!['gyro']['z']?.toStringAsFixed(4)}'),
                            if (_lastSentData!['magnetometer'] != null)
                              _buildDataItem('Magnetometer', 'X: ${_lastSentData!['magnetometer']['x']?.toStringAsFixed(2)}, Y: ${_lastSentData!['magnetometer']['y']?.toStringAsFixed(2)}, Z: ${_lastSentData!['magnetometer']['z']?.toStringAsFixed(2)}'),
                          ] else ...[
                            const Text(
                              'No data sent yet',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                          const SizedBox(height: 16),
                          // Action Buttons
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    // Clear all stored data
                                    setState(() {
                                      _lastSentData = null;
                                    });
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Data cleared from display'),
                                        backgroundColor: Colors.green,
                                      ),
                                    );
                                  },
                                  icon: const Icon(Icons.clear_all),
                                  label: const Text('Clear Data'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    // Copy data to clipboard
                                    if (_lastSentData != null) {
                                      // You can implement clipboard functionality here
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Data copied to clipboard'),
                                          backgroundColor: Colors.blue,
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.copy),
                                  label: const Text('Copy'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blue,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildDataItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(
                color: Colors.cyan,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}