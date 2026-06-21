import 'dart:convert';
import 'package:file_picker/file_picker.dart';

class SessionRecorder {
  List<Map<String, dynamic>> _snapshots = [];
  DateTime? _rideStartTime;
  DateTime? _rideEndTime;
  String _currentRideId = '';
  bool _isRecording = false;
  String _currentLabel = '';
  Map<String, dynamic>? _rideOutcome;

  static const int maxSnapshots = 3600;

  String? _backendVersion;

  void setBackendVersion(String version) {
    _backendVersion = version;
  }

  void startRide(String label) {
    _snapshots = [];
    _rideStartTime = DateTime.now();
    _rideEndTime = null;
    _currentLabel = label;
    final sanitized = label.replaceAll(RegExp(r'[^\w\- ]'), '').replaceAll(' ', '_');
    _currentRideId = sanitized.isEmpty ? 'ride_${_rideStartTime!.millisecondsSinceEpoch}' : sanitized;
    _isRecording = true;
  }

  Future<void> stopRide({Map<String, dynamic>? outcome}) async {
    if (!_isRecording) return;
    _isRecording = false;
    _rideEndTime = DateTime.now();
    _rideOutcome = outcome;
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

    _snapshots.add({
      't': _elapsedSec(),
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

  double _elapsedSec() {
    if (_rideStartTime == null) return 0;
    return DateTime.now().difference(_rideStartTime!).inMilliseconds / 1000.0;
  }

  Future<String?> exportSession(String fileName) async {
    final jsonStr = const JsonEncoder.withIndent('  ').convert(_buildExportData());
    final bytes = utf8.encode(jsonStr);
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save ride recording',
      fileName: '$fileName.json',
      bytes: bytes,
    );
    if (savedPath != null) {
      print('Session exported to: $savedPath');
    }
    return savedPath;
  }

  String getSessionJsonString() {
    return const JsonEncoder.withIndent('  ').convert(_buildExportData());
  }

  Map<String, dynamic> _buildExportData() {
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

    return {
      'name': _currentLabel,
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
      'frames': _snapshots,
      'summary': {
        'totalAlerts': totalAlerts,
        'threatTypes': threatCounts,
        'snapshotCount': _snapshots.length,
      },
      'rideOutcome': _rideOutcome ?? {
        'userReportedNearMiss': false,
        'userReportedFalseAlert': 0,
        'userReportedIssue': null,
      },
    };
  }

  Map<String, dynamic> _sanitizeForStorage(Map<String, dynamic>? data) {
    if (data == null) return {};
    final sanitized = Map<String, dynamic>.from(data);
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
  String get currentLabel => _currentLabel;
}
