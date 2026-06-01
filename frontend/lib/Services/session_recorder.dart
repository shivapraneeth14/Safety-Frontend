import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class SessionRecorder {
  List<Map<String, dynamic>> _snapshots = [];
  DateTime? _rideStartTime;
  DateTime? _rideEndTime;
  String? _currentRideId;
  bool _isRecording = false;
  int _recordingInterval = 0;
  Map<String, dynamic>? _lastFullResponse;
  Map<String, dynamic>? _lastMapMatch;

  static const int maxSnapshots = 3600;
  static const int sparseInterval = 30;

  String? _backendVersion;

  void setBackendVersion(String version) {
    _backendVersion = version;
  }

  void startRide() {
    _snapshots = [];
    _rideStartTime = DateTime.now();
    _rideEndTime = null;
    _currentRideId = 'ride_${_rideStartTime!.millisecondsSinceEpoch}';
    _isRecording = true;
    _recordingInterval = 0;
    _lastFullResponse = null;
    _lastMapMatch = null;
  }

  Future<void> stopRide({Map<String, dynamic>? outcome}) async {
    if (!_isRecording) return;
    _isRecording = false;
    _rideEndTime = DateTime.now();
    await _saveSession(outcome);
  }

  void recordExchange({
    required Map<String, dynamic> sentPayload,
    required Map<String, dynamic> serverResponse,
    required double roundTripMs,
    required double batteryPct,
    required String networkType,
    required double gpsAccuracy,
  }) {
    if (!_isRecording) return;
    if (_snapshots.length >= maxSnapshots) return;

    _recordingInterval++;
    final hasThreats = (serverResponse['threats'] as List?)?.isNotEmpty ?? false;
    final mapMatchChanged = _mapMatchChanged(serverResponse['mapMatch']);

    if (!hasThreats && !mapMatchChanged && _snapshots.isNotEmpty) {
      if (_recordingInterval % sparseInterval != 0) return;
      _snapshots.add({
        't': _elapsedSec(),
        'type': 'heartbeat',
        'meta': {
          'rttMs': roundTripMs,
          'batteryPct': batteryPct,
          'networkType': networkType,
          'gpsAccuracy': gpsAccuracy,
        },
      });
      return;
    }

    _lastFullResponse = serverResponse;
    _snapshots.add({
      't': _elapsedSec(),
      'type': hasThreats ? 'threat' : 'state',
      'sent': _sanitizeForStorage(sentPayload),
      'received': _sanitizeForStorage(serverResponse),
      'meta': {
        'rttMs': roundTripMs,
        'batteryPct': batteryPct,
        'networkType': networkType,
        'gpsAccuracy': gpsAccuracy,
      },
    });
  }

  bool _mapMatchChanged(Map<String, dynamic>? current) {
    if (current == null && _lastMapMatch == null) return false;
    if (current == null || _lastMapMatch == null) return true;
    if (current['roadId'] != _lastMapMatch!['roadId']) return true;
    if ((current['confidence'] ?? 0) != (_lastMapMatch!['confidence'] ?? 0)) {
      if ((current['confidence'] ?? 0) - (_lastMapMatch!['confidence'] ?? 0) > 0.1) return true;
    }
    _lastMapMatch = Map<String, dynamic>.from(current);
    return false;
  }

  double _elapsedSec() {
    if (_rideStartTime == null) return 0;
    return DateTime.now().difference(_rideStartTime!).inMilliseconds / 1000.0;
  }

  Future<void> _saveSession(Map<String, dynamic>? outcome) async {
    if (_snapshots.isEmpty) return;
    final threatCounts = <String, int>{};
    int totalAlerts = 0;
    for (final snap in _snapshots) {
      final threats = (snap['received']?['threats'] as List?) ?? [];
      for (final t in threats) {
        totalAlerts++;
        final type = t['type'] as String? ?? 'unknown';
        threatCounts[type] = (threatCounts[type] ?? 0) + 1;
      }
    }

    final session = {
      'appVersion': '1.0.0',
      'backendVersion': _backendVersion ?? 'unknown',
      'modelVersion': 'sprint4',
      'sessionId': _currentRideId,
      'startTime': _rideStartTime?.toIso8601String(),
      'endTime': _rideEndTime?.toIso8601String(),
      'durationSec': _rideEndTime != null && _rideStartTime != null
          ? _rideEndTime!.difference(_rideStartTime!).inSeconds
          : 0,
      'snapshotCount': _snapshots.length,
      'snapshots': _snapshots,
      'summary': {
        'totalAlerts': totalAlerts,
        'threatTypes': threatCounts,
        'snapshotCount': _snapshots.length,
      },
      'rideOutcome': outcome ?? {
        'userReportedNearMiss': false,
        'userReportedFalseAlert': 0,
        'userReportedIssue': null,
      },
    };

    final dir = await getApplicationDocumentsDirectory();
    final sessionsDir = Directory('${dir.path}/sessions');
    if (!await sessionsDir.exists()) await sessionsDir.create();
    final file = File('${sessionsDir.path}/$_currentRideId.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(session));
  }

  Future<List<File>> getPastSessions() async {
    try {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/sessions');
      if (!await dir.exists()) return [];
      final files = await dir.list()
          .where((f) => f is File && f.path.endsWith('.json'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      return files;
    } catch (_) {
      return [];
    }
  }

  Future<void> shareLatestSession() async {
    final files = await getPastSessions();
    if (files.isEmpty) return;
    await Share.shareXFiles([XFile(files.first.path)], subject: 'Safety App Session');
  }

  Map<String, dynamic> _sanitizeForStorage(Map<String, dynamic>? data) {
    if (data == null) return {};
    final sanitized = Map<String, dynamic>.from(data);
    sanitized.remove('accel');
    sanitized.remove('gyro');
    sanitized.remove('magnetometer');
    sanitized.remove('sensorQuality');
    sanitized.remove('connectivity');
    return sanitized;
  }

  bool get isRecording => _isRecording;
  int get snapshotCount => _snapshots.length;
  int get durationSec => _rideStartTime != null
      ? DateTime.now().difference(_rideStartTime!).inSeconds
      : _rideEndTime != null && _rideStartTime != null
          ? _rideEndTime!.difference(_rideStartTime!).inSeconds
          : 0;
  String? get currentRideId => _currentRideId;
}
