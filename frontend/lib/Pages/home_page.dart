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
          final vxTarget = speed * sin(hRad);
          final vyTarget = speed * cos(hRad);
      const velGain = 0.3;
      vLat += velGain * (vxTarget - vLat);
      vLon += velGain * (vyTarget - vLon);
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
  Timer? _reconnectTimer;

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
  Map<String, dynamic>?
  _turnInfo; // { exists, type, distance, intersectionLat, intersectionLng }
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

        // Phase 1: Record exchange for session replay
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
      "turnAhead": _turnInfo?['exists'] ?? false,
      "turnType": _turnInfo?['type'],
      "turnDistance": _turnInfo?['distance'],
      "intersectionLat": _turnInfo?['intersectionLat'],
      "intersectionLng": _turnInfo?['intersectionLng'],
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
      turnInfo: _turnInfo,
      elapsedSec: elapsed,
    );
    _sessionSnapshots.add(snapshot);
  }

  Future<List<File>> _getRecordingFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final sessionsDir = Directory('${dir.path}/debug_sessions');
      if (!await sessionsDir.exists()) return [];
      final files = await sessionsDir.list().where(
        (f) => f is File && f.path.endsWith('.json') && f.path.contains('safety_session_'),
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

        _turnDebug.lastCheckTime = _lastTurnCheckTime;
        _turnDebug.timeSinceLastCheckSec = dt / 1000;
        _turnDebug.distSinceLastCheckM = moved;
        _turnDebug.speedMs = speed;
        _turnDebug.minIntervalSec = minSeconds;
        _turnDebug.minDistanceM = minDistance;
        _turnDebug.shouldRun = !(dt < minSeconds * 1000 && moved < minDistance);

        // OR condition — check if EITHER enough time passed OR enough distance moved
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

  double _getScanRadius() {
    final speed = _lastSpeed ?? 0;
    if (speed > 13.9) return 150;   // > 50 km/h
    if (speed > 8.3)  return 100;   // > 30 km/h
    return 60;                      // slow speed
  }

  // Cache position for road data fetch-distance check
  LatLng? _lastRoadFetchPosition;

  Future<Map<String, dynamic>?> _detectTurnAhead() async {
    if (_fusedPosition == null) {
      _turnDebug.cacheTooOld = null;
      _turnDebug.usingCache = null;
      _turnDebug.httpStatus = null;
      _turnDebug.httpError = null;
      _turnDebug.roadsReturned = null;
      _turnDebug.fallbackUsed = null;
      return null;
    }

    final lat = _fusedPosition!.latitude;
    final lon = _fusedPosition!.longitude;
    final scanRadius = _getScanRadius();
    _turnDebug.scanRadius = scanRadius;

    // FIX BUG #36: Use cached road data if within 20m of last fetch
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
      if (_cachedRoadData != null && _cachedRoadData!.isNotEmpty) {
        _turnDebug.fallbackUsed = true;
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
      _turnDebug.fallbackUsed = true;
      debugPrint('🗺️ Falling back to cached road data');
      return _processTurnDataFromElements(_cachedRoadData!, lat, lon, scanRadius);
    }
    return null;
  }

  Future<Map<String, dynamic>?> _processTurnDataFromElements(List<dynamic> elements, double lat, double lon, double scanRadius) async {
    _turnDebug.phase1Entries.clear();
    _turnDebug.phase2Entries.clear();
    _turnDebug.elementsCount = elements.length;

    dynamic bestWay;
    int bestSegmentIndex = 0;
    double bestSegmentDist = double.infinity;

    for (final el in elements) {
      if (el['geometry'] == null) continue;
      final geom = el['geometry'] as List<dynamic>;
      if (geom.length < 2) continue;

      final points = geom
          .map((p) => LatLng(p['lat'] as double, p['lon'] as double))
          .toList();

      for (int i = 0; i < points.length - 1; i++) {
        final p1 = points[i];
        final p2 = points[i + 1];
        final distToSegment = _distanceToSegment(lat, lon, p1, p2);
        if (distToSegment < bestSegmentDist) {
          bestSegmentDist = distToSegment;
          bestWay = el;
          bestSegmentIndex = i;
        }
      }
    }

    if (bestWay == null) {
      _turnDebug.bestWayId = 'null';
      debugPrint('⚠️ No suitable way found');
      _turnDebug.detectResult = {'error': 'No suitable way found'};
      return null;
    }

    _turnDebug.bestWayId = bestWay['id']?.toString();
    _turnDebug.bestWayHighway = bestWay['highway']?.toString();
    _turnDebug.bestWayName = bestWay['name']?.toString();
    _turnDebug.bestSegmentDist = bestSegmentDist;
    _turnDebug.bestSegmentIndex = bestSegmentIndex;

    final geom = bestWay['geometry'] as List<dynamic>;
    if (geom.length < 2) {
      _turnDebug.detectResult = {'error': 'Geometry too short'};
      return null;
    }

    final points = geom
        .map((p) => LatLng(p['lat'] as double, p['lon'] as double))
        .toList();

    final nodes = bestWay['nodes'] as List?;
    int startIndex = bestSegmentIndex;

    final segBearing = _bearing(points[startIndex], points[startIndex + 1]);
    double headingDiff = (_lastHeading ?? segBearing) - segBearing;
    if (headingDiff > 180) headingDiff -= 360;
    if (headingDiff < -180) headingDiff += 360;
    final goingForward = headingDiff.abs() <= 90;
    _turnDebug.goingForward = goingForward;
    _turnDebug.totalPoints = points.length;

    // ─── PHASE 1: Junction detection ───
    if (nodes != null && nodes.isNotEmpty) {
      _turnDebug.phase1Executed = true;
      _turnDebug.hasNodes = true;
      _turnDebug.nodeCount = nodes.length;

      final Map<int, List<int>> nodeToWays = {};
      final bestWayId = bestWay['id'] as int;
      for (final el in elements) {
        if (el['type'] != 'way' || el['nodes'] == null) continue;
        final wId = el['id'] as int;
        for (final nid in (el['nodes'] as List).cast<int>()) {
          nodeToWays.putIfAbsent(nid, () => []).add(wId);
        }
      }

      final Map<int, List> otherGeoms = {};
      for (final el in elements) {
        if (el['type'] == 'way' && el['id'] != bestWayId && el['geometry'] != null) {
          otherGeoms[el['id'] as int] = el['geometry'] as List;
        }
      }

      _turnDebug.nodeToWaysCount = nodeToWays.length;
      _turnDebug.waysCount = elements.where((e) => e['type'] == 'way').length;

      final int scanLimit = goingForward
          ? (nodes.length < points.length ? nodes.length : points.length)
          : 0;
      final int scanStep = goingForward ? 1 : -1;

      for (int j = startIndex; goingForward ? j < scanLimit : j >= scanLimit; j += scanStep) {
        final dist = _distance(lat, lon, points[j].latitude, points[j].longitude);
        if (dist > scanRadius) break;

        final nodeId = nodes[j] as int;
        final waysHere = nodeToWays[nodeId] ?? [];
        final isJunction = waysHere.length > 1;

        _turnDebug.phase1Entries.add(Phase1Entry(
          nodeIndex: j,
          nodeId: nodeId,
          waysHere: waysHere.length,
          distance: dist,
          isJunction: isJunction,
        ));

        if (!isJunction) continue;

        final approach = goingForward
            ? _bearing(points[j > 0 ? j - 1 : 0], points[j])
            : _bearing(points[j + 1 < points.length ? j + 1 : points.length - 1], points[j]);

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

        final hasStraight = goingForward
            ? (j + 1 < points.length)
            : (j > 0);
        final dirs = Set<String>.from(sideRoads);
        if (hasStraight) dirs.add("straight");

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

        _turnDebug.phase1Entries.last.junctionType = type;
        _turnDebug.phase1Entries.last.junctionDetails = {
          'approach': approach,
          'dirs': dirs.toList(),
          'sideRoads': sideRoads.toList(),
          'hasStraight': hasStraight,
        };

        _turnDebug.phase1EarlyReturned = true;
        _turnDebug.phase1ReturnType = type;
        _turnDebug.phase1ReturnDist = dist;

        debugPrint('🚧 Phase1 early return: $type at ${dist.toStringAsFixed(1)}m — $dirs');
        final result = {
          "exists": true,
          "type": type,
          "distance": dist,
          "intersectionLat": points[j].latitude,
          "intersectionLng": points[j].longitude,
        };
        _turnDebug.detectResult = result;
        return result;
      }
    } else {
      _turnDebug.phase1Executed = true;
      _turnDebug.hasNodes = false;
      _turnDebug.nodeCount = nodes?.length ?? 0;
    }

    // ─── PHASE 2: Road bend detection ───
    _turnDebug.phase2Executed = true;
    _turnDebug.bendThreshold = 45.0;
    _turnDebug.maxAngleChange = 0;
    _turnDebug.segmentsWithinRadius = 0;

    if (goingForward) {
      for (int j = startIndex; j + 2 < points.length; j++) {
        final dist = _distance(lat, lon, points[j + 1].latitude, points[j + 1].longitude);
        if (dist > scanRadius) break;

        _turnDebug.segmentsWithinRadius = (_turnDebug.segmentsWithinRadius ?? 0) + 1;

        final b1 = _bearing(points[j], points[j + 1]);
        final b2 = _bearing(points[j + 1], points[j + 2]);
        double angleChange = b2 - b1;
        if (angleChange > 180) angleChange -= 360;
        if (angleChange < -180) angleChange += 360;

        final above = angleChange.abs() >= 45.0;
        if (angleChange.abs() > (_turnDebug.maxAngleChange ?? 0)) {
          _turnDebug.maxAngleChange = angleChange.abs();
        }

        _turnDebug.phase2Entries.add(Phase2Entry(
          segmentIndex: j,
          distance: dist,
          bearing1: b1,
          bearing2: b2,
          angleChange: angleChange,
          aboveThreshold: above,
        ));

        if (above) {
          final type = angleChange > 0 ? "right_bend" : "left_bend";
          _turnDebug.bendDetected = true;
          _turnDebug.phase2Result = '$type at ${dist.toStringAsFixed(1)}m';
          debugPrint('↩️ $type at ${dist.toStringAsFixed(1)}m (angle: ${angleChange.toStringAsFixed(1)}°)');
          final result = {
            "exists": true,
            "type": type,
            "distance": dist,
            "intersectionLat": points[j + 1].latitude,
            "intersectionLng": points[j + 1].longitude,
          };
          _turnDebug.detectResult = result;
          return result;
        }
      }
    } else {
      for (int j = startIndex; j >= 2; j--) {
        final dist = _distance(lat, lon, points[j - 1].latitude, points[j - 1].longitude);
        if (dist > scanRadius) break;

        _turnDebug.segmentsWithinRadius = (_turnDebug.segmentsWithinRadius ?? 0) + 1;

        final b1 = _bearing(points[j], points[j - 1]);
        final b2 = _bearing(points[j - 1], points[j - 2]);
        double angleChange = b2 - b1;
        if (angleChange > 180) angleChange -= 360;
        if (angleChange < -180) angleChange += 360;

        final above = angleChange.abs() >= 45.0;
        if (angleChange.abs() > (_turnDebug.maxAngleChange ?? 0)) {
          _turnDebug.maxAngleChange = angleChange.abs();
        }

        _turnDebug.phase2Entries.add(Phase2Entry(
          segmentIndex: j,
          distance: dist,
          bearing1: b1,
          bearing2: b2,
          angleChange: angleChange,
          aboveThreshold: above,
        ));

        if (above) {
          final type = angleChange > 0 ? "right_bend" : "left_bend";
          _turnDebug.bendDetected = true;
          _turnDebug.phase2Result = '$type at ${dist.toStringAsFixed(1)}m';
          final result = {
            "exists": true,
            "type": type,
            "distance": dist,
            "intersectionLat": points[j - 1].latitude,
            "intersectionLng": points[j - 1].longitude,
          };
          _turnDebug.detectResult = result;
          return result;
        }
      }
    }

    _turnDebug.bendDetected = false;
    _turnDebug.phase2Result = 'No angle ≥ 45° (max: ${_turnDebug.maxAngleChange?.toStringAsFixed(1)}°)';
    final noneResult = {"exists": false, "distance": null};
    _turnDebug.detectResult = noneResult;
    return noneResult;
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

      _turnDebug.detectResult = result;
      _turnDebug.turnInfoApplied = result ?? {"exists": false, "distance": null};
      _turnDebug.turnExists = result?['exists'] == true;
      _turnDebug.turnType = result?['type']?.toString();
      _turnDebug.turnDistance = result?['distance']?.toDouble();

      if (mounted && _isRecording) {
        _captureSnapshot();
      }

      if (mounted) {
        setState(() {
          _turnInfo = result ?? {"exists": false, "distance": null};
        });
      }
    } catch (e) {
      _turnDebug.httpError = 'Exception in _checkTurnAhead: $e';
      _turnDebug.turnInfoApplied = {"exists": false, "distance": null};
      _turnDebug.turnExists = false;
      debugPrint('❌ _checkTurnAhead error: $e');
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
                          turnExists: _turnInfo != null && _turnInfo!['exists'] == true,
                          turnType: _turnInfo?['type']?.toString(),
                          turnDistance: _turnInfo?['distance']?.toDouble(),
                          turnInfo: _turnInfo,
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
