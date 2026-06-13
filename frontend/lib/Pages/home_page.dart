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
import '../Services/session_recorder.dart';
import 'debug_overlay.dart';
import 'turn_debug.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';

// ─── Pure helper functions for turn detection ───

/// FIX DRAWBACK 3: Maps turn angle (0-180) to risk level 0-5
int getRiskLevelFromAngle(double angleDeg) {
  final a = angleDeg.abs();
  if (a < 15) return 0;
  if (a < 30) return 1;
  if (a < 60) return 2;
  if (a < 90) return 3;
  if (a < 150) return 4;
  return 5;
}

/// FIX DRAWBACK 3: Maps risk level to alert distance in meters
double getAlertDistanceFromRisk(int riskLevel) {
  switch (riskLevel) {
    case 0: return 0;
    case 1: return 30;
    case 2: return 50;
    case 3: return 80;
    case 4: return 120;
    case 5: return 160;
    default: return 50;
  }
}

/// FIX DRAWBACK 1: Classifies junction type from complete direction set
/// Uses ALL roads at a node, not just one road's perspective
String classifyJunctionType(Set<String> dirs, int totalRoadsAtNode, bool hasStraight, double? maxAngleDiff) {
  if (dirs.contains("straight") && dirs.length >= 3) {
    return "cross";
  }
  if (!dirs.contains("straight") && dirs.length >= 2) {
    if (dirs.contains("left") && dirs.contains("right") && totalRoadsAtNode <= 4) {
      return "y_junction";
    }
    return "t_junction";
  }
  if (dirs.length == 1 && dirs.contains("straight")) {
    return "straight";
  }
  if (dirs.length == 1 && maxAngleDiff != null) {
    final absAngle = maxAngleDiff.abs();
    final dir = maxAngleDiff > 0 ? "right" : "left";
    if (absAngle > 150) return "hairpin_$dir";
    if (absAngle > 90) return "sharp_$dir";
    if (absAngle > 30) return "${dir}_turn";
    return "slight_$dir";
  }
  return "complex";
}

/// Normalize angle to 0-360 range
double normalizeAngleDeg(double a) {
  final n = a % 360;
  return n < 0 ? n + 360 : n;
}

/// Calculate angle between two bearings (normalized 0-180)
double calculateTurnAngle(double approachBearing, double exitBearing) {
  double diff = (exitBearing - approachBearing) % 360;
  if (diff > 180) diff -= 360;
  if (diff < -180) diff += 360;
  return diff.abs();
}

class KalmanFilter {
  double lat, lon, vLat, vLon;
  double p00, p01, p10, p11;
  double p22, p33;
  double processNoisePos, processNoiseVel;
  double lastTimestamp;
  bool initialized;

  KalmanFilter()
      : lat = 0,
        lon = 0,
        vLat = 0,
        vLon = 0,
        p00 = 1, p01 = 0, p10 = 0, p11 = 1,
        p22 = 1, p33 = 1,
        processNoisePos = 0.1,
        processNoiseVel = 0.5,
        lastTimestamp = 0,
        initialized = false;

  void init(double latitude, double longitude, double accuracy, double timestamp) {
    lat = latitude;
    lon = longitude;
    vLat = 0;
    vLon = 0;
    p00 = accuracy * accuracy;
    p11 = accuracy * accuracy;
    p22 = 5.0;
    p33 = 5.0;
    lastTimestamp = timestamp;
    initialized = true;
  }

  void predict(double timestamp, {double gyroZ = 0, double accelMagnitude = 0, double speed = 0}) {
    if (!initialized) return;
    final dt = (timestamp - lastTimestamp) / 1000.0;
    if (dt <= 0 || dt > 5.0) {
      lastTimestamp = timestamp;
      return;
    }

    lat += vLat * dt;
    lon += vLon * dt;

    final gyroActivity = gyroZ.abs() > 0.5 ? (gyroZ.abs() / 10.0) : 0.0;
    final accelActivity = accelMagnitude > 2.0 ? (accelMagnitude / 20.0) : 0.0;
    final activityFactor = 1.0 + gyroActivity + accelActivity;

    final qPos = processNoisePos * activityFactor;
    final qVel = processNoiseVel * activityFactor;

    final dt2 = dt * dt;
    final dt3 = dt2 * dt;
    final dt4 = dt3 * dt;

    p00 += p22 * dt2 + qPos * dt4 / 4;
    p01 += p33 * dt2;
    p10 += p22 * dt2;
    p11 += p33 * dt2;

    p22 += qVel * dt2;
    p33 += qVel * dt2;

    lastTimestamp = timestamp;
  }

  void update(double latitude, double longitude, double accuracy, double speed, double heading) {
    if (!initialized) return;
    final r = accuracy * accuracy;

    final yLat = latitude - lat;
    final yLon = longitude - lon;

    final sLat = p00 + r;
    final kLat = sLat > 0 ? p00 / sLat : 0;

    final sLon = p11 + r;
    final kLon = sLon > 0 ? p11 / sLon : 0;

    lat += kLat * yLat;
    lon += kLon * yLon;

    p00 = (1 - kLat) * p00;
    p11 = (1 - kLon) * p11;

      if (speed > 0.5 && heading >= 0) {
        final hRad = heading * pi / 180.0;
        final metersPerDegLat = 111320.0;
        final cosLat = cos(latitude * pi / 180.0).clamp(0.01, 1.0);
        final metersPerDegLon = 111320.0 * cosLat;

        // North-south component → lat velocity (deg/s)
        final vLatTarget = speed * cos(hRad) / metersPerDegLat;
        // East-west component → lon velocity (deg/s)
        final vLonTarget = speed * sin(hRad) / metersPerDegLon;

        const velGain = 0.3;
        vLat += velGain * (vLatTarget - vLat);
        vLon += velGain * (vLonTarget - vLon);
      }
  }

  double getUncertainty() {
    if (!initialized) return 10.0;
    return sqrt((p00 + p11) / 2.0);
  }

  double getLatitude() => lat;
  double getLongitude() => lon;
}

class SessionFatigue {
  final List<DateTime> _alertTimestamps = [];
  static const int maxAlertsPerWindow = 5;
  static const Duration fatigueWindow = Duration(minutes: 1);
  int _totalAlertsInRide = 0;

  bool shouldSuppress(double alertConfidence) {
    final now = DateTime.now();
    _alertTimestamps.removeWhere((t) => now.difference(t) > fatigueWindow);
    _alertTimestamps.add(now);
    _totalAlertsInRide++;

    if (_alertTimestamps.length > maxAlertsPerWindow) {
      return alertConfidence < 0.7;
    }
    return false;
  }

  int get alertsInWindow => _alertTimestamps.length;
  int get totalAlerts => _totalAlertsInRide;

  void reset() {
    _alertTimestamps.clear();
    _totalAlertsInRide = 0;
  }
}

enum SafetyMode { conservative, balanced, minimal }

