import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../Config/app_config.dart';

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
  double _calibrationOffsetDeg = 0.0;

  // Road matching (map-matching) state
  bool _onRoad = false;
  LatLng? _snappedPosition;
  double? _roadHeadingDeg;
  List<dynamic>? _cachedRoadData;
  DateTime? _cachedRoadDataTime;

  // Threat markers rendered as red dots
  List<Marker> _threatMarkers = [];
  // Active threats for banners
  List<Map<String, dynamic>> _activeThreats = [];
  Timer? _clearThreatTimer;

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

  // Turn detection state (frontend only)
  Map<String, dynamic>?
  _turnInfo; // { exists, type, distance, intersectionLat, intersectionLng }
  DateTime? _lastTurnCheckTime;
  LatLng? _lastTurnCheckPosition;

  // Upcoming turns from backend cone query
  List<Map<String, dynamic>> _upcomingTurns = [];
  Map<String, dynamic>? _currentRoadInfo;

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
      "${AppConfig.baseUrl}/api/current",
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

    // Set raw GPS as initial fused position; sensor fusion may modify it below
    _fusedPosition = LatLng(pos.latitude, pos.longitude);

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
    _matchToRoad(pos.latitude, pos.longitude);
    _updateHeadingFromSources();

    // FIX BUG #12: Sensor fusion enabled for Android/iOS
    // Uses gyroscope + accelerometer + heading to augment GPS
    if (_lastGyro != null) {
      _applyFusion(pos);
    }

    // Trigger a turn-check when position changes significantly (rate-limited)
    _maybeScheduleTurnCheck();

    setState(() {});
  }

  // FIX BUG #12: Sensor fusion with gyroscope heading correction
  void _applyFusion(Position gps) {
    final now = gps.timestamp ?? DateTime.now();
    if (_fusedPosition == null) {
      _fusedPosition = LatLng(gps.latitude, gps.longitude);
      _lastTimestamp = now;
      return;
    }

    double dt = _lastTimestamp != null
        ? (now.difference(_lastTimestamp!).inMilliseconds / 1000.0)
        : 0.0;
    _lastTimestamp = now;

    if (dt > 0.05 && dt < 5.0) { // Sanity check time delta
      // Use gyroscope to adjust heading if available
      double effectiveHeading = _lastHeading ?? 0;
      if (_lastGyro != null && _lastGyro!.z.abs() > 0.1) {
        // Gyro gives rad/s, convert to degrees
        final gyroDeg = _lastGyro!.z * (180 / pi) * dt;
        effectiveHeading = (effectiveHeading + gyroDeg) % 360;
        if (effectiveHeading < 0) effectiveHeading += 360;
      }

      if (_lastSpeed != null && _lastSpeed! > 0.5 && effectiveHeading >= 0) {
        double headingRad = effectiveHeading * pi / 180.0;
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
        // Complementary filter: trust GPS more at high speeds, dead reckoning more at low speeds
        final alpha = _lastSpeed! > 5 ? 0.9 : 0.7;
        double fusedLat =
            alpha * gps.latitude + (1 - alpha) * deadReckon.latitude;
        double fusedLon =
            alpha * gps.longitude + (1 - alpha) * deadReckon.longitude;
        _fusedPosition = LatLng(fusedLat, fusedLon);
        return;
      }
    }
    // Fallback to raw GPS
    _fusedPosition = LatLng(gps.latitude, gps.longitude);
  }

  LatLng _projectOnSegment(LatLng p, LatLng a, LatLng b) {
    final double metersPerDegLat = 111320.0;
    final double cosLat = cos(p.latitude * pi / 180.0);
    final double metersPerDegLon = 111320.0 * (cosLat == 0 ? 1 : cosLat);

    final double ax = a.longitude * metersPerDegLon;
    final double ay = a.latitude * metersPerDegLat;
    final double bx = b.longitude * metersPerDegLon;
    final double by = b.latitude * metersPerDegLat;
    final double px = p.longitude * metersPerDegLon;
    final double py = p.latitude * metersPerDegLat;

    final double abx = bx - ax;
    final double aby = by - ay;
    final double apx = px - ax;
    final double apy = py - ay;

    final double ab2 = abx * abx + aby * aby;
    if (ab2 < 0.01) return a;

    double t = (apx * abx + apy * aby) / ab2;
    t = t.clamp(0.0, 1.0);

    final double projX = ax + t * abx;
    final double projY = ay + t * aby;

    return LatLng(projY / metersPerDegLat, projX / metersPerDegLon);
  }

  void _matchToRoad(double lat, double lon) {
    if (_cachedRoadData == null ||
        _cachedRoadDataTime == null ||
        DateTime.now().difference(_cachedRoadDataTime!).inSeconds > 5) {
      _onRoad = false;
      _snappedPosition = null;
      _roadHeadingDeg = null;
      return;
    }

    dynamic bestWay;
    int bestSegmentIndex = 0;
    double bestSegmentDist = double.infinity;

    for (final el in _cachedRoadData!) {
      if (el['geometry'] == null) continue;
      final geom = el['geometry'] as List<dynamic>;
      if (geom.length < 2) continue;

      final points = geom
          .map((p) => LatLng(p['lat'] as double, p['lon'] as double))
          .toList();

      for (int i = 0; i < points.length - 1; i++) {
        final dist = _distanceToSegment(lat, lon, points[i], points[i + 1]);
        if (dist < bestSegmentDist) {
          bestSegmentDist = dist;
          bestWay = el;
          bestSegmentIndex = i;
        }
      }
    }

    if (bestWay == null || bestSegmentDist > 10) {
      _onRoad = false;
      _snappedPosition = null;
      _roadHeadingDeg = null;
      return;
    }

    final geom = bestWay['geometry'] as List<dynamic>;
    final pt1 = LatLng(
      geom[bestSegmentIndex]['lat'] as double,
      geom[bestSegmentIndex]['lon'] as double,
    );
    final pt2 = LatLng(
      geom[bestSegmentIndex + 1]['lat'] as double,
      geom[bestSegmentIndex + 1]['lon'] as double,
    );

    _snappedPosition = _projectOnSegment(LatLng(lat, lon), pt1, pt2);

    final segBearing = _bearing(pt1, pt2);
    double headingDiff = (_lastHeading ?? segBearing) - segBearing;
    if (headingDiff > 180) headingDiff -= 360;
    if (headingDiff < -180) headingDiff += 360;
    final goingForward = headingDiff.abs() <= 90;
    _roadHeadingDeg = goingForward ? segBearing : (segBearing + 180) % 360;
    _onRoad = true;
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

    final bool movingFast = (_lastSpeed ?? 0) > 2.5;

    // 1) Road heading (from map matching) is most stable and correct
    if (_onRoad && _roadHeadingDeg != null) {
      _usingGpsCourse = false;
      final double chosen = normalize(_roadHeadingDeg!);
      const double alpha = 0.5;
      double current = _displayHeadingDeg;
      double delta = chosen - current;
      if (delta > 180) delta -= 360;
      if (delta < -180) delta += 360;
      double next = current + alpha * delta;
      _displayHeadingDeg = normalize(next);
      return;
    }

    double? gpsCourseDeg = (_lastHeading != null && _lastHeading! >= 0)
        ? normalize(_lastHeading!)
        : null;

    double? compassDeg = _hasCompassHeading ? normalize(_rotation) : null;

    // If moving > ~2.5 m/s (~9 km/h), prefer GPS course as it's usually more stable while driving
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
    const double alpha = 0.5; // higher = more responsive, lower = smoother
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
    conn.checkConnectivity().then((results) => _onConnectivity(results));
    _connectivityStream = conn.onConnectivityChanged.listen(_onConnectivity);
  }

  void _onConnectivity(List<ConnectivityResult> results) {
    // Take the first connectivity result (most common case)
    _connectivityStatus = results.isNotEmpty
        ? results.first
        : ConnectivityResult.none;
  }

  // Offline message queue
  // FIX BUG #28: Buffer unsent messages during disconnect, flush on reconnect
  final List<Map<String, dynamic>> _pendingMessages = [];
  static const int _maxPendingMessages = 30;

  // ======================
  // WebSocket + Data Sender
  // ======================
  void _initWebSocket() {
    _connectWebSocket();
  }

  Future<String> _getWsUrlWithToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('accessToken') ?? '';
    return '${AppConfig.wsUrl}?token=$token';
  }

  void _connectWebSocket() {
    try {
      _ws?.sink.close(); // Close existing connection if any
      // FIX BUG #2: Pass JWT token as query parameter for WebSocket auth
      final wsUrlFuture = _getWsUrlWithToken();
      wsUrlFuture.then((wsUrl) {
        _ws = WebSocketChannel.connect(Uri.parse(wsUrl));
        debugPrint('🔗 Connecting to WebSocket with auth');

        _ws!.stream.listen(
          (msg) {
            debugPrint('📥 WS Message: $msg');
            _handleWsMessage(msg);
            setState(() {
              _isConnected = true;
              _connectionStatus = 'Connected';
            });
            // Flush pending messages on reconnect
            // FIX BUG #28: Send queued messages
            if (_pendingMessages.isNotEmpty) {
              debugPrint('📤 Flushing ${_pendingMessages.length} pending messages');
              for (final pm in _pendingMessages) {
                try {
                  _ws!.sink.add(jsonEncode(pm));
                } catch (e) {
                  debugPrint('❌ Failed to flush pending message: $e');
                }
              }
              _pendingMessages.clear();
            }
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
        _sendTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
          _sendWebSocket();
        });

        debugPrint('✅ WebSocket connected successfully');
        setState(() {
          _isConnected = true;
          _connectionStatus = 'Connected';
        });
      }).catchError((e) {
        debugPrint('❌ WebSocket connection failed: $e - will retry...');
        _reconnectWebSocket();
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
      if (payload is! Map) return;

      // --- Format 1: Direct push from backend: {status: "threat", data: {...}} ---
      if (payload['status'] == 'threat' && payload['data'] != null) {
        final threat = payload['data'] as Map<String, dynamic>;
        _showThreatAlert(threat);
        return;
      }

      // --- Format 2: Heartbeat with threats: {status: "received", threats: [...]} ---
      final List<dynamic> threats = payload['threats'] is List
          ? (payload['threats'] as List)
          : const [];

      if (threats.isNotEmpty) {
        final List<Marker> markers = [];
        final List<Map<String, dynamic>> newThreats = [];

        for (final t in threats) {
          if (t is! Map) continue;
          final num? latNum = t['lat'] as num?;
          final num? lngNum = t['lng'] as num?;
          if (latNum == null || lngNum == null) continue;

          markers.add(
            Marker(
              point: LatLng(latNum.toDouble(), lngNum.toDouble()),
              width: 18,
              height: 18,
              child: const Icon(Icons.warning, color: Colors.red, size: 14),
            ),
          );

          newThreats.add(t.cast<String, dynamic>());
          _showThreatAlert(t.cast<String, dynamic>());
        }

        if (mounted) {
          setState(() {
            _threatMarkers = markers;
            _activeThreats = newThreats;
          });
        }

        // Auto-clear threats after 10 seconds
        _clearThreatTimer?.cancel();
        _clearThreatTimer = Timer(const Duration(seconds: 10), () {
          if (mounted) {
            setState(() {
              _threatMarkers = [];
              _activeThreats = [];
            });
          }
        });
      }

      // Extract upcoming turns from backend response
      if (payload['upcomingTurns'] is List) {
        final turns = (payload['upcomingTurns'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        if (mounted) {
          setState(() {
            _upcomingTurns = turns;
          });
        }
      }

      // Extract current road info
      if (payload['currentRoadInfo'] is Map) {
        if (mounted) {
          setState(() {
            _currentRoadInfo = payload['currentRoadInfo'] as Map<String, dynamic>?;
          });
        }
      }
    } catch (e) {
      debugPrint('❌ Failed to parse WebSocket message: $e');
      debugPrint('Raw message: $msg');
    }
  }

  // FIX BUG #24: Add vibration + sound on alert
  void _showThreatAlert(Map<String, dynamic> threat) {
    if (!mounted) return;

    final String type = threat['type'] ?? 'unknown';
    final String message = threat['message'] ?? '⚠️ Collision risk detected';
    final int severity = threat['severity'] ?? 1;

    IconData icon;
    Color color;
    switch (type) {
      case 'turn_collision':
        icon = Icons.turn_slight_right;
        color = Colors.red;
        break;
      case 'predicted_collision':
        icon = Icons.directions_car;
        color = Colors.red;
        break;
      case 'rear_end':
        icon = Icons.car_crash;
        color = Colors.deepOrange;
        break;
      case 'wrong_direction':
        icon = Icons.swap_horiz;
        color = Colors.purple;
        break;
      default:
        icon = Icons.warning;
        color = Colors.orange;
    }

    // Trigger vibration (SOS pattern for severity 3)
    HapticFeedback.heavyImpact();
    if (severity >= 2) {
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 200), () {
        HapticFeedback.heavyImpact();
      });
    }

    // Play system alert sound
    SystemSound.play(SystemSoundType.alert);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  if (severity > 0)
                    Text('Severity: $severity/3', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: color,
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 100, left: 10, right: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
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
    debugPrint(
      '🌍 Position: ${_fusedPosition!.latitude}, ${_fusedPosition!.longitude}',
    );

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
      "turnAhead": _turnInfo?['exists'] ?? false,
      "turnType": _turnInfo?['type'],
      "turnDistance": _turnInfo?['distance'],
      "intersectionLat": _turnInfo?['intersectionLat'],
      "intersectionLng": _turnInfo?['intersectionLng'],
    };

    debugPrint("📤 Sending WebSocket data...");
    debugPrint(jsonEncode(payload));

    // FIX BUG #28: Offline buffer — queue if not connected
    if (!_isConnected || _ws == null) {
      if (_pendingMessages.length < _maxPendingMessages) {
        _pendingMessages.add(payload as Map<String, dynamic>);
        debugPrint("📤 Queued for later (${_pendingMessages.length} pending)");
      } else {
        debugPrint("⚠️ Pending message queue full, dropping oldest");
        _pendingMessages.removeAt(0);
        _pendingMessages.add(payload as Map<String, dynamic>);
      }
      setState(() => _isSendingData = false);
      return;
    }

    try {
      setState(() {
        _isSendingData = true;
      });

      _ws!.sink.add(jsonEncode(payload));
      _lastDataSent = DateTime.now();
      _lastSentData = payload;

      setState(() {
        _isSendingData = false;
      });

      debugPrint("✅ Data sent successfully at ${DateTime.now()}");
    } catch (e) {
      // Queue on send failure too
      if (_pendingMessages.length < _maxPendingMessages) {
        _pendingMessages.add(payload as Map<String, dynamic>);
      }
      setState(() {
        _isSendingData = false;
        _isConnected = false;
        _connectionStatus = 'Send Error';
      });
      debugPrint("❌ Failed to send data: $e - queued for retry");
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
    _clearThreatTimer?.cancel();
    _ws?.sink.close();
    super.dispose();
  }

  // -----------------
  // Turn detection helpers
  // -----------------

  double _distance(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000; // meters
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;

    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);

    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _bearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;

    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);

    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  // Speed-aware rate-limited check: OR condition (time OR distance)
  Future<void> _maybeScheduleTurnCheck() async {
    try {
      final now = DateTime.now();
      if (_fusedPosition == null) return;

      // Faster speed = more frequent checks
      final speed = _lastSpeed ?? 0;
      int minSeconds;
      if (speed > 13.9) {        // > 50 km/h
        minSeconds = 3;
      } else if (speed > 8.3) {  // > 30 km/h
        minSeconds = 5;
      } else if (speed > 4.2) {  // > 15 km/h
        minSeconds = 8;
      } else {
        minSeconds = 15;
      }

      // Check every 25m moved (half of minimum scan range)
      const double minDistance = 25.0;

      if (_lastTurnCheckTime != null) {
        final dt = now.difference(_lastTurnCheckTime!).inMilliseconds;
        final moved = _lastTurnCheckPosition == null
            ? double.infinity
            : _distance(
                _fusedPosition!.latitude,
                _fusedPosition!.longitude,
                _lastTurnCheckPosition!.latitude,
                _lastTurnCheckPosition!.longitude,
              );

        // OR condition — check if EITHER enough time passed OR enough distance moved
        if (dt < minSeconds * 1000 && moved < minDistance) {
          return;
        }
      }

      await _checkTurnAhead();
    } catch (e) {
      debugPrint('❌ Turn check failed: $e');
    }
  }

  double _getScanRadius() {
    final speed = _lastSpeed ?? 0;
    if (speed > 13.9) return 150;   // > 50 km/h
    if (speed > 8.3)  return 100;   // > 30 km/h
    return 60;                      // slow speed
  }

  // Cache position for road data fetch-distance check
  LatLng? _lastRoadFetchPosition;

  Future<Map<String, dynamic>?> _detectTurnAhead() async {
    if (_fusedPosition == null) return null;

    final lat = _fusedPosition!.latitude;
    final lon = _fusedPosition!.longitude;
    final scanRadius = _getScanRadius();

    // FIX BUG #36: Use cached road data if within 20m of last fetch
    if (_cachedRoadData != null && _lastRoadFetchPosition != null && _cachedRoadData!.isNotEmpty) {
      final distSinceFetch = _distance(
        lat, lon,
        _lastRoadFetchPosition!.latitude, _lastRoadFetchPosition!.longitude,
      );
      if (distSinceFetch < 20.0) {
        debugPrint('🗺️ Using cached road data (moved ${distSinceFetch.toStringAsFixed(1)}m)');
        return _processTurnDataFromElements(_cachedRoadData!, lat, lon, scanRadius);
      }
    }

    Map<String, dynamic>? data;
    try {
      final url = Uri.parse(
        "${AppConfig.baseUrl}/api/nearby-roads"
        "?lat=$lat&lon=$lon&radius=$scanRadius",
      );
      final res = await http.get(url).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        data = jsonDecode(res.body);
        debugPrint('✅ Nearby roads query succeeded');
      }
    } catch (e) {
      debugPrint('⚠️ Nearby roads query failed: $e');
      if (_cachedRoadData != null && _cachedRoadData!.isNotEmpty) {
        debugPrint('🗺️ Falling back to cached road data');
        return _processTurnDataFromElements(_cachedRoadData!, lat, lon, scanRadius);
      }
      return null;
    }

    if (data != null && data['elements'] != null && (data['elements'] as List).isNotEmpty) {
      _cachedRoadData = List.from(data['elements']);
      _cachedRoadDataTime = DateTime.now();
      _lastRoadFetchPosition = _fusedPosition;
      return _processTurnDataFromElements(_cachedRoadData!, lat, lon, scanRadius);
    }

    debugPrint('⚠️ No roads found nearby');
    if (_cachedRoadData != null && _cachedRoadData!.isNotEmpty) {
      debugPrint('🗺️ Falling back to cached road data');
      return _processTurnDataFromElements(_cachedRoadData!, lat, lon, scanRadius);
    }
    return null;
  }

  Future<Map<String, dynamic>?> _processTurnDataFromElements(List<dynamic> elements, double lat, double lon, double scanRadius) async {

    // Find the way with the closest segment to the user's position
    dynamic bestWay;
    int bestSegmentIndex = 0;
    double bestSegmentDist = double.infinity;

    for (final el in elements) {
      if (el['geometry'] == null) continue;
      final geom = el['geometry'] as List<dynamic>;
      if (geom.length < 2) continue;

      // Convert to LatLng list
      final points = geom
          .map((p) => LatLng(p['lat'] as double, p['lon'] as double))
          .toList();

      // Find the closest segment (line between two consecutive points)
      for (int i = 0; i < points.length - 1; i++) {
        final p1 = points[i];
        final p2 = points[i + 1];

        // Calculate distance from user to the segment
        final distToSegment = _distanceToSegment(lat, lon, p1, p2);

        if (distToSegment < bestSegmentDist) {
          bestSegmentDist = distToSegment;
          bestWay = el;
          bestSegmentIndex = i;
        }
      }
    }

    if (bestWay == null) {
      debugPrint('⚠️ No suitable way found');
      return null;
    }

    final geom = bestWay['geometry'] as List<dynamic>;
    if (geom.length < 2) return null;

    // Convert to LatLng list
    final points = geom
        .map((p) => LatLng(p['lat'] as double, p['lon'] as double))
        .toList();

    final nodes = bestWay['nodes'] as List?;

    int startIndex = bestSegmentIndex;

    // Determine which direction the vehicle is traveling along the way
    final segBearing = _bearing(points[startIndex], points[startIndex + 1]);
    double headingDiff = (_lastHeading ?? segBearing) - segBearing;
    if (headingDiff > 180) headingDiff -= 360;
    if (headingDiff < -180) headingDiff += 360;
    final goingForward = headingDiff.abs() <= 90;
    debugPrint('🧭 heading=$_lastHeading segBearing=${segBearing.toStringAsFixed(0)}° diff=${headingDiff.toStringAsFixed(0)}° goingForward=$goingForward');

    // ─── PHASE 1: Junction detection (node shared with other roads) ───
    if (nodes != null && nodes.isNotEmpty) {
      // Build node-to-ways index
      final Map<int, List<int>> nodeToWays = {};
      final bestWayId = bestWay['id'] as int;
      for (final el in elements) {
        if (el['type'] != 'way' || el['nodes'] == null) continue;
        final wId = el['id'] as int;
        for (final nid in (el['nodes'] as List).cast<int>()) {
          nodeToWays.putIfAbsent(nid, () => []).add(wId);
        }
      }

      // Index other way geometries for direction lookup
      final Map<int, List> otherGeoms = {};
      for (final el in elements) {
        if (el['type'] == 'way' && el['id'] != bestWayId && el['geometry'] != null) {
          otherGeoms[el['id'] as int] = el['geometry'] as List;
        }
      }

      final int scanLimit = goingForward
          ? (nodes.length < points.length ? nodes.length : points.length)
          : 0;
      final int scanStep = goingForward ? 1 : -1;

      for (int j = startIndex; goingForward ? j < scanLimit : j >= scanLimit; j += scanStep) {
        final dist = _distance(lat, lon, points[j].latitude, points[j].longitude);
        if (dist > scanRadius) break;

        final nodeId = nodes[j] as int;
        final waysHere = nodeToWays[nodeId] ?? [];
        if (waysHere.length <= 1) continue;

        // Approach bearing depends on travel direction
        final approach = goingForward
            ? _bearing(points[j > 0 ? j - 1 : 0], points[j])
            : _bearing(points[j + 1 < points.length ? j + 1 : points.length - 1], points[j]);

        // Check each other way at this node
        final sideRoads = <String>{};
        for (final otherId in waysHere) {
          if (otherId == bestWayId) continue;
          final otherGeom = otherGeoms[otherId];
          if (otherGeom == null) continue;

          int otherIdx = -1;
          for (int k = 0; k < otherGeom.length; k++) {
            final og = otherGeom[k] as Map<String, dynamic>;
            final oLat = og['lat'] as double;
            final oLon = og['lon'] as double;
            if ((oLat - points[j].latitude).abs() < 0.00001 &&
                (oLon - points[j].longitude).abs() < 0.00001) {
              otherIdx = k;
              break;
            }
          }
          if (otherIdx < 0) continue;

          final dirIdx = otherIdx + 1 < otherGeom.length ? otherIdx + 1 : otherIdx - 1;
          if (dirIdx < 0 || dirIdx >= otherGeom.length) continue;

          final ogDir = otherGeom[dirIdx] as Map<String, dynamic>;
          final brg = _bearing(
            points[j],
            LatLng(ogDir['lat'] as double, ogDir['lon'] as double),
          );

          double diff = (brg - approach) % 360;
          if (diff > 180) diff -= 360;

          if (diff.abs() <= 30) {
            sideRoads.add("straight");
          } else if (diff > 30 && diff <= 150) {
            sideRoads.add("right");
          } else if (diff < -30 && diff >= -150) {
            sideRoads.add("left");
          }
        }

        // Check if vehicle's own road continues past this node (in travel direction)
        final hasStraight = goingForward
            ? (j + 1 < points.length)
            : (j > 0);
        final dirs = Set<String>.from(sideRoads);
        if (hasStraight) dirs.add("straight");

        // Classify junction
        String type;
        if (dirs.contains("straight") && dirs.length >= 3) {
          type = "cross";
        } else if (!dirs.contains("straight") && dirs.length >= 2) {
          type = "t_junction";
        } else if (dirs.length == 1 && dirs.contains("straight")) {
          continue;
        } else if (dirs.length == 1) {
          type = dirs.first == "left" ? "left_turn" : "right_turn";
        } else {
          continue;
        }

        debugPrint('🚧 $type at ${dist.toStringAsFixed(1)}m — $dirs');
        return {
          "exists": true,
          "type": type,
          "distance": dist,
          "intersectionLat": points[j].latitude,
          "intersectionLng": points[j].longitude,
        };
      }
    }

    // ─── PHASE 2: Road bend detection (L-shape on same road) ───
    if (goingForward) {
      for (int j = startIndex; j + 2 < points.length; j++) {
        final dist = _distance(lat, lon, points[j + 1].latitude, points[j + 1].longitude);
        if (dist > scanRadius) break;

        final b1 = _bearing(points[j], points[j + 1]);
        final b2 = _bearing(points[j + 1], points[j + 2]);
        double angleChange = b2 - b1;
        if (angleChange > 180) angleChange -= 360;
        if (angleChange < -180) angleChange += 360;

        if (angleChange.abs() >= 45.0) {
          final type = angleChange > 0 ? "right_bend" : "left_bend";
          debugPrint('↩️ $type at ${dist.toStringAsFixed(1)}m (angle: ${angleChange.toStringAsFixed(1)}°)');
          return {
            "exists": true,
            "type": type,
            "distance": dist,
            "intersectionLat": points[j + 1].latitude,
            "intersectionLng": points[j + 1].longitude,
          };
        }
      }
    } else {
      for (int j = startIndex; j >= 2; j--) {
        final dist = _distance(lat, lon, points[j - 1].latitude, points[j - 1].longitude);
        if (dist > scanRadius) break;

        final b1 = _bearing(points[j], points[j - 1]);
        final b2 = _bearing(points[j - 1], points[j - 2]);
        double angleChange = b2 - b1;
        if (angleChange > 180) angleChange -= 360;
        if (angleChange < -180) angleChange += 360;

        if (angleChange.abs() >= 45.0) {
          final type = angleChange > 0 ? "right_bend" : "left_bend";
          debugPrint('↩️ $type at ${dist.toStringAsFixed(1)}m (angle: ${angleChange.toStringAsFixed(1)}°)');
          return {
            "exists": true,
            "type": type,
            "distance": dist,
            "intersectionLat": points[j - 1].latitude,
            "intersectionLng": points[j - 1].longitude,
          };
        }
      }
    }

    return {"exists": false, "distance": null};
  }

  // Helper function to calculate distance from a point to a line segment
  double _distanceToSegment(
    double lat,
    double lon,
    LatLng segStart,
    LatLng segEnd,
  ) {
    // Convert to radians for calculations
    final lat1 = segStart.latitude * pi / 180;
    final lon1 = segStart.longitude * pi / 180;
    final lat2 = segEnd.latitude * pi / 180;
    final lon2 = segEnd.longitude * pi / 180;
    final lat0 = lat * pi / 180;
    final lon0 = lon * pi / 180;

    // Calculate distance from point to line segment using cross-track distance
    final d13 = _distance(segStart.latitude, segStart.longitude, lat, lon);
    final d12 = _distance(
      segStart.latitude,
      segStart.longitude,
      segEnd.latitude,
      segEnd.longitude,
    );
    final d23 = _distance(segEnd.latitude, segEnd.longitude, lat, lon);

    // If segment is very short, just use distance to nearest endpoint
    if (d12 < 0.1) {
      return d13 < d23 ? d13 : d23;
    }

    // Calculate bearing from segStart to segEnd and from segStart to point
    final brng12 = _bearing(segStart, segEnd) * pi / 180;
    final brng13 = _bearing(segStart, LatLng(lat, lon)) * pi / 180;

    // Cross-track distance
    final dxt = asin(sin(d13 / 6371000) * sin(brng13 - brng12)) * 6371000;

    // Check if the point projects onto the segment
    final dAlong = d13 * cos(brng13 - brng12);
    if (dAlong < 0 || dAlong > d12) {
      // Point projects outside segment, use distance to nearest endpoint
      return d13 < d23 ? d13 : d23;
    }

    return dxt.abs();
  }

  Future<void> _checkTurnAhead() async {
    try {
      final now = DateTime.now();
      final result = await _detectTurnAhead();
      _lastTurnCheckTime = now;
      _lastTurnCheckPosition = _fusedPosition;

      if (mounted) {
        setState(() {
          // Always set turnInfo, even if null (will show as false/None/N/A in UI)
          _turnInfo = result ?? {"exists": false, "distance": null};
        });
      }
    } catch (e) {
      debugPrint('❌ _checkTurnAhead error: $e');
      // On error, set to no turn detected
      if (mounted) {
        setState(() {
          _turnInfo = {"exists": false, "distance": null};
        });
      }
    }
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
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
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.explore,
                                  color: Colors.white,
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${_displayHeadingDeg.toStringAsFixed(0)}° ${_onRoad ? 'road' : (_usingGpsCourse ? 'gps' : (_hasCompassHeading ? 'compass' : 'n/a'))} (cal: ${_calibrationOffsetDeg.toStringAsFixed(0)}°)',
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
                // Active threat banners (above map)
                if (_activeThreats.isNotEmpty)
                  Positioned(
                    top: 76,
                    left: 8,
                    right: 8,
                    child: Column(
                      children: _activeThreats.map((t) {
                        final type = t['type'] ?? 'unknown';
                        final msg = t['message'] ?? 'Collision risk';
                        Color bgColor;
                        IconData icon;
                        switch (type) {
                          case 'turn_collision':
                            bgColor = Colors.red.shade700;
                            icon = Icons.turn_slight_right;
                            break;
                          case 'predicted_collision':
                            bgColor = Colors.red.shade700;
                            icon = Icons.directions_car;
                            break;
                          case 'rear_end':
                            bgColor = Colors.deepOrange;
                            icon = Icons.car_crash;
                            break;
                          case 'wrong_direction':
                            bgColor = Colors.purple;
                            icon = Icons.swap_horiz;
                            break;
                          default:
                            bgColor = Colors.orange.shade800;
                            icon = Icons.warning;
                        }
                        return Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: bgColor,
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 6)],
                          ),
                          child: Row(
                            children: [
                              Icon(icon, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  msg,
                                  style: const TextStyle(color: Colors.white, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                // Map with top padding for status bar
                Positioned(
                  top: _activeThreats.isNotEmpty ? 140 : 80,
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
                            point: _snappedPosition ?? _currentPosition!,
                            width: 60,
                            height: 60,
                            rotate: false,
                            child: AnimatedRotation(
                              turns: ((_displayHeadingDeg % 360) / 360),
                              duration: const Duration(milliseconds: 150),
                              curve: Curves.easeOut,
                              child: Icon(
                                Icons.navigation,
                                color: _onRoad ? Colors.green : Colors.blue,
                                size: 45,
                              ),
                            ),
                          ),
                        ],
                      ),
                      // Threat markers layer (red dots)
                      if (_threatMarkers.isNotEmpty)
                        MarkerLayer(markers: _threatMarkers),
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
                        _userHasInteracted =
                            false; // Reset flag to allow auto-centering again
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
                    backgroundColor: _showDataViewer
                        ? Colors.blue
                        : Colors.white,
                    foregroundColor: _showDataViewer
                        ? Colors.white
                        : Colors.black,
                    onPressed: () {
                      setState(() {
                        _showDataViewer = !_showDataViewer;
                      });
                    },
                    child: Icon(
                      _showDataViewer ? Icons.close : Icons.data_usage,
                    ),
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
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Data Content
                          if (_lastSentData != null) ...[
                            _buildDataItem(
                              'User ID',
                              _lastSentData!['userId']?.toString() ?? 'N/A',
                            ),
                            _buildDataItem(
                              'Latitude',
                              _lastSentData!['latitude']?.toString() ?? 'N/A',
                            ),
                            _buildDataItem(
                              'Longitude',
                              _lastSentData!['longitude']?.toString() ?? 'N/A',
                            ),
                            _buildDataItem(
                              'Speed',
                              _lastSentData!['speed']?.toString() ?? 'N/A',
                            ),
                            _buildDataItem(
                              'Heading',
                              _lastSentData!['heading']?.toString() ?? 'N/A',
                            ),
                            _buildDataItem(
                              'Connectivity',
                              _lastSentData!['connectivity']?.toString() ??
                                  'N/A',
                            ),
                            _buildDataItem(
                              'Timestamp',
                              _lastSentData!['timestamp']?.toString() ?? 'N/A',
                            ),
                            // Sensor data
                            if (_lastSentData!['accel'] != null)
                              _buildDataItem(
                                'Accelerometer',
                                'X: ${_lastSentData!['accel']['x']?.toStringAsFixed(2)}, Y: ${_lastSentData!['accel']['y']?.toStringAsFixed(2)}, Z: ${_lastSentData!['accel']['z']?.toStringAsFixed(2)}',
                              ),
                            if (_lastSentData!['gyro'] != null)
                              _buildDataItem(
                                'Gyroscope',
                                'X: ${_lastSentData!['gyro']['x']?.toStringAsFixed(4)}, Y: ${_lastSentData!['gyro']['y']?.toStringAsFixed(4)}, Z: ${_lastSentData!['gyro']['z']?.toStringAsFixed(4)}',
                              ),
                            if (_lastSentData!['magnetometer'] != null)
                              _buildDataItem(
                                'Magnetometer',
                                'X: ${_lastSentData!['magnetometer']['x']?.toStringAsFixed(2)}, Y: ${_lastSentData!['magnetometer']['y']?.toStringAsFixed(2)}, Z: ${_lastSentData!['magnetometer']['z']?.toStringAsFixed(2)}',
                              ),
                          ] else ...[
                            const Text(
                              'No data sent yet',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                          const SizedBox(height: 12),
                          // Turn info display (frontend only)
                          const Divider(color: Colors.white12),
                          const SizedBox(height: 8),
                          _buildDataItem(
                            'Turn Ahead',
                            _turnInfo != null && _turnInfo!['exists'] == true
                                ? 'true'
                                : 'false',
                          ),
                          _buildDataItem(
                            'Turn Type',
                            _turnInfo != null && _turnInfo!['exists'] == true
                                ? (_turnInfo!['type']?.toString() ?? 'None')
                                : 'None',
                          ),
                          _buildDataItem(
                            'Turn Distance',
                            _turnInfo != null && _turnInfo!['distance'] != null
                                ? "${(_turnInfo!['distance'] as double).toStringAsFixed(1)} meters"
                                : 'N/A',
                          ),
                          _buildDataItem(
                            'Intersection Lat',
                            _turnInfo?['intersectionLat']?.toString() ?? 'N/A',
                          ),
                          _buildDataItem(
                            'Intersection Lng',
                            _turnInfo?['intersectionLng']?.toString() ?? 'N/A',
                          ),
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
                                        content: Text(
                                          'Data cleared from display',
                                        ),
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
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Data copied to clipboard',
                                          ),
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
                // ─── Turn/junction info card at bottom ───
                if (_turnInfo != null && _turnInfo!['exists'] == true)
                  Positioned(
                    bottom: 160,
                    left: 16,
                    right: 16,
                    child: AnimatedOpacity(
                      opacity: 1.0,
                      duration: const Duration(milliseconds: 300),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: _turnInfo!['type'] == 'left_bend' || _turnInfo!['type'] == 'right_bend'
                              ? Colors.red.shade700
                              : Colors.orange.shade800,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.4),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _buildTurnIcon(_turnInfo!['type']),
                              color: Colors.white,
                              size: 28,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _buildTurnTitle(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (_turnInfo!['distance'] != null)
                                    Text(
                                      '${(_turnInfo!['distance'] as double).toStringAsFixed(0)}m ahead',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.9),
                                        fontSize: 13,
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
                // ─── Upcoming turns list (from backend cone query) ───
                if (_upcomingTurns.isNotEmpty)
                  Positioned(
                    bottom: 250,
                    left: 16,
                    right: 16,
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 160),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.5),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'TURNS AHEAD',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Flexible(
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: _upcomingTurns.length,
                              itemBuilder: (context, index) {
                                final turn = _upcomingTurns[index];
                                final type = turn['type'] as String? ?? 'unknown';
                                final distance = turn['distance'] as int? ?? 0;
                                final timeToReach = turn['timeToReach'] as num? ?? 0;
                                final riskLevel = turn['riskLevel'] as int? ?? 1;
                                final isBlind = turn['blind'] as bool? ?? false;
                                final vehiclesNearby = turn['vehiclesNearby'] as bool? ?? false;
                                final angle = turn['angle'] as int? ?? 0;

                                // Color code by risk
                                Color dotColor;
                                if (vehiclesNearby && isBlind) {
                                  dotColor = Colors.red;
                                } else if (isBlind) {
                                  dotColor = Colors.orange;
                                } else {
                                  dotColor = Colors.green;
                                }

                                IconData turnIcon = _buildTurnIcon(type);

                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                  child: Row(
                                    children: [
                                      Icon(turnIcon, color: dotColor, size: 16),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _formatTurnType(type),
                                          style: TextStyle(
                                            color: dotColor,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '${distance}m',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '${timeToReach}s',
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11,
                                        ),
                                      ),
                                      if (riskLevel >= 3)
                                        const Padding(
                                          padding: EdgeInsets.only(left: 4),
                                          child: Icon(Icons.warning, color: Colors.red, size: 14),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  String _buildTurnTitle() {
    final type = _turnInfo?['type'] as String?;
    switch (type) {
      case 'left_turn': case 'left': return 'LEFT TURN';
      case 'right_turn': case 'right': return 'RIGHT TURN';
      case 'slight_left': case 'gentle_curve_left': return 'GENTLE LEFT';
      case 'slight_right': case 'gentle_curve_right': return 'GENTLE RIGHT';
      case 'sharp_left': return 'SHARP LEFT';
      case 'sharp_right': return 'SHARP RIGHT';
      case 'hairpin_left': return 'HAIRPIN LEFT';
      case 'hairpin_right': return 'HAIRPIN RIGHT';
      case 't_junction': return 'T-JUNCTION';
      case 'y_junction': return 'Y-JUNCTION';
      case 'cross': return 'CROSS INTERSECTION';
      case 'offset_junction': return 'OFFSET JUNCTION';
      case 'roundabout': return 'ROUNDABOUT';
      case 'mini_roundabout': return 'MINI ROUNDABOUT';
      case 'slip_road': return 'SLIP ROAD';
      case 'left_bend': return 'ROAD BENDS LEFT';
      case 'right_bend': return 'ROAD BENDS RIGHT';
      case 's_curve': return 'S-CURVE';
      case 'reverse_s_curve': return 'REVERSE S-CURVE';
      case 'blind_crest': return 'BLIND CREST';
      case 'dip': return 'DIP AHEAD';
      case 'narrow_section': return 'NARROW ROAD';
      case 'dead_end': return 'DEAD END';
      case 'complex': return 'COMPLEX JUNCTION';
      default: return 'JUNCTION AHEAD';
    }
  }

  IconData _buildTurnIcon(dynamic type) {
    final String? t = type?.toString();
    switch (t) {
      case 'left_turn': case 'left': case 'slight_left': case 'gentle_curve_left': case 'sharp_left': case 'hairpin_left':
        return Icons.arrow_left;
      case 'right_turn': case 'right': case 'slight_right': case 'gentle_curve_right': case 'sharp_right': case 'hairpin_right':
        return Icons.arrow_right;
      case 't_junction': case 'y_junction':
        return Icons.merge_type;
      case 'cross': case 'offset_junction':
        return Icons.add;
      case 'roundabout': case 'mini_roundabout':
        return Icons.replay;
      case 's_curve': case 'reverse_s_curve':
        return Icons.swap_horiz;
      case 'blind_crest':
        return Icons.trending_up;
      case 'dip':
        return Icons.trending_down;
      case 'narrow_section':
        return Icons.photo_size_select_small;
      case 'dead_end':
        return Icons.block;
      case 'slip_road':
        return Icons.merge;
      default:
        return Icons.warning_amber_rounded;
    }
  }

  String _formatTurnType(String type) {
    switch (type) {
      case 'left_turn': case 'left': return 'Left';
      case 'right_turn': case 'right': return 'Right';
      case 'slight_left': return 'Slight Left';
      case 'slight_right': return 'Slight Right';
      case 'sharp_left': return 'Sharp Left';
      case 'sharp_right': return 'Sharp Right';
      case 'hairpin_left': return 'Hairpin Left';
      case 'hairpin_right': return 'Hairpin Right';
      case 'gentle_curve_left': return 'Gentle Curve L';
      case 'gentle_curve_right': return 'Gentle Curve R';
      case 't_junction': return 'T-Junction';
      case 'y_junction': return 'Y-Junction';
      case 'cross': return 'Cross';
      case 'offset_junction': return 'Offset Junction';
      case 'roundabout': return 'Roundabout';
      case 'mini_roundabout': return 'Mini Roundabout';
      case 'slip_road': return 'Slip Road';
      case 's_curve': return 'S-Curve';
      case 'reverse_s_curve': return 'Reverse S-Curve';
      case 'blind_crest': return 'Blind Crest';
      case 'dip': return 'Dip';
      case 'narrow_section': return 'Narrow Road';
      case 'dead_end': return 'Dead End';
      case 'complex': return 'Complex Junction';
      default: return type.replaceAll('_', ' ');
    }
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
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