extension SafetyModeExtension on SafetyMode {
  double get criticalThreshold {
    switch (this) {
      case SafetyMode.conservative: return 0.50;
      case SafetyMode.balanced: return 0.70;
      case SafetyMode.minimal: return 0.85;
    }
  }
  double get highThreshold {
    switch (this) {
      case SafetyMode.conservative: return 0.30;
      case SafetyMode.balanced: return 0.40;
      case SafetyMode.minimal: return 0.60;
    }
  }
  double get monitorThreshold {
    switch (this) {
      case SafetyMode.conservative: return 0.15;
      case SafetyMode.balanced: return 0.20;
      case SafetyMode.minimal: return 0.40;
    }
  }
  String get label {
    switch (this) {
      case SafetyMode.conservative: return 'Conservative';
      case SafetyMode.balanced: return 'Balanced';
      case SafetyMode.minimal: return 'Minimal';
    }
  }
}

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
  List<dynamic>? _cachedRoadData;
  DateTime? _cachedRoadDataTime;

  // Threat markers rendered as red dots
  List<Marker> _threatMarkers = [];
  // Nearby vehicle markers rendered as red dots
  List<Marker> _nearbyVehicleMarkers = [];
  // Turn debug markers
  List<Marker> _turnDetectionMarkers = [];
  final Set<String> _crossedTurnKeys = {};
  bool _showTurnPanel = true;
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
  Timer? _reconnectTimer;

  Map<String, dynamic>? user;
  bool isLoading = true;

  // Status indicators
  bool _isConnected = false;
  bool _redisConnected = false;
  bool _isSendingData = false;
  DateTime? _lastDataSent;
  String _connectionStatus = 'Connecting...';

  // Data viewer
  bool _showDataViewer = false;
  bool _showBoundingBox = false;
  Map<String, dynamic>? _lastSentData;

  // Sprint 1: Kalman filter
  final KalmanFilter _kalman = KalmanFilter();

  // Sprint 1: Time sync
  double _timeOffset = 0.0;
  double _timeSyncConfidence = 1.0;
  final List<double> _timeOffsets = [];
  int _lastClientSendTime = 0;

  // Sprint 1: GPS accuracy tracking for outlier rejection
  double _lastGpsAccuracy = 10.0;

  // Turn detection state (frontend only)
  List<Map<String, dynamic>> _detectedTurns = []; // list of turns, sorted by distance
  Map<String, dynamic>? _primaryTurn;              // nearest turn (for backward compat)
  DateTime? _lastTurnCheckTime;
  LatLng? _lastTurnCheckPosition;
  final TurnDebugInfo _turnDebug = TurnDebugInfo();

  // Sprint 4: Session fatigue + safety mode
  final SessionFatigue _fatigue = SessionFatigue();
  SafetyMode _safetyMode = SafetyMode.balanced;

  // Phase 1: Session recorder
  final SessionRecorder _sessionRecorder = SessionRecorder();

  // Session recording
  bool _isRecording = false;
  DateTime? _sessionStartTime;
  List<Map<String, dynamic>> _sessionSnapshots = [];
  Timer? _recordingTimer;
  int _recordingSeconds = 0;

  // Upcoming turns from backend cone query
  List<Map<String, dynamic>> _upcomingTurns = [];
  Map<String, dynamic>? _currentRoadInfo;

  // FIX DRAWBACK 6: Emergency cache for network failure
  List<Map<String, dynamic>>? _emergencyRoadCache;
  LatLng? _emergencyCachePosition;
  DateTime? _emergencyCacheTime;
  String _turnDetectionStatus = 'no_data'; // 'fresh', 'cached', 'limited', 'no_data'

  // Part 3: Backend pre-computed turn markers on map
  List<Marker> _backendTurnMarkers = [];

  // Part 4: Two-check multi-vehicle collision verification
  double _turnDetectionConfidence = 0.0;
  int _multiVehicleRisk = 0;
  int _vehiclesAtTurn = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await fetchUserProfile();
      await _loadRoadCache();
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
    _tryGetGps();
  }

  void _tryGetGps() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint("📍 Location services disabled — retrying in 10s");
        Future.delayed(const Duration(seconds: 10), _tryGetGps);
        return;
      }

      LocationPermission permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint("📍 Permission denied — retrying in 10s");
        Future.delayed(const Duration(seconds: 10), _tryGetGps);
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        debugPrint("📍 Permission denied forever — cannot get location");
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _updatePosition(position, initial: true);

      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        ),
      ).listen((pos) => _updatePosition(pos));
    } catch (e) {
      debugPrint("📍 Location failed, retrying in 10s: $e");
      Future.delayed(const Duration(seconds: 10), _tryGetGps);
    }
  }

  void _updatePosition(Position pos, {bool initial = false}) {
    _lastGpsAccuracy = pos.accuracy ?? 10.0;
    final now = pos.timestamp ?? DateTime.now();
    final nowMs = now.millisecondsSinceEpoch.toDouble();

    // Sprint 1: Kalman filter with outlier rejection
    if (initial || !_kalman.initialized) {
      _kalman.init(pos.latitude, pos.longitude, _lastGpsAccuracy, nowMs);
      _fusedPosition = LatLng(pos.latitude, pos.longitude);
      _currentPosition = LatLng(pos.latitude, pos.longitude);
    } else {
      // Predict step (run every time, even without gyro updates)
      _kalman.predict(nowMs,
        gyroZ: _lastGyro?.z ?? 0,
        accelMagnitude: _lastAccel != null
            ? (_lastAccel!.x.abs() + _lastAccel!.y.abs() + _lastAccel!.z.abs()) / 3
            : 0,
        speed: pos.speed ?? 0,
      );

      // Outlier rejection: if GPS jumped impossibly far, reject this update
      final predictedLat = _kalman.getLatitude();
      final predictedLon = _kalman.getLongitude();
      final metersPerDegLat = 111320.0;
      final cosLat = _cosDeg(pos.latitude);
      final finalMetersPerDegLon = cosLat < 0.01 ? 111320.0 : 111320.0 * cosLat;
      final predictedLatDelta = (predictedLat - pos.latitude) * metersPerDegLat;
      final predictedLonDelta = (predictedLon - pos.longitude) * finalMetersPerDegLon;
      final maxJumpM = (pos.speed ?? 0) * 4.0 + 30.0;

      if ((predictedLatDelta.abs() > maxJumpM || predictedLonDelta.abs() > maxJumpM) && !initial) {
        debugPrint('📍 Outlier rejected: dLat=${predictedLatDelta.toStringAsFixed(1)}m dLon=${predictedLonDelta.toStringAsFixed(1)}m maxJump=$maxJumpM');
        // Still use dead reckoning for position
        _fusedPosition = LatLng(predictedLat, predictedLon);
      } else {
        // Update Kalman with GPS measurement
        _kalman.update(pos.latitude, pos.longitude, _lastGpsAccuracy, pos.speed ?? 0, pos.heading ?? 0);
        _fusedPosition = LatLng(_kalman.getLatitude(), _kalman.getLongitude());
      }
    }

    _currentPosition = LatLng(pos.latitude, pos.longitude);

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

    _lastTimestamp = now;
    _lastSpeed = pos.speed;
    _lastHeading = pos.heading;
    _matchToRoad(pos.latitude, pos.longitude);
    _updateHeadingFromSources();

    // Trigger a turn-check when position changes significantly (rate-limited)
    _maybeScheduleTurnCheck();

    // Check if turn marker should be cleared (crossed the turn)
    _checkTurnCrossed();

    setState(() {});
  }

  double _cosDeg(double degrees) {
    return cos(degrees * pi / 180.0);
  }

  // Sprint 1: Sensor quality score (0.0–1.0)
  double _computeSensorQuality() {
    double score = 1.0;
    if (_lastGpsAccuracy > 10) score *= 0.8;
    if (_lastGpsAccuracy > 25) score *= 0.5;
    if (_lastGpsAccuracy > 50) score *= 0.3;
    if (_lastGyro == null) score *= 0.7;
    if (!_hasCompassHeading) score *= 0.9;
    if (_lastSpeed != null && _lastSpeed! < 0.5) score *= 0.95;
    return score.clamp(0.1, 1.0);
  }

  // Sprint 1: Time sync update from server response
  void _updateTimeOffset(int serverTimeMs) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rtt = nowMs - _lastClientSendTime;
    if (rtt < 0 || rtt > 10000) return;
    final estimatedOffset = ((serverTimeMs + rtt ~/ 2) - nowMs).toDouble();
    _timeOffsets.add(estimatedOffset);
    if (_timeOffsets.length > 20) _timeOffsets.removeAt(0);
    if (_timeOffsets.length >= 3) {
      final mean = _timeOffsets.reduce((a, b) => a + b) / _timeOffsets.length;
      final variance = _timeOffsets.fold(0.0, (sum, v) => sum + (v - mean) * (v - mean)) / _timeOffsets.length;
      final stdDev = sqrt(variance.abs());
      _timeOffset = mean;
      _timeSyncConfidence = (1.0 - (stdDev / 500).clamp(0.0, 0.9)).clamp(0.1, 1.0);
    }
  }

  // Part 3: Build markers from backend pre-computed turns (using lat/lng keys)
  List<Marker> _buildBackendTurnMarkers(List<Map<String, dynamic>> turns) {
    if (turns.isEmpty) return [];
    final heading = _lastHeading ?? 0;
    final originLat = _fusedPosition?.latitude ?? 0;
    final originLng = _fusedPosition?.longitude ?? 0;
    return turns.where((t) {
      final tLat = (t['lat'] as num).toDouble();
      final tLng = (t['lng'] as num).toDouble();
      return _isInCone(originLat, originLng, heading, tLat, tLng, 60.0, 200);
    }).map((t) {
      final lat = (t['lat'] as num).toDouble();
      final lng = (t['lng'] as num).toDouble();
      final type = t['type'] as String? ?? 'TURN';
      final dist = (t['distance'] as num?)?.toDouble() ?? 0;
      final riskLevel = t['riskLevel'] as int? ?? 1;
      final isBlind = t['blind'] as bool? ?? false;
      final vehiclesHere = t['vehiclesNearby'] as bool? ?? false;
      final key = 'backend_${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
      if (_crossedTurnKeys.contains(key)) return null;

      Color bgColor;
      if (vehiclesHere && isBlind) {
        bgColor = Colors.red.shade900;
      } else if (riskLevel >= 4) {
        bgColor = Colors.red.shade700;
      } else if (riskLevel >= 2) {
        bgColor = Colors.orange.shade800;
      } else {
        bgColor = Colors.blue.shade800;
      }

      return Marker(
        point: LatLng(lat, lng),
        width: 100,
        height: 30,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white70, width: 1.5),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 4),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_buildTurnIcon(type), color: Colors.white, size: 14),
              const SizedBox(width: 4),
              Text(
                '${type.toUpperCase()} ${dist.toStringAsFixed(0)}m',
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
              ),
              if (vehiclesHere)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.directions_car, color: Colors.yellow, size: 11),
                ),
            ],
          ),
        ),
      );
    }).whereType<Marker>().toList();
  }

  List<Marker> _buildTurnMarkers(List<Map<String, dynamic>> turns) {
    final markers = <Marker>[];
    for (final turn in turns) {
      // FIX: Handle both frontend (intersectionLat/Lng) and backend (lat/lng) formats
      final lat = (turn['intersectionLat'] as num?)?.toDouble() ?? (turn['lat'] as num?)?.toDouble() ?? 0;
      final lng = (turn['intersectionLng'] as num?)?.toDouble() ?? (turn['lng'] as num?)?.toDouble() ?? 0;
      if (lat == 0 && lng == 0) continue;
      final type = turn['type']?.toString() ?? 'TURN';
      final dist = (turn['distance'] as num).toDouble();
      final key = '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
      final isCrossed = _crossedTurnKeys.contains(key);

      final isBend = type == 'left_bend' || type == 'right_bend';
      final bgColor = isBend ? Colors.red.shade700 : Colors.orange.shade800;
      final icon = _buildTurnIcon(type);

      markers.add(Marker(
        point: LatLng(lat, lng),
        width: 100,
        height: 30,
        child: Opacity(
          opacity: isCrossed ? 0.3 : 1.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.black87, width: 1.5),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 4),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 14),
                const SizedBox(width: 4),
                Text(
                  '${type.toUpperCase()} ${dist.toStringAsFixed(0)}m',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
    }
    return markers;
  }

  void _checkTurnCrossed() {
    // FIX: Check both frontend detected turns and backend upcoming turns
    final allActiveTurns = <Map<String, dynamic>>[
      ..._detectedTurns,
      ..._upcomingTurns.map((t) => {
        'intersectionLat': t['lat'],
        'intersectionLng': t['lng'],
        'distance': t['distance']?.toDouble() ?? 0,
        '_backend': true,
      }),
    ];
    if (_fusedPosition == null || allActiveTurns.isEmpty) return;
    for (final turn in allActiveTurns) {
      final lat = (turn['intersectionLat'] as num?)?.toDouble() ?? 0;
      final lng = (turn['intersectionLng'] as num?)?.toDouble() ?? 0;
      if (lat == 0 && lng == 0) continue;
      final key = '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
      if (_crossedTurnKeys.contains(key)) continue;
      final d = _distance(lat, lng, _fusedPosition!.latitude, _fusedPosition!.longitude);
      if (turn['_minDist'] == null) {
        turn['_minDist'] = d;
      } else {
        final prev = turn['_minDist'] as double;
        if (d < prev) turn['_minDist'] = d;
        if (prev < 10.0 && d > 25.0) {
          _crossedTurnKeys.add(key);
          // Also add backend variant of the key
          _crossedTurnKeys.add('backend_$key');
        }
      }
    }
    if (mounted) {
      setState(() {
        _turnDetectionMarkers = _buildTurnMarkers(_detectedTurns);
        _backendTurnMarkers = _buildBackendTurnMarkers(_upcomingTurns);
      });
    }
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
        DateTime.now().difference(_cachedRoadDataTime!).inSeconds > 60) {
      _onRoad = false;
      _snappedPosition = null;
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
      _sendTimer?.cancel();
      // FIX BUG #2: Pass JWT token as query parameter for WebSocket auth
      final wsUrlFuture = _getWsUrlWithToken();
      wsUrlFuture.then((wsUrl) async {
        _ws = WebSocketChannel.connect(Uri.parse(wsUrl));
        debugPrint('🔗 Connecting to WebSocket with auth');
        await _ws!.ready;
        debugPrint('✅ WebSocket connected successfully');
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
        // Start sending data every second
        _sendTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
          _sendWebSocket();
        });

        _ws!.stream.listen(
          (msg) {
            debugPrint('📥 WS Message: $msg');
            _handleWsMessage(msg);
          },

          onDone: () {
            debugPrint('ℹ️ WebSocket closed - attempting to reconnect...');
            if (!mounted) return;
            setState(() {
              _isConnected = false;
              _connectionStatus = 'Reconnecting...';
            });
            _reconnectWebSocket();
          },
          onError: (e) {
            debugPrint('❌ WebSocket error: $e - attempting to reconnect...');
            if (!mounted) return;
            setState(() {
              _isConnected = false;
              _connectionStatus = 'Connection Error';
            });
            _reconnectWebSocket();
          },
        );
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
    if (!mounted) return;
    _sendTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      debugPrint('🔄 Attempting to reconnect WebSocket...');
      _connectWebSocket();
    });
  }

  void _handleWsMessage(dynamic msg) {
    try {
      final String text = msg is String ? msg : msg.toString();
      final dynamic payload = jsonDecode(text);
      if (payload is! Map) return;

      // Sprint 1: Time sync from server response
      if (payload['serverTime'] is int) {
        _updateTimeOffset(payload['serverTime'] as int);
      }

      // Sprint 1: Extract map matching info from response
      if (payload['mapMatch'] is Map) {
        final mm = payload['mapMatch'] as Map;
        // Server-snapped position is authoritative
        debugPrint('🗺️ Server map match: road=${mm['roadId']} conf=${(mm['confidence'] * 100).toStringAsFixed(0)}%');
      }

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

      // Parse nearby vehicles from backend response (red dots on map)
      if (payload['nearbyVehicles'] is List) {
        final markers = (payload['nearbyVehicles'] as List).map((v) {
          return Marker(
            point: LatLng(
              (v['lat'] as num).toDouble(),
              (v['lng'] as num).toDouble(),
            ),
            child: Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: Colors.black26, blurRadius: 2),
                ],
              ),
            ),
          );
        }).toList();
        if (mounted) setState(() => _nearbyVehicleMarkers = markers);
      }

      // Extract Redis connection status
      if (payload['redisConnected'] is bool) {
        if (mounted) {
          setState(() => _redisConnected = payload['redisConnected'] as bool);
        }
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

        // Part 3: Build map markers from backend pre-computed database turns
        final backendMarkers = _buildBackendTurnMarkers(turns);
        if (mounted) {
          setState(() {
            _backendTurnMarkers = backendMarkers;
          });
        }

        // Part 4: Two-check verification — cross-reference frontend detection with backend DB
        // FIX: Compute detection confidence by matching frontend-detected turns against backend
        if (mounted) {
          final confidence = _computeTurnDetectionConfidence(_primaryTurn, turns);
          final multiRisk = _assessMultiVehicleRisk(turns, _activeThreats, _lastSpeed ?? 0);
          int vehiclesHere = 0;
          if (_primaryTurn != null) {
            final pLat = (_primaryTurn!['intersectionLat'] as num?)?.toDouble() ?? 0;
            final pLng = (_primaryTurn!['intersectionLng'] as num?)?.toDouble() ?? 0;
            if (pLat != 0) {
              for (final t in turns) {
                final tLat = (t['lat'] as num).toDouble();
                final tLng = (t['lng'] as num).toDouble();
                if (_distance(tLat, tLng, pLat, pLng) < 20) {
                  vehiclesHere = t['vehicleCount'] as int? ?? 0;
                  break;
                }
              }
            }
          }
          setState(() {
            _turnDetectionConfidence = confidence;
            _multiVehicleRisk = multiRisk;
            _vehiclesAtTurn = vehiclesHere;
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

      // Record every WebSocket exchange for session replay
      if (_sessionRecorder.isRecording && _lastSentData != null && payload is Map) {
        _sessionRecorder.recordExchange(
          sentPayload: _lastSentData!,
          serverResponse: payload.cast<String, dynamic>(),
          roundTripMs: (DateTime.now().millisecondsSinceEpoch - _lastClientSendTime).toDouble(),
          batteryPct: 100,
          networkType: _connectivityStatus.toString(),
          gpsAccuracy: _lastGpsAccuracy,
        );
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
    final String alertClass = threat['alertClass'] as String? ?? (severity >= 3 ? 'critical' : severity >= 2 ? 'high' : 'monitor');
    final double alertConfidence = (threat['alertConfidence'] as num?)?.toDouble() ?? (threat['collisionProbability'] as num?)?.toDouble() ?? 0;

    // Sprint 4: Session fatigue check
    if (_fatigue.shouldSuppress(alertConfidence)) {
      debugPrint('🔇 Alert suppressed by session fatigue (${_fatigue.alertsInWindow} in 60s)');
      return;
    }

    // Sprint 4: Safety mode filtering
    final String effectiveClass = _classifyWithMode(alertConfidence, _safetyMode);
    if (effectiveClass == 'ignore') {
      debugPrint('🔇 Alert suppressed by safety mode ($_safetyMode, conf=$alertConfidence)');
      return;
    }

    IconData icon;
    Color color;
    String classLabel;
    switch (effectiveClass) {
      case 'critical':
        icon = Icons.warning;
        color = Colors.red.shade700;
        classLabel = 'CRITICAL';
        break;
      case 'high':
        icon = Icons.warning_amber_rounded;
        color = Colors.deepOrange;
        classLabel = 'HIGH';
        break;
      case 'monitor':
        icon = Icons.info_outline;
        color = Colors.orange.shade700;
        classLabel = 'MONITOR';
        break;
      default:
        icon = Icons.info_outline;
        color = Colors.grey;
        classLabel = 'INFO';
    }

    // Haptic feedback based on alert class
    if (effectiveClass == 'critical') {
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 200), () { HapticFeedback.heavyImpact(); });
      Future.delayed(const Duration(milliseconds: 400), () { HapticFeedback.heavyImpact(); });
      SystemSound.play(SystemSoundType.alert);
    } else if (effectiveClass == 'high') {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    } else {
      HapticFeedback.lightImpact();
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(classLabel, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
            const SizedBox(width: 8),
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  if (alertConfidence > 0)
                    Text('${(alertConfidence * 100).toStringAsFixed(0)}% confidence', style: const TextStyle(fontSize: 11)),
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

  /// Classify alert based on confidence and safety mode
  String _classifyWithMode(double confidence, SafetyMode mode) {
    if (confidence >= mode.criticalThreshold) return 'critical';
    if (confidence >= mode.highThreshold) return 'high';
    if (confidence >= mode.monitorThreshold) return 'monitor';
    return 'ignore';
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

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _lastClientSendTime = nowMs;

    // Prefer snapped position when on road (more accurate)
    final effectiveLat = (_onRoad && _snappedPosition != null) ? _snappedPosition!.latitude : _fusedPosition!.latitude;
    final effectiveLng = (_onRoad && _snappedPosition != null) ? _snappedPosition!.longitude : _fusedPosition!.longitude;

    // Reject out-of-range coordinates to prevent backend corruption
    if (effectiveLat < -90 || effectiveLat > 90 || effectiveLng < -180 || effectiveLng > 180) {
      debugPrint('⚠️ Invalid coordinates rejected: $effectiveLat, $effectiveLng');
      return;
    }

    final payload = {
      "userId": user!['_id'],
      "latitude": effectiveLat,
      "longitude": effectiveLng,
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
      "turnAhead": _detectedTurns.isNotEmpty,
      "turns": _detectedTurns.map((t) => {
        "type": t['type'],
        "distance": (t['distance'] as double).round(),
        "angle": (t['angle'] as num?)?.round(),
        "lat": t['intersectionLat'],
        "lng": t['intersectionLng'],
        "riskLevel": t['riskLevel'] ?? 1,
      }).toList(),
      "turnType": _primaryTurn?['type'],
      "turnDistance": _primaryTurn?['distance'],
      "intersectionLat": _primaryTurn?['intersectionLat'],
      "intersectionLng": _primaryTurn?['intersectionLng'],
      // Sprint 1: New fields
      "positionUncertainty": _kalman.initialized ? _kalman.getUncertainty() : 10.0,
      "sensorQuality": _computeSensorQuality(),
      "clientTime": nowMs,
      "serverTime": nowMs + _timeOffset.round(),
      "timeSyncConfidence": _timeSyncConfidence,
      "gpsAccuracy": _lastGpsAccuracy,
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

      _turnDebug.lastWsPayload = payload;
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

  // ─── Session Recording ───

  String get _headingSourceName {
    if (_onRoad) return 'road';
    if (_usingGpsCourse) return 'gps';
    if (_hasCompassHeading) return 'compass';
    return 'none';
  }

  void _startSession() {
    _sessionSnapshots = [];
    _sessionStartTime = DateTime.now();
    _recordingSeconds = 0;
    _isRecording = true;
    _sessionRecorder.startRide();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordingSeconds++);
    });
    debugPrint('🔴 Session recording started');
  }

  Future<void> _stopSessionAndShare() async {
    _isRecording = false;
    _recordingTimer?.cancel();
    _recordingTimer = null;

    // Phase 1: Show ride outcome dialog
    Map<String, dynamic>? outcome;
    if (mounted) {
      outcome = await _showRideOutcomeDialog();
    }

    await _sessionRecorder.stopRide(outcome: outcome);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ride saved. Share from Profile page.')),
      );
      setState(() {});
    }
  }

  Future<Map<String, dynamic>> _showRideOutcomeDialog() async {
    bool nearMiss = false;
    int falseAlerts = 0;
    String? issue;
    final completer = Completer<Map<String, dynamic>>();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Ride Complete'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Duration: $_recordingSeconds s'),
                  Text('Snapshots: ${_sessionRecorder.snapshotCount}'),
                  const SizedBox(height: 16),
                  const Text('Any issues during this ride?'),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    title: const Text('Near miss (almost collided)'),
                    value: nearMiss,
                    onChanged: (v) => setDialogState(() => nearMiss = v ?? false),
                    dense: true,
                  ),
                  CheckboxListTile(
                    title: const Text('False alert (unnecessary warning)'),
                    value: falseAlerts > 0,
                    onChanged: (v) => setDialogState(() => falseAlerts = v == true ? (falseAlerts + 1) : 0),
                    dense: true,
                  ),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Other issues (optional)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => issue = v,
                    maxLines: 2,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    completer.complete({
                      'userReportedNearMiss': nearMiss,
                      'userReportedFalseAlert': falseAlerts,
                      'userReportedIssue': issue?.isNotEmpty == true ? issue : null,
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text('Submit'),
                ),
              ],
            );
          },
        );
      },
    );

    return completer.future;
  }

  void _captureSnapshot() {
    final elapsed = _sessionStartTime != null
        ? (DateTime.now().difference(_sessionStartTime!).inMilliseconds / 1000.0)
        : 0.0;
    final snapshot = _turnDebug.toSnapshot(
      lat: _fusedPosition?.latitude ?? _currentPosition?.latitude ?? 0,
      lng: _fusedPosition?.longitude ?? _currentPosition?.longitude ?? 0,
      speedMs: _lastSpeed ?? 0,
      headingDeg: _displayHeadingDeg,
      headingSource: _headingSourceName,
      activeThreats: List.from(_activeThreats),
      upcomingTurns: List.from(_upcomingTurns),
      turnInfo: _primaryTurn,
      elapsedSec: elapsed,
    );
    _sessionSnapshots.add(snapshot);
  }

  Future<List<File>> _getRecordingFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final sessionsDir = Directory('${dir.path}/sessions');
      if (!await sessionsDir.exists()) return [];
      final files = await sessionsDir.list().where(
        (f) => f is File && f.path.endsWith('.json') && f.path.contains('ride_'),
      ).cast<File>().toList();
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      return files;
    } catch (_) {
      return [];
    }
  }

  Future<void> _shareRecording(String filePath) async {
    try {
      await Share.shareXFiles([XFile(filePath)], subject: 'Safety App Debug Session');
    } catch (e) {
      debugPrint('❌ Failed to share recording: $e');
    }
  }

  Future<void> _deleteRecording(String filePath) async {
    try {
      await File(filePath).delete();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('❌ Failed to delete recording: $e');
    }
  }

  Future<void> _showRecordingsBottomSheet() async {
    final files = await _getRecordingFiles();
    if (!mounted || files.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No recordings found')),
        );
      }
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.folder_open, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  const Text('Saved Recordings', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: files.length > 5 ? 300 : files.length * 72.0,
                child: ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (_, i) {
                    final f = files[i];
                    final size = f.lengthSync();
                    final modified = f.lastModifiedSync();
                    final name = f.uri.pathSegments.last;
                    final sizeStr = size > 1024 ? '${(size / 1024).toStringAsFixed(1)} KB' : '${size} B';
                    return Card(
                      color: Colors.white10,
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        dense: true,
                        title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                        subtitle: Text('$sizeStr • ${modified.toString().substring(0, 19)}', style: const TextStyle(color: Colors.white38, fontSize: 10)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.share, color: Colors.blue, size: 18),
                              onPressed: () { Navigator.pop(ctx); _shareRecording(f.path); },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                              onPressed: () { _deleteRecording(f.path); Navigator.pop(ctx); },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
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
    _reconnectTimer?.cancel();
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
      if (_fusedPosition == null) {
        _turnDebug.skipReason = 'fusedPosition is null';
        return;
      }

      // FIX DRAWBACK 4: Faster, speed-adaptive intervals
      // REASON: At 60km/h, old 3s interval allowed 50m travel between checks
      // EXPECTED: At 60km/h → check every 2s or 20m, scan 200m radius
      final speed = _lastSpeed ?? 0;
      int minSeconds;
      double minDistance;
      if (speed > 13.9) {        // > 50 km/h
        minSeconds = 2;
        minDistance = 20;
      } else if (speed > 8.3) {  // > 30 km/h
        minSeconds = 4;
        minDistance = 20;
      } else if (speed > 4.2) {  // > 15 km/h
        minSeconds = 6;
        minDistance = 20;
      } else {
        minSeconds = 10;
        minDistance = 20;
      }

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

        _turnDebug.lastCheckTime = _lastTurnCheckTime;
        _turnDebug.timeSinceLastCheckSec = dt / 1000;
        _turnDebug.distSinceLastCheckM = moved;
        _turnDebug.speedMs = speed;
        _turnDebug.minIntervalSec = minSeconds;
        _turnDebug.minDistanceM = minDistance;
        _turnDebug.shouldRun = !(dt < minSeconds * 1000 && moved < minDistance);

        // OR condition: fire if EITHER enough time OR enough distance (skip only if BOTH below)
        if (dt < minSeconds * 1000 && moved < minDistance) {
          _turnDebug.skipReason = 'time=${(dt/1000).toStringAsFixed(1)}s < ${minSeconds}s AND dist=${moved.toStringAsFixed(1)}m < ${minDistance}m';
          return;
        }
      } else {
        _turnDebug.lastCheckTime = null;
        _turnDebug.shouldRun = true;
      }

      _turnDebug.skipReason = null;
      await _checkTurnAhead();
    } catch (e) {
      _turnDebug.skipReason = 'Exception: $e';
      debugPrint('❌ Turn check failed: $e');
    }
  }

  Future<void> _loadRoadCache() async {
    try {
      final box = Hive.box('roadCache');
      final cached = box.get('roadElements');
      final cachedTime = box.get('roadCacheTime');
      final cachedLat = box.get('roadCacheLat');
      final cachedLon = box.get('roadCacheLon');
      if (cached != null && cachedTime != null && cachedLat != null && cachedLon != null) {
        final age = DateTime.now().millisecondsSinceEpoch - (cachedTime as int);
        if (age < 24 * 60 * 60 * 1000) {
          _cachedRoadData = (cached as List).cast<dynamic>();
          _cachedRoadDataTime = DateTime.fromMillisecondsSinceEpoch(cachedTime);
          _lastRoadFetchPosition = LatLng(cachedLat as double, cachedLon as double);
          debugPrint('🗺️ Loaded ${_cachedRoadData!.length} roads from persistent cache');
        } else {
          debugPrint('🗺️ Persistent cache expired (age=${age ~/ 1000}s)');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Failed to load road cache: $e');
    }
  }

  Future<void> _saveRoadCache() async {
    if (_cachedRoadData == null || _lastRoadFetchPosition == null) return;
    try {
      final box = Hive.box('roadCache');
      await box.put('roadElements', _cachedRoadData);
      await box.put('roadCacheTime', DateTime.now().millisecondsSinceEpoch);
      await box.put('roadCacheLat', _lastRoadFetchPosition!.latitude);
      await box.put('roadCacheLon', _lastRoadFetchPosition!.longitude);
      debugPrint('🗺️ Saved ${_cachedRoadData!.length} roads to persistent cache');
    } catch (e) {
      debugPrint('⚠️ Failed to save road cache: $e');
    }
  }

  double _getScanRadius() {
    // FIX DRAWBACK 4: Speed-based scan radius with 200m cap
    // REASON: 150m max was too short for 60km/h (16.7m/s * 10s = 167m)
    // EXPECTED: At 60km/h → 200m radius detects junction 10s+ before arrival
    final speed = _lastSpeed ?? 0;
    if (speed > 13.9) return 200;   // > 50 km/h → 200m
    if (speed > 8.3)  return 150;   // > 30 km/h → 150m
    if (speed > 4.2)  return 100;   // > 15 km/h → 100m
    return 60;                      // slow speed
  }

  // Cache position for road data fetch-distance check
  LatLng? _lastRoadFetchPosition;

  Future<List<Map<String, dynamic>>> _detectTurnAhead() async {
    if (_fusedPosition == null) {
      _turnDebug.cacheTooOld = null;
      _turnDebug.usingCache = null;
      _turnDebug.httpStatus = null;
      _turnDebug.httpError = null;
      _turnDebug.roadsReturned = null;
      _turnDebug.fallbackUsed = null;
      return [];
    }

    final lat = _fusedPosition!.latitude;
    final lon = _fusedPosition!.longitude;
    final scanRadius = _getScanRadius();
    _turnDebug.scanRadius = scanRadius;

    if (_cachedRoadData != null && _lastRoadFetchPosition != null && _cachedRoadData!.isNotEmpty) {
      final distSinceFetch = _distance(
        lat, lon,
        _lastRoadFetchPosition!.latitude, _lastRoadFetchPosition!.longitude,
      );
      _turnDebug.hasCachedData = true;
      _turnDebug.cachedDataCount = _cachedRoadData!.length;
      _turnDebug.distSinceLastFetch = distSinceFetch;
      _turnDebug.cacheTooOld = distSinceFetch >= 20.0;
      if (distSinceFetch < 20.0) {
        _turnDebug.usingCache = true;
        debugPrint('🗺️ Using cached road data (moved ${distSinceFetch.toStringAsFixed(1)}m)');
        return _processTurnDataFromElements(_cachedRoadData!, lat, lon, scanRadius);
      } else {
        _turnDebug.usingCache = false;
      }
    } else {
      _turnDebug.hasCachedData = (_cachedRoadData != null && _cachedRoadData!.isNotEmpty);
      _turnDebug.cachedDataCount = (_cachedRoadData?.length ?? 0);
      _turnDebug.distSinceLastFetch = null;
      _turnDebug.cacheTooOld = null;
      _turnDebug.usingCache = false;
    }

    Map<String, dynamic>? data;
    _turnDebug.fallbackUsed = false;
    try {
      final url = Uri.parse(
        "${AppConfig.baseUrl}/api/nearby-roads"
        "?lat=$lat&lon=$lon&radius=$scanRadius",
      );
      _turnDebug.fetchUrl = url.toString();
      final res = await http.get(url).timeout(const Duration(seconds: 5));
      _turnDebug.httpStatus = res.statusCode;

      if (res.statusCode == 200) {
        data = jsonDecode(res.body);
        _turnDebug.roadsReturned = (data?['elements'] as List?)?.length ?? 0;
        debugPrint('✅ Nearby roads query succeeded: ${_turnDebug.roadsReturned} roads');
      } else {
        _turnDebug.httpError = 'Status ${res.statusCode}';
      }
    } catch (e) {
      _turnDebug.httpError = e.toString();
      _turnDebug.roadsReturned = null;
      debugPrint('⚠️ Nearby roads query failed: $e');

      // FIX DRAWBACK 6A: Try emergency cache before giving up
      // REASON: Network failure should not silently kill detection
      // EXPECTED: Uses last known road data for 5 min / 200m
      if (_emergencyRoadCache != null && _emergencyCacheTime != null) {
        final ageSec = DateTime.now().difference(_emergencyCacheTime!).inSeconds;
        final distM = _emergencyCachePosition != null
            ? _distance(lat, lon, _emergencyCachePosition!.latitude, _emergencyCachePosition!.longitude)
            : double.infinity;
        if (ageSec < 300 && distM < 200) {
          _turnDebug.fallbackUsed = true;
          _turnDetectionStatus = 'cached';
          debugPrint('🗺️ Emergency cache fallback (age=${ageSec}s, dist=${distM.toStringAsFixed(0)}m)');
          return _processTurnDataFromElements(_emergencyRoadCache!, lat, lon, scanRadius);
        }
      }

      // FIX DRAWBACK 6B: Then try primary cache
      if (_cachedRoadData != null && _cachedRoadData!.isNotEmpty) {
        _turnDebug.fallbackUsed = true;
        _turnDetectionStatus = 'cached';
        debugPrint('🗺️ Falling back to cached road data');
        return _processTurnDataFromElements(_cachedRoadData!, lat, lon, scanRadius);
      }

      _turnDetectionStatus = 'limited';
      debugPrint('⚠️ No cache available — turn detection limited');
      return [];
    }

    if (data != null && data['elements'] != null && (data['elements'] as List).isNotEmpty) {
      // FIX DRAWBACK 6C: Store successful fetch as emergency cache
      _emergencyRoadCache = List.from(data['elements']);
      _emergencyCachePosition = _fusedPosition;
      _emergencyCacheTime = DateTime.now();
      _turnDetectionStatus = 'fresh';

      _cachedRoadData = List.from(data['elements']);
      _cachedRoadDataTime = DateTime.now();
      _lastRoadFetchPosition = _fusedPosition;
      _saveRoadCache();
      return _processTurnDataFromElements(_cachedRoadData!, lat, lon, scanRadius);
    }

    debugPrint('⚠️ No roads found nearby');
    if (_cachedRoadData != null && _cachedRoadData!.isNotEmpty) {
      _turnDebug.fallbackUsed = true;
      _turnDetectionStatus = 'cached';
      debugPrint('🗺️ Falling back to cached road data');
      return _processTurnDataFromElements(_cachedRoadData!, lat, lon, scanRadius);
    }
    _turnDetectionStatus = 'limited';
    return [];
  }

  // FIX BUG 4: Deduplicate junctions within 15m
  List<Map<String, dynamic>> _deduplicateJunctions(List<Map<String, dynamic>> junctions) {
    final merged = <Map<String, dynamic>>[];
    for (final j in junctions) {
      final lat = j['intersectionLat'] as double;
      final lng = j['intersectionLng'] as double;
      final existing = merged.indexWhere((m) {
        final mLat = m['intersectionLat'] as double;
        final mLng = m['intersectionLng'] as double;
        return _distance(lat, lng, mLat, mLng) < 15.0;
      });
      if (existing >= 0) {
        final existingDist = merged[existing]['distance'] as double;
        if ((j['distance'] as double) < existingDist) {
          merged[existing] = j;
        }
        final dirs = {
          ...(merged[existing]['directions'] as List).cast<String>(),
          ...(j['directions'] as List).cast<String>(),
        };
        merged[existing]['directions'] = dirs.toList();
        final roads = {
          ...(merged[existing]['roads'] as List).cast<int>(),
          ...(j['roads'] as List).cast<int>(),
        };
        merged[existing]['roads'] = roads.toList();
        if (j['type'] == 'cross' || j['type'] == 't_junction') {
          merged[existing]['type'] = j['type'];
        }
      } else {
        merged.add(Map<String, dynamic>.from(j));
      }
    }
    return merged;
  }

  // FIX BUG 6: Check if a point is within a forward-facing cone
  bool _isInCone(double originLat, double originLng, double headingDeg,
      double targetLat, double targetLng, double coneAngleDeg, double maxRangeM) {
    final dist = _distance(originLat, originLng, targetLat, targetLng);
    if (dist > maxRangeM || dist < 1) return false;
    final bearing = _bearing(LatLng(originLat, originLng), LatLng(targetLat, targetLng));
    double diff = (bearing - headingDeg) % 360;
    if (diff > 180) diff -= 360;
    return diff.abs() <= coneAngleDeg / 2;
  }

  Future<List<Map<String, dynamic>>> _processTurnDataFromElements(
      List<dynamic> elements, double lat, double lon, double scanRadius) async {
    _turnDebug.phase1Entries.clear();
    _turnDebug.phase2Entries.clear();
    _turnDebug.elementsCount = elements.length;

    if (elements.isEmpty) return [];

    // ─── Build node-to-ways map from ALL elements ───
    final Map<int, List<int>> nodeToWays = {};
    final Map<int, List> otherGeoms = {};
    for (final el in elements) {
      if (el['type'] != 'way' || el['nodes'] == null) continue;
      final wId = el['id'] as int;
      for (final nid in (el['nodes'] as List).cast<int>()) {
        nodeToWays.putIfAbsent(nid, () => []).add(wId);
      }
      if (el['geometry'] != null) {
        otherGeoms[wId] = el['geometry'] as List;
      }
    }

    _turnDebug.nodeToWaysCount = nodeToWays.length;
    _turnDebug.waysCount = elements.where((e) => e['type'] == 'way').length;

    // ─── Find closest road to vehicle ───
    dynamic bestWay;
    int bestSegmentIndex = 0;
    double bestSegmentDist = double.infinity;

    for (final el in elements) {
      if (el['geometry'] == null) continue;
      final geom = el['geometry'] as List<dynamic>;
      if (geom.length < 2) continue;
      final pts = geom
          .map((p) => LatLng(p['lat'] as double, p['lon'] as double))
          .toList();
      for (int i = 0; i < pts.length - 1; i++) {
        final d = _distanceToSegment(lat, lon, pts[i], pts[i + 1]);
        if (d < bestSegmentDist) {
          bestSegmentDist = d;
          bestWay = el;
          bestSegmentIndex = i;
        }
      }
    }

    _turnDebug.bestWayId = bestWay?['id']?.toString();
    _turnDebug.bestWayHighway = bestWay?['highway']?.toString();
    _turnDebug.bestWayName = bestWay?['name']?.toString();
    _turnDebug.bestSegmentDist = bestSegmentDist;
    _turnDebug.bestSegmentIndex = bestSegmentIndex;

    if (bestWay == null) {
      _turnDebug.bestWayId = 'null';
      _turnDebug.detectResult = {"exists": false, "distance": null};
      return [];
    }

    // ─── Scan ALL roads for junctions ───
    final List<Map<String, dynamic>> allJunctions = [];
    bool? bestGoingForward;

    for (final el in elements) {
      if (el['geometry'] == null) continue;
      final geom = el['geometry'] as List<dynamic>;
      if (geom.length < 2) continue;
      final nodes = el['nodes'] as List?;
      if (nodes == null || nodes.isEmpty) continue;

      final roadId = el['id'] as int;
      final pts = geom
          .map((p) => LatLng(p['lat'] as double, p['lon'] as double))
          .toList();

      // Defensive: skip roads where nodes/geometry length mismatch
      if (nodes.length != pts.length) {
        debugPrint('⚠️ Road $roadId: nodes(${nodes.length}) != geometry(${pts.length}) — skipping');
        continue;
      }

      double minSegDist = double.infinity;
      int segIdx = 0;
      for (int i = 0; i < pts.length - 1; i++) {
        final d = _distanceToSegment(lat, lon, pts[i], pts[i + 1]);
        if (d < minSegDist) { minSegDist = d; segIdx = i; }
      }
      // FIX DRAWBACK 1: Use scanRadius instead of hardcoded 50
      // REASON: 50m skip caused roads at crossroad to be ignored
      // EXPECTED: All roads within scanRadius contribute to junction classification
      if (minSegDist > scanRadius) continue;

      final segBearing = _bearing(pts[segIdx], pts[segIdx + 1]);
      double hdgDiff = (_lastHeading ?? segBearing) - segBearing;
      if (hdgDiff > 180) hdgDiff -= 360;
      if (hdgDiff < -180) hdgDiff += 360;
      final goingForward = hdgDiff.abs() <= 90;

      // nodes.length == pts.length guaranteed by check above

      if (roadId == bestWay?['id']) {
        _turnDebug.goingForward = goingForward;
        _turnDebug.totalPoints = pts.length;
        _turnDebug.hasNodes = true;
        _turnDebug.nodeCount = nodes.length;
        _turnDebug.phase1Executed = true;
        bestGoingForward = goingForward;
      }

      // FIX DRAWBACK 2: Explicit forward/backward loops
      // REASON: Old loop with scanStart/scanLimit/scanStep had off-by-one errors
      // for short roads and segIdx=0 backward cases
      // EXPECTED: All nodes within scanRadius are scanned regardless of road length
      void scanNode(int j) {
        final dist = _distance(lat, lon, pts[j].latitude, pts[j].longitude);
        if (dist > scanRadius) return;

        final nodeId = nodes[j] as int;
        final waysHere = nodeToWays[nodeId] ?? [];
        final isJunction = waysHere.length > 1;

        if (roadId == bestWay?['id']) {
          _turnDebug.phase1Entries.add(Phase1Entry(
            nodeIndex: j,
            nodeId: nodeId,
            waysHere: waysHere.length,
            distance: dist,
            isJunction: isJunction,
          ));
        }

        if (!isJunction) return;

        // Approach bearing with proper edge case handling
        final approach = goingForward
            ? (j > 0 ? _bearing(pts[j - 1], pts[j]) : segBearing)
            : (j + 1 < pts.length ? _bearing(pts[j + 1], pts[j]) : (segBearing + 180) % 360);

        final sideRoads = <String>{};
        double? maxAngleDiff;

        for (final otherId in waysHere) {
          if (otherId == roadId) continue;
          final otherGeom = otherGeoms[otherId];
          if (otherGeom == null) continue;

          int otherIdx = -1;
          for (int k = 0; k < otherGeom.length; k++) {
            final og = otherGeom[k] as Map<String, dynamic>;
            final oLat = og['lat'] as double;
            final oLon = og['lon'] as double;
            if ((oLat - pts[j].latitude).abs() < 0.00001 &&
                (oLon - pts[j].longitude).abs() < 0.00001) {
              otherIdx = k;
              break;
            }
          }
          if (otherIdx < 0) continue;

          final dirIdx = otherIdx + 1 < otherGeom.length ? otherIdx + 1 : otherIdx - 1;
          if (dirIdx < 0 || dirIdx >= otherGeom.length) continue;

          final ogDir = otherGeom[dirIdx] as Map<String, dynamic>;
          final brg = _bearing(
            pts[j],
            LatLng(ogDir['lat'] as double, ogDir['lon'] as double),
          );

          double diff = (brg - approach) % 360;
          if (diff > 180) diff -= 360;

          if (maxAngleDiff == null || diff.abs() > maxAngleDiff.abs()) {
            maxAngleDiff = diff;
          }

          if (diff.abs() <= 30) {
            sideRoads.add("straight");
          } else if (diff > 30 && diff <= 150) {
            sideRoads.add("right");
          } else if (diff < -30 && diff >= -150) {
            sideRoads.add("left");
          }
        }

        final hasStraight = goingForward
            ? (j + 1 < pts.length)
            : (j > 0);
        final dirs = Set<String>.from(sideRoads);
        if (hasStraight) dirs.add("straight");

        // FIX DRAWBACK 1: Use pure function with complete direction set
        // FIX DRAWBACK 3: Add riskLevel from angle
        final type = classifyJunctionType(dirs, waysHere.length, hasStraight, maxAngleDiff);
        if (type == "straight") return;

        final riskLevel = getRiskLevelFromAngle(maxAngleDiff ?? 0);
        final alertDistanceM = getAlertDistanceFromRisk(riskLevel);

        if (roadId == bestWay?['id']) {
          _turnDebug.phase1Entries.last.junctionType = type;
          _turnDebug.phase1Entries.last.junctionDetails = {
            'approach': approach,
            'dirs': dirs.toList(),
            'sideRoads': sideRoads.toList(),
            'hasStraight': hasStraight,
            'angle': maxAngleDiff,
          };
        }

        allJunctions.add({
          "exists": true,
          "type": type,
          "distance": dist,
          "angle": maxAngleDiff ?? 0,
          "intersectionLat": pts[j].latitude,
          "intersectionLng": pts[j].longitude,
          "directions": dirs.toList(),
          "approachBearing": approach,
          "roads": waysHere,
          "roadId": roadId,
          "riskLevel": riskLevel,
          "alertDistanceM": alertDistanceM,
        });

        debugPrint('🚧 Junction found: $type (risk=$riskLevel) at ${dist.toStringAsFixed(1)}m on road $roadId');
      }

      if (goingForward) {
        for (int j = segIdx; j < pts.length; j++) {
          scanNode(j);
        }
        // FIX DRAWBACK 2: Also scan behind segIdx on the best road for short roads
        if (roadId == bestWay?['id']) {
          for (int j = segIdx - 1; j >= 0; j--) {
            scanNode(j);
          }
        }
      } else {
        // FIX DRAWBACK 2: Backward scan covers all indices including 0
        for (int j = segIdx; j >= 0; j--) {
          scanNode(j);
        }
        // FIX DRAWBACK 2: Also scan the other endpoint of closest segment for short roads
        if (segIdx + 1 < pts.length) {
          scanNode(segIdx + 1);
        }
      }
    }

    // Deduplicate by coordinate proximity
    final deduped = _deduplicateJunctions(allJunctions);

    final allTurns = deduped
      ..sort((a, b) => (a['distance'] as double).compareTo(b['distance'] as double));

    // ─── Cone filter: keep only turns within 60° forward cone ───
    final heading = _lastHeading ?? 0;
    final coneFiltered = allTurns.where((t) => _isInCone(
      lat, lon, heading,
      t['intersectionLat'] as double,
      t['intersectionLng'] as double,
      60.0,
      scanRadius,
    )).toList();

    // ─── Phase 2: Bend detection on the best way ───
    _turnDebug.phase2Executed = true;
    _turnDebug.bendThreshold = 30.0;
    _turnDebug.phase2Entries.clear();
    final List<Map<String, dynamic>> bendResults = [];

    if (bestWay != null && bestWay['geometry'] != null) {
      final bestGeom = bestWay['geometry'] as List<dynamic>;
      if (bestGeom.length >= 3) {
        final bestPts = bestGeom
            .map((p) => LatLng(p['lat'] as double, p['lon'] as double))
            .toList();

        int segCount = 0;
        double maxAngle = 0;

        // Scan in the direction of travel from current position
        final forward = bestGoingForward ?? true;
        final int iStart, iEnd, iStep;
        if (forward) {
          iStart = bestSegmentIndex;
          iEnd = bestPts.length - 2;
          iStep = 1;
        } else {
          iStart = bestSegmentIndex > 0 ? bestSegmentIndex - 1 : 0;
          iEnd = 1;
          iStep = -1;
          // FIX DRAWBACK 2: Also scan forward end for short roads in backward mode
        }

        for (int i = iStart; forward ? i < iEnd : i > iEnd; i += iStep) {
          final d = _distance(lat, lon, bestPts[i + 1].latitude, bestPts[i + 1].longitude);
          if (d > scanRadius) break;

          final b1 = _bearing(bestPts[i], bestPts[i + 1]);
          final b2 = _bearing(bestPts[i + 1], bestPts[i + 2]);
          double angleChange = (b2 - b1) % 360;
          if (angleChange > 180) angleChange -= 360;
          final absAngle = angleChange.abs();
          segCount++;

          if (absAngle > maxAngle) maxAngle = absAngle;

          final aboveThreshold = absAngle > (_turnDebug.bendThreshold ?? 30.0);
          _turnDebug.phase2Entries.add(Phase2Entry(
            segmentIndex: i,
            distance: d,
            bearing1: b1,
            bearing2: b2,
            angleChange: absAngle,
            aboveThreshold: aboveThreshold,
          ));

          if (aboveThreshold) {
            final bendLat = bestPts[i + 1].latitude;
            final bendLng = bestPts[i + 1].longitude;

            // FIX DRAWBACK 5: 60° cone filter for bends
            // REASON: Bends behind vehicle were reported as upcoming
            // EXPECTED: Only bends ahead in travel direction are reported
            if (!_isInCone(lat, lon, heading, bendLat, bendLng, 60.0, scanRadius)) {
              debugPrint('🗺️ Bend behind vehicle skipped: ${absAngle.toStringAsFixed(0)}° at ${d.toStringAsFixed(0)}m');
              continue;
            }

            final bendDir = angleChange > 0 ? "right" : "left";
            String bendType;
            if (absAngle > 90) {
              bendType = "sharp_${bendDir}_bend";
            } else if (absAngle > 60) {
              bendType = "moderate_${bendDir}_bend";
            } else {
              bendType = "gentle_${bendDir}_bend";
            }

            // FIX DRAWBACK 3: Add riskLevel for bends too
            final bendRisk = getRiskLevelFromAngle(absAngle);
            final bendAlertDist = getAlertDistanceFromRisk(bendRisk);

            bendResults.add({
              "exists": true,
              "type": bendType,
              "distance": d,
              "angle": absAngle,
              "intersectionLat": bendLat,
              "intersectionLng": bendLng,
              "directions": [bendDir],
              "approachBearing": b1,
              "roads": [bestWay['id']],
              "roadId": bestWay['id'],
              "isBend": true,
              "riskLevel": bendRisk,
              "alertDistanceM": bendAlertDist,
            });
          }
        }

        // FIX DRAWBACK 2: For short roads in backward mode, scan forward too
        if (!forward && bestSegmentIndex + 2 < bestPts.length) {
          final i = bestSegmentIndex;
          final d = _distance(lat, lon, bestPts[i + 1].latitude, bestPts[i + 1].longitude);
          if (d <= scanRadius) {
            final b1 = _bearing(bestPts[i], bestPts[i + 1]);
            final b2 = _bearing(bestPts[i + 1], bestPts[i + 2]);
            double angleChange = (b2 - b1) % 360;
            if (angleChange > 180) angleChange -= 360;
            final absAngle = angleChange.abs();
            if (absAngle > (_turnDebug.bendThreshold ?? 30.0)) {
              final bendLat = bestPts[i + 1].latitude;
              final bendLng = bestPts[i + 1].longitude;
              if (_isInCone(lat, lon, heading, bendLat, bendLng, 60.0, scanRadius)) {
                final bendDir = angleChange > 0 ? "right" : "left";
                String bendType;
                if (absAngle > 90) {
                  bendType = "sharp_${bendDir}_bend";
                } else if (absAngle > 60) {
                  bendType = "moderate_${bendDir}_bend";
                } else {
                  bendType = "gentle_${bendDir}_bend";
                }
                final bendRisk = getRiskLevelFromAngle(absAngle);
                bendResults.add({
                  "exists": true,
                  "type": bendType,
                  "distance": d,
                  "angle": absAngle,
                  "intersectionLat": bendLat,
                  "intersectionLng": bendLng,
                  "directions": [bendDir],
                  "approachBearing": b1,
                  "roads": [bestWay['id']],
                  "roadId": bestWay['id'],
                  "isBend": true,
                  "riskLevel": bendRisk,
                  "alertDistanceM": getAlertDistanceFromRisk(bendRisk),
                });
              }
            }
          }
        }

        _turnDebug.segmentsWithinRadius = segCount;
        _turnDebug.maxAngleChange = maxAngle;
        _turnDebug.bendDetected = bendResults.isNotEmpty;
        _turnDebug.phase2Result = bendResults.isNotEmpty
            ? '${bendResults.length} bend(s) found'
            : 'no bends';
      } else {
        _turnDebug.segmentsWithinRadius = 0;
        _turnDebug.maxAngleChange = 0;
        _turnDebug.bendDetected = false;
        _turnDebug.phase2Result = 'insufficient points (< 3)';
      }
    } else {
      _turnDebug.segmentsWithinRadius = 0;
      _turnDebug.maxAngleChange = 0;
      _turnDebug.bendDetected = false;
      _turnDebug.phase2Result = 'no best way';
    }

    // Merge Phase 1 (cone-filtered) and Phase 2 (bend) results, deduplicate, sort
    final mergedTurns = [...coneFiltered, ...bendResults];
    final merged = _deduplicateJunctions(mergedTurns);
    merged.sort((a, b) => (a['distance'] as double).compareTo(b['distance'] as double));

    _turnDebug.phase1EarlyReturned = false;
    _turnDebug.detectResult = merged.isNotEmpty ? merged.first : {"exists": false, "distance": null};
    _turnDebug.turnExists = merged.isNotEmpty;
    _turnDebug.turnType = merged.isNotEmpty ? merged.first['type']?.toString() : null;
    _turnDebug.turnDistance = merged.isNotEmpty ? merged.first['distance']?.toDouble() : null;
    _turnDebug.allJunctionsCount = allJunctions.length;
    _turnDebug.dedupedJunctionsCount = deduped.length;
    _turnDebug.filteredJunctionsCount = coneFiltered.length;
    _turnDebug.finalTurns = merged;

    if (merged.isNotEmpty) {
      debugPrint('🚧 ${merged.length} turn(s) ahead: ${merged.map((t) => '${t['type']} @ ${(t['distance'] as double).toStringAsFixed(1)}m risk=${t['riskLevel']}').join(', ')}');
    }

    return merged;
  }

  // FIX Part 4: Two-check collision verification
  // Cross-references frontend geometry detection with backend pre-computed database
  double _computeTurnDetectionConfidence(
    Map<String, dynamic>? frontendTurn,
    List<Map<String, dynamic>> backendTurns,
  ) {
    if (frontendTurn == null) return 0.0;
    if (backendTurns.isEmpty) return 0.3;

    final fLat = (frontendTurn['intersectionLat'] as num?)?.toDouble() ?? 0;
    final fLng = (frontendTurn['intersectionLng'] as num?)?.toDouble() ?? 0;
    if (fLat == 0 && fLng == 0) return 0.0;

    for (final bt in backendTurns) {
      final bLat = (bt['lat'] as num).toDouble();
      final bLng = (bt['lng'] as num).toDouble();
      final dist = _distance(fLat, fLng, bLat, bLng);
      if (dist < 15.0) {
        // Same junction detected by both methods → HIGH confidence
        return (0.7 + (0.3 * (1.0 - (dist / 15.0)))).clamp(0.7, 1.0);
      }
    }
    return 0.3;
  }

  // FIX Part 4: Multi-vehicle collision risk assessment
  // Checks every vehicle near each junction, not just pairwise
  int _assessMultiVehicleRisk(
    List<Map<String, dynamic>> backendTurns,
    List<Map<String, dynamic>> activeThreats,
    double speedMs,
  ) {
    int maxRisk = 0;

    for (final turn in backendTurns) {
      final vehicleCount = turn['vehicleCount'] as int? ?? 0;
      final riskLevel = turn['riskLevel'] as int? ?? 1;

      if (vehicleCount >= 3) {
        maxRisk = maxRisk < 5 ? 5 : maxRisk;
      } else if (vehicleCount >= 2) {
        maxRisk = maxRisk < (riskLevel + 1).clamp(1, 5) ? (riskLevel + 1).clamp(1, 5) : maxRisk;
      } else if (vehicleCount >= 1) {
        maxRisk = maxRisk < riskLevel ? riskLevel : maxRisk;
      }
    }

    final turnCollisionThreats = activeThreats.where((t) =>
      t['type'] == 'turn_collision' || t['type'] == 'intersection_collision'
    ).toList();

    if (turnCollisionThreats.length >= 2) {
      maxRisk = maxRisk < 5 ? 5 : maxRisk;
    } else if (turnCollisionThreats.length >= 1) {
      maxRisk = maxRisk < 4 ? 4 : maxRisk;
    }

    return maxRisk;
  }
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
      final turns = await _detectTurnAhead();
      _lastTurnCheckTime = now;
      _lastTurnCheckPosition = _fusedPosition;

      _detectedTurns = turns;
      _primaryTurn = turns.isNotEmpty ? turns.first : null;

      _turnDebug.detectResult = turns.isNotEmpty ? turns.first : null;
      _turnDebug.turnInfoApplied = _primaryTurn ?? {"exists": false, "distance": null};
      _turnDebug.turnExists = turns.isNotEmpty;
      _turnDebug.turnType = turns.isNotEmpty ? turns.first['type']?.toString() : null;
      _turnDebug.turnDistance = turns.isNotEmpty ? turns.first['distance']?.toDouble() : null;

      if (mounted && _isRecording) {
        _captureSnapshot();
      }

      if (mounted) {
        setState(() {
          if (turns.isNotEmpty) {
            for (final t in turns) {
              final lat = (t['intersectionLat'] as num).toDouble();
              final lng = (t['intersectionLng'] as num).toDouble();
              final key = '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
              if (!_crossedTurnKeys.contains(key) && t['_minDist'] == null) {
                t['_minDist'] = _distance(lat, lng,
                    _fusedPosition!.latitude, _fusedPosition!.longitude);
              }
            }
          }
          _turnDetectionMarkers = _buildTurnMarkers(turns);
        });
      }
    } catch (e) {
      _turnDebug.httpError = 'Exception in _checkTurnAhead: $e';
      _turnDebug.turnInfoApplied = {"exists": false, "distance": null};
      _turnDebug.turnExists = false;
      debugPrint('❌ _checkTurnAhead error: $e');
      if (mounted) {
        setState(() {
          _primaryTurn = null;
          _detectedTurns = [];
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
                          const SizedBox(width: 6),
                          // Redis Status
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _redisConnected ? Colors.green : Colors.red,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _redisConnected ? Icons.storage : Icons.storage_outlined,
                                  color: Colors.white,
                                  size: 14,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  _redisConnected ? 'DB' : 'DB',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
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
                          const SizedBox(width: 6),
                          // Sprint 4: Safety mode toggle
                          GestureDetector(
                            onTap: () {
                              final modes = SafetyMode.values;
                              final idx = (modes.indexOf(_safetyMode) + 1) % modes.length;
                              setState(() => _safetyMode = modes[idx]);
                              _fatigue.reset();
                              debugPrint('🛡️ Safety mode: ${_safetyMode.label}');
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _safetyMode == SafetyMode.conservative
                                    ? Colors.green.withOpacity(0.8)
                                    : _safetyMode == SafetyMode.balanced
                                        ? Colors.blue.withOpacity(0.8)
                                        : Colors.red.withOpacity(0.8),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _safetyMode == SafetyMode.conservative
                                        ? Icons.shield
                                        : _safetyMode == SafetyMode.balanced
                                            ? Icons.shield_outlined
                                            : Icons.flash_on,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _safetyMode.label,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // FIX DRAWBACK 6D: Turn detection status indicator
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: _turnDetectionStatus == 'fresh' ? Colors.green
                                   : _turnDetectionStatus == 'cached' ? Colors.orange
                                   : Colors.red,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _turnDetectionStatus == 'fresh' ? Icons.brightness_1
                                      : _turnDetectionStatus == 'cached' ? Icons.brightness_medium
                                      : Icons.brightness_2,
                                  color: Colors.white,
                                  size: 12,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  _turnDetectionStatus == 'fresh' ? 'T'
                                      : _turnDetectionStatus == 'cached' ? 'T~'
                                      : 'T!',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
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
                // Active threat banners (above map) — Sprint 4: alert class based
                if (_activeThreats.isNotEmpty)
                  Positioned(
                    top: 76,
                    left: 8,
                    right: 8,
                    child: Column(
                      children: _activeThreats.map((t) {
                        final String alertClass = t['alertClass'] as String? ?? (t['severity'] ?? 1) >= 3 ? 'critical' : 'high';
                        final msg = t['message'] ?? 'Collision risk';
                        final double conf = (t['alertConfidence'] as num?)?.toDouble() ?? 0;

                        Color bgColor;
                        IconData icon;
                        switch (alertClass) {
                          case 'critical':
                            bgColor = Colors.red.shade700;
                            icon = Icons.warning;
                            break;
                          case 'high':
                            bgColor = Colors.deepOrange;
                            icon = Icons.warning_amber_rounded;
                            break;
                          case 'monitor':
                            bgColor = Colors.orange.shade700;
                            icon = Icons.info_outline;
                            break;
                          default:
                            bgColor = Colors.grey.shade700;
                            icon = Icons.info;
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
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(msg, style: const TextStyle(color: Colors.white, fontSize: 13)),
                                    if (conf > 0)
                                      Text('${(conf * 100).toStringAsFixed(0)}% | $alertClass',
                                        style: const TextStyle(color: Colors.white70, fontSize: 10)),
                                  ],
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
                      if (_showBoundingBox)
                        PolygonLayer(
                          polygons: [
                            Polygon<Object>(
                              points: const [
                                LatLng(17.305, 78.495),
                                LatLng(17.305, 78.625),
                                LatLng(17.445, 78.625),
                                LatLng(17.445, 78.495),
                              ],
                              color: Colors.blue.withValues(alpha: 0.15),
                              borderColor: Colors.blue,
                              borderStrokeWidth: 2.5,
                              label: 'Detection Zone',
                            ),
                          ],
                        ),
                      if (_nearbyVehicleMarkers.isNotEmpty)
                        MarkerLayer(markers: _nearbyVehicleMarkers),
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
                      // Part 3: Turn markers — frontend (geometry) + backend (DB) merged
                      if (_turnDetectionMarkers.isNotEmpty || _backendTurnMarkers.isNotEmpty)
                        MarkerLayer(markers: [..._turnDetectionMarkers, ..._backendTurnMarkers]),
                    ],
                  ),
                ),
                // Bounding box toggle
                Positioned(
                  top: _activeThreats.isNotEmpty ? 140 : 80,
                  left: 8,
                  child: FloatingActionButton.small(
                    heroTag: 'bbox_toggle',
                    onPressed: () =>
                        setState(() => _showBoundingBox = !_showBoundingBox),
                    backgroundColor:
                        _showBoundingBox ? Colors.blue : Colors.grey[300],
                    tooltip: _showBoundingBox
                        ? 'Hide detection zone'
                        : 'Show detection zone',
                    child: Icon(
                      Icons.aspect_ratio,
                      color: _showBoundingBox
                          ? Colors.white
                          : Colors.grey[700],
                    ),
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
                // Debug Overlay Button
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
                      _showDataViewer ? Icons.close : Icons.bug_report,
                    ),
                  ),
                ),
                // Debug Overlay (covers screen when open)
                if (_showDataViewer)
                  Positioned(
                    top: 80,
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: DebugOverlay(
                          debug: _turnDebug,
                          lastSentData: _lastSentData,
                          activeThreats: _activeThreats,
                          upcomingTurns: _upcomingTurns,
                          isConnected: _isConnected,
                          connectionStatus: _connectionStatus,
                          isSendingData: _isSendingData,
                          displayHeadingDeg: _displayHeadingDeg,
                          onRoad: _onRoad,
                          headingRaw: _lastHeading,
                          hasCompassHeading: _hasCompassHeading,
                          usingGpsCourse: _usingGpsCourse,
                          pendingMessagesCount: _pendingMessages.length,
                          turnExists: _detectedTurns.isNotEmpty,
                          turnType: _primaryTurn?['type']?.toString(),
                          turnDistance: _primaryTurn?['distance']?.toDouble(),
                          turnInfo: _primaryTurn,
                          detectedTurns: _detectedTurns,
                          onClose: () {
                            setState(() {
                              _showDataViewer = false;
                            });
                          },
                          isRecording: _isRecording,
                          recordingSeconds: _recordingSeconds,
                          snapshotCount: _sessionSnapshots.length,
                          onStartRecording: _startSession,
                          onStopRecording: _stopSessionAndShare,
                          onListRecordings: _showRecordingsBottomSheet,
                      ),
                  ),
                // ─── Turn/junction info card at bottom ───
                if (_showTurnPanel && _primaryTurn != null)
                  Positioned(
                    bottom: 8,
                    left: 16,
                    right: 16,
                    child: AnimatedOpacity(
                      opacity: 1.0,
                      duration: const Duration(milliseconds: 300),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: _primaryTurn!['type'] == 'left_bend' || _primaryTurn!['type'] == 'right_bend'
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
                            Column(
                              children: [
                                Icon(
                                  _buildTurnIcon(_primaryTurn!['type']),
                                  color: Colors.white,
                                  size: 28,
                                ),
                                // Part 4: Multi-vehicle indicator below icon
                                if (_vehiclesAtTurn > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: Colors.yellow.shade700,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.directions_car, color: Colors.white, size: 10),
                                          const SizedBox(width: 2),
                                          Text(
                                            '$_vehiclesAtTurn',
                                            style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
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
                                  if (_primaryTurn!['distance'] != null)
                                    Text(
                                      '${(_primaryTurn!['distance'] as double).toStringAsFixed(0)}m ahead',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.9),
                                        fontSize: 13,
                                      ),
                                    ),
                                  // Part 4: Detection confidence bar
                                  if (_turnDetectionConfidence > 0)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 50,
                                            height: 4,
                                            decoration: BoxDecoration(
                                              color: Colors.white24,
                                              borderRadius: BorderRadius.circular(2),
                                            ),
                                            child: FractionallySizedBox(
                                              alignment: Alignment.centerLeft,
                                              widthFactor: _turnDetectionConfidence.clamp(0.0, 1.0),
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: _turnDetectionConfidence >= 0.7 ? Colors.greenAccent : Colors.orangeAccent,
                                                  borderRadius: BorderRadius.circular(2),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${(_turnDetectionConfidence * 100).toStringAsFixed(0)}%',
                                            style: const TextStyle(color: Colors.white54, fontSize: 9),
                                          ),
                                        ],
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
                if (_showTurnPanel && _upcomingTurns.isNotEmpty)
                  Positioned(
                    bottom: 80,
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
                                final vehicleCount = turn['vehicleCount'] as int? ?? 0;
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
                                      // Part 4: Multi-vehicle indicator
                                      if (vehicleCount > 0)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 4),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: Colors.yellow.shade800,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(Icons.directions_car, color: Colors.white, size: 9),
                                                const SizedBox(width: 2),
                                                Text(
                                                  '$vehicleCount',
                                                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                                                ),
                                              ],
                                            ),
                                          ),
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
                // ─── Frontend-detected additional turns (2nd, 3rd) ───
                if (_showTurnPanel && _detectedTurns.length > 1)
                  Positioned(
                    bottom: 80,
                    left: 16,
                    right: 16,
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 80),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.4),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'NEXT TURNS',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Flexible(
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: _detectedTurns.length - 1,
                              itemBuilder: (context, idx) {
                                final i = idx + 1;
                                final turn = _detectedTurns[i];
                                final type = turn['type'] as String? ?? '?';
                                final dist = (turn['distance'] as double?)?.toInt() ?? 0;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 1),
                                  child: Row(
                                    children: [
                                      Icon(_buildTurnIcon(type), color: Colors.orange, size: 12),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          _formatTurnType(type),
                                          style: const TextStyle(
                                            color: Colors.orangeAccent,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '${dist}m',
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 10,
                                        ),
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
                // ─── Turn panel toggle button ───
                Positioned(
                  bottom: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: () => setState(() => _showTurnPanel = !_showTurnPanel),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _showTurnPanel ? Colors.white.withOpacity(0.9) : Colors.orange.withOpacity(0.9),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: _showTurnPanel ? Colors.grey : Colors.orange, width: 1.5),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _showTurnPanel ? Icons.visibility_off : Icons.turn_left,
                              color: _showTurnPanel ? Colors.black87 : Colors.white,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _showTurnPanel ? 'HIDE TURNS' : 'SHOW TURNS',
                              style: TextStyle(
                                color: _showTurnPanel ? Colors.black87 : Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  String _buildTurnTitle() {
    final type = _primaryTurn?['type'] as String?;
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
