import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'turn_debug.dart';

class DebugOverlay extends StatelessWidget {
  final TurnDebugInfo debug;
  final Map<String, dynamic>? lastSentData;
  final List<Map<String, dynamic>> activeThreats;
  final List<Map<String, dynamic>> upcomingTurns;
  final bool isConnected;
  final String connectionStatus;
  final bool isSendingData;
  final double? displayHeadingDeg;
  final bool onRoad;
  final double? speedMs;
  final double? headingRaw;
  final bool hasCompassHeading;
  final bool usingGpsCourse;
  final int pendingMessagesCount;
  final bool turnExists;
  final String? turnType;
  final double? turnDistance;
  final Map<String, dynamic>? turnInfo;
  final List<Map<String, dynamic>> detectedTurns;
  final VoidCallback? onClose;
  final bool isRecording;
  final int recordingSeconds;
  final int snapshotCount;
  final Future<void> Function()? onStartRecording;
  final VoidCallback? onStopRecording;
  final VoidCallback? onListRecordings;

  const DebugOverlay({
    super.key,
    required this.debug,
    this.lastSentData,
    this.activeThreats = const [],
    this.upcomingTurns = const [],
    required this.isConnected,
    required this.connectionStatus,
    required this.isSendingData,
    this.displayHeadingDeg,
    required this.onRoad,
    this.speedMs,
    this.headingRaw,
    required this.hasCompassHeading,
    required this.usingGpsCourse,
    required this.pendingMessagesCount,
    required this.turnExists,
    this.turnType,
    this.turnDistance,
    this.turnInfo,
    this.detectedTurns = const [],
    this.onClose,
    this.isRecording = false,
    this.recordingSeconds = 0,
    this.snapshotCount = 0,
    this.onStartRecording,
    this.onStopRecording,
    this.onListRecordings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(
              turnExists: turnExists,
              turnType: turnType,
              turnDistance: turnDistance,
              isRecording: isRecording,
              recordingSeconds: recordingSeconds,
              snapshotCount: snapshotCount,
              onStartRecording: onStartRecording,
              onStopRecording: onStopRecording,
            ),
            const SizedBox(height: 12),
            _section('CONNECTION', _connectionContent(), Colors.cyan),
            _section('LOCATION & SPEED', _locationContent(), Colors.lightGreen),
            _section('HEADING SOURCES', _headingContent(), Colors.orange),
            _section('ROAD MATCH', _roadMatchContent(), Colors.teal),
            _section('TURN CHECK TIMING', _turnTimingContent(), Colors.amber),
            _section('CACHE / HTTP FETCH', _cacheContent(), Colors.blueGrey),
            _section('PRE-PROCESSING', _preProcessContent(), Colors.indigo),
            _section('PHASE 1: JUNCTION DETECTION', _phase1Content(), Colors.redAccent),
            _section('PHASE 2: BEND DETECTION', _phase2Content(), Colors.purple),
            _section('DETECT RESULT', _resultContent(), Colors.deepOrange),
            _section('WS PAYLOAD', _wsPayloadContent(), Colors.blue),
            _section('ACTIVE THREATS', _threatsContent(), Colors.red),
            _section('UPCOMING TURNS (backend)', _backendTurnsContent(), Colors.tealAccent),
            _section('DETECTED TURNS (frontend)', _frontendTurnsContent(), Colors.amber),
            _section('RECORDING', _recordingContent(), Colors.redAccent),
            _section('RAW DEBUG JSON', _rawJsonContent(), Colors.grey),
            const SizedBox(height: 12),
            _CopyButton(debug: debug, lastSentData: lastSentData, onClose: onClose, onListRecordings: onListRecordings),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, Widget content, Color color) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      initiallyExpanded: title == 'CONNECTION' || title == 'RECORDING',
      title: Text(
        title,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.3,
        ),
      ),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(6),
          ),
          child: content,
        ),
      ],
    );
  }

  Widget _item(String label, dynamic value, [Color? valueColor]) {
    final v = value?.toString() ?? 'null';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _connectionContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Connected', isConnected, isConnected ? Colors.green : Colors.red),
        _item('Status', connectionStatus),
        _item('Sending', isSendingData),
        _item('Pending msgs', pendingMessagesCount),
      ],
    );
  }

  Widget _locationContent() {
    final ls = lastSentData;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Latitude', _fmt(ls?['latitude'])),
        _item('Longitude', _fmt(ls?['longitude'])),
        _item('Speed (m/s)', _fmt(ls?['speed'])),
        if (ls?['speed'] != null)
          _item('Speed (km/h)', ((ls!['speed'] as num) * 3.6).toStringAsFixed(1)),
        _item('Timestamp', ls?['timestamp'] ?? ''),
        _item('Accuracy', _fmt(ls?['accuracy'])),
      ],
    );
  }

  Widget _headingContent() {
    final ls = lastSentData;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Display heading', displayHeadingDeg != null ? '${displayHeadingDeg!.toStringAsFixed(1)}°' : 'null'),
        _item('Raw heading (sent)', _fmt(ls?['heading'])),
        _item('Has compass', hasCompassHeading),
        _item('Using GPS course', usingGpsCourse),
        _item('On road (matched)', onRoad),
        _item('Heading source', onRoad ? 'road' : usingGpsCourse ? 'gps' : hasCompassHeading ? 'compass' : 'NONE'),
      ],
    );
  }

  Widget _roadMatchContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('onRoad', onRoad),
      ],
    );
  }

  Widget _turnTimingContent() {
    final t = debug.toJson()['timing'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Last check time', t['lastCheckTime'] ?? ''),
        _item('Time since last (s)', _fmt(t['timeSinceLastCheckSec'])),
        _item('Dist since last (m)', _fmt(t['distSinceLastCheckM'])),
        _item('Speed (m/s)', _fmt(t['speedMs'])),
        _item('Min interval (s)', _fmt(t['minIntervalSec'])),
        _item('Min distance (m)', _fmt(t['minDistanceM'])),
        _item('Should run', _boolStr(t['shouldRun'])),
        if (t['shouldRun'] == false)
          _item('SKIP REASON', t['skipReason'] ?? '', Colors.amber),
      ],
    );
  }

  Widget _cacheContent() {
    final d = debug.toJson()['detectInput'] as Map? ?? {};
    final h = debug.toJson()['httpRequest'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Scan radius (m)', _fmt(d['scanRadius'])),
        _item('Has cached data', _boolStr(d['hasCachedData'])),
        _item('Cached count', _fmt(d['cachedDataCount'])),
        _item('Dist since fetch (m)', _fmt(d['distSinceLastFetch'])),
        _item('Using cache', _boolStr(d['usingCache'])),
        _item('Cache too old', _boolStr(d['cacheTooOld'])),
        const SizedBox(height: 4),
        _item('HTTP URL', h['url'] ?? '', Colors.cyan),
        _item('HTTP status', _fmt(h['status'])),
        _item('HTTP error', h['error'] ?? ''),
        _item('Roads returned', _fmt(h['roadsReturned'])),
        _item('Fallback used', _boolStr(h['fallbackUsed'])),
      ],
    );
  }

  Widget _preProcessContent() {
    final p = debug.toJson()['preProcessing'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Elements count', _fmt(p['elementsCount'])),
        _item('Best way ID', p['bestWayId'] ?? ''),
        _item('Best highway', p['bestWayHighway'] ?? ''),
        _item('Best name', p['bestWayName'] ?? ''),
        _item('Best seg dist (m)', _fmt(p['bestSegmentDist'])),
        _item('Best seg index', _fmt(p['bestSegmentIndex'])),
        _item('Going forward', _boolStr(p['goingForward'])),
        _item('Total points', _fmt(p['totalPoints'])),
      ],
    );
  }

  Widget _phase1Content() {
    final p1 = debug.toJson()['phase1'] as Map? ?? {};
    final entries = p1['entries'] as List? ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Executed', _boolStr(p1['executed'])),
        _item('Has nodes', _boolStr(p1['hasNodes'])),
        _item('Node count', _fmt(p1['nodeCount'])),
        _item('Node→Ways count', _fmt(p1['nodeToWaysCount'])),
        _item('Ways count', _fmt(p1['waysCount'])),
        _item('Early returned', _boolStr(p1['earlyReturned']), Colors.amber),
        if (p1['earlyReturned'] == true) ...[
          _item('→ Return type', p1['returnType'] ?? '', Colors.yellow),
          _item('→ Return dist (m)', _fmt(p1['returnDist']), Colors.yellow),
        ],
        if (p1['hasNodes'] == false)
          const Text('  NODES ARRAY NULL/EMPTY — Phase 1 skipped entirely',
            style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold)),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text('SCANNED NODES:', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          ...entries.map((e) {
            final m = e as Map<String, dynamic>;
            final isJunc = m['isJunction'] == true;
            return Text(
              '  node[${m['nodeIndex']}] id=${m['nodeId']} '
              'ways=${m['waysHere']} '
              'dist=${_fmtNum(m['distance'])}m'
              '${isJunc ? ' → ${m['junctionType']} ⚠️' : ''}',
              style: TextStyle(
                color: isJunc ? Colors.yellow : Colors.white38,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            );
          }),
        ],
        if (entries.isEmpty && p1['executed'] == true)
          const Text('  (no nodes scanned — all skipped or radius exceeded)',
            style: TextStyle(color: Colors.white38, fontSize: 10)),
      ],
    );
  }

  Widget _phase2Content() {
    final p2 = debug.toJson()['phase2'] as Map? ?? {};
    final entries = p2['entries'] as List? ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Executed', _boolStr(p2['executed'])),
        _item('Segments in radius', _fmt(p2['segmentsWithinRadius'])),
        _item('Max angle change', '${_fmtNum(p2['maxAngleChange'])}°', Colors.amber),
        _item('Bend threshold', '${_fmtNum(p2['bendThreshold'])}°'),
        _item('Bend detected', _boolStr(p2['bendDetected'])),
        _item('Result', p2['result'] ?? ''),
        if (p2['executed'] == false)
          const Text('  Phase 2 SKIPPED (Phase 1 returned early)',
            style: TextStyle(color: Colors.orange, fontSize: 10, fontWeight: FontWeight.bold)),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text('ANGLE CHECKS:', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          ...entries.map((e) {
            final m = e as Map<String, dynamic>;
            final above = m['aboveThreshold'] == true;
            return Text(
              '  seg[${m['segmentIndex']}] dist=${_fmtNum(m['distance'])}m '
              'b1=${_fmtNum(m['bearing1'])}° b2=${_fmtNum(m['bearing2'])}° '
              'Δ=${_fmtNum(m['angleChange'])}°${above ? ' ⚠️' : ''}',
              style: TextStyle(
                color: above ? Colors.yellow : Colors.white38,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            );
          }),
        ],
        if (entries.isEmpty && p2['executed'] == true && p2['bendDetected'] == false)
          const Text('  (all angles below threshold)',
            style: TextStyle(color: Colors.white38, fontSize: 10)),
      ],
    );
  }

  Widget _resultContent() {
    final r = debug.toJson()['result'] as Map? ?? {};
    final exists = r['turnExists'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Turn exists', _boolStr(exists), exists ? Colors.green : Colors.red),
        _item('Turn type', r['turnType'] ?? ''),
        _item('Turn distance (m)', _fmt(r['turnDistance'])),
        const SizedBox(height: 6),
        const Text('_detectTurnAhead() raw result:',
          style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            _fmtJson(r['detectResult']),
            style: const TextStyle(color: Colors.white70, fontSize: 8, fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 4),
        const Text('_turnInfo applied to state:',
          style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            _fmtJson(r['turnInfoApplied']),
            style: const TextStyle(color: Colors.white70, fontSize: 8, fontFamily: 'monospace'),
          ),
        ),
        if (r['multiTurn'] != null)
          ..._buildMultiTurnResult(r['multiTurn']),
      ],
    );
  }

  List<Widget> _buildMultiTurnResult(dynamic mt) {
    return [
      const SizedBox(height: 6),
      const Text('MULTI-TURN PIPELINE:',
        style: TextStyle(color: Colors.amber, fontSize: 10, fontWeight: FontWeight.bold)),
      const SizedBox(height: 2),
      _item('All junctions (raw)', mt['allJunctionsCount'] ?? 0),
      _item('After dedup (15m)', mt['dedupedCount'] ?? 0),
      _item('After cone filter (60°)', mt['filteredCount'] ?? 0),
      _item('Final turns (top 3)', (mt['finalTurns'] as List?)?.length ?? 0),
      if ((mt['finalTurns'] as List?)?.isNotEmpty == true) ...[
        const SizedBox(height: 4),
        ...(mt['finalTurns'] as List).map((t) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            _fmtJson(t),
            style: const TextStyle(color: Colors.amberAccent, fontSize: 8, fontFamily: 'monospace'),
          ),
        )),
      ],
    ];
  }

  Widget _wsPayloadContent() {
    final payload = debug.lastWsPayload ?? lastSentData;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _fmtJson(payload),
        style: const TextStyle(color: Colors.cyan, fontSize: 8, fontFamily: 'monospace'),
      ),
    );
  }

  Widget _threatsContent() {
    if (activeThreats.isEmpty) {
      return const Text('(none)', style: TextStyle(color: Colors.white38, fontSize: 10));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${activeThreats.length} active threat(s)',
          style: const TextStyle(color: Colors.red, fontSize: 10)),
        const SizedBox(height: 4),
        ...activeThreats.map((t) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              _fmtJson(t),
              style: const TextStyle(color: Colors.white70, fontSize: 8, fontFamily: 'monospace'),
            ),
          );
        }),
      ],
    );
  }

  Widget _backendTurnsContent() {
    if (upcomingTurns.isEmpty) {
      return const Text('(none)', style: TextStyle(color: Colors.white38, fontSize: 10));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${upcomingTurns.length} turn(s)',
          style: const TextStyle(color: Colors.tealAccent, fontSize: 10)),
        const SizedBox(height: 4),
        ...upcomingTurns.map((t) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              _fmtJson(t),
              style: const TextStyle(color: Colors.white70, fontSize: 8, fontFamily: 'monospace'),
            ),
          );
        }),
      ],
    );
  }

  Widget _frontendTurnsContent() {
    if (detectedTurns.isEmpty) {
      return const Text('(none)', style: TextStyle(color: Colors.white38, fontSize: 10));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${detectedTurns.length} turn(s)',
          style: const TextStyle(color: Colors.amber, fontSize: 10)),
        const SizedBox(height: 4),
        ...detectedTurns.map((t) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              _fmtJson(t),
              style: const TextStyle(color: Colors.white70, fontSize: 8, fontFamily: 'monospace'),
            ),
          );
        }),
      ],
    );
  }

  Widget _recordingContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item('Recording', isRecording, isRecording ? Colors.red : Colors.white38),
        _item('Duration', '$recordingSeconds s'),
        _item('Snapshots', snapshotCount),
      ],
    );
  }

  Widget _rawJsonContent() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        debug.toJsonString(),
        style: const TextStyle(color: Colors.grey, fontSize: 7, fontFamily: 'monospace'),
      ),
    );
  }

  String _fmt(dynamic v) {
    if (v == null) return 'null';
    if (v is num) {
      if (v == v.roundToDouble()) return v.toString();
      return v.toStringAsFixed(2);
    }
    return v.toString();
  }

  String _fmtNum(dynamic v) {
    if (v == null) return '-';
    if (v is num) return v.toStringAsFixed(1);
    return v.toString();
  }

  String _boolStr(dynamic v) {
    if (v == null) return 'null';
    if (v == true) return 'YES';
    return 'NO';
  }

  String _fmtJson(dynamic data) {
    if (data == null) return 'null';
    try {
      if (data is String) return data;
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }
}

class _Header extends StatelessWidget {
  final bool turnExists;
  final String? turnType;
  final double? turnDistance;
  final bool isRecording;
  final int recordingSeconds;
  final int snapshotCount;
  final Future<void> Function()? onStartRecording;
  final VoidCallback? onStopRecording;

  const _Header({
    required this.turnExists,
    this.turnType,
    this.turnDistance,
    required this.isRecording,
    required this.recordingSeconds,
    required this.snapshotCount,
    this.onStartRecording,
    this.onStopRecording,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Icon(
              turnExists ? Icons.check_circle : Icons.cancel,
              color: turnExists ? Colors.green : Colors.red,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                turnExists
                  ? 'TURN: ${turnType ?? "?"} at ${turnDistance?.toStringAsFixed(0) ?? "?"}m'
                  : 'NO TURN DETECTED',
                style: TextStyle(
                  color: turnExists ? Colors.green : Colors.red,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: isRecording ? onStopRecording : onStartRecording,
            icon: Icon(
              isRecording ? Icons.stop : Icons.fiber_manual_record,
              size: 16,
            ),
            label: Text(
              isRecording
                ? '■ Stop & Share  ${_formatDuration(recordingSeconds)}  ($snapshotCount snaps)'
                : '● Start Recording',
              style: const TextStyle(fontSize: 11),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: isRecording ? Colors.red : Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
      ],
    );
  }

  String _formatDuration(int totalSec) {
    final min = totalSec ~/ 60;
    final sec = totalSec % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

class _CopyButton extends StatelessWidget {
  final TurnDebugInfo debug;
  final Map<String, dynamic>? lastSentData;
  final VoidCallback? onClose;
  final VoidCallback? onListRecordings;

  const _CopyButton({required this.debug, this.lastSentData, this.onClose, this.onListRecordings});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  final full = {
                    'debug': debug.toJson(),
                    'lastSentData': lastSentData,
                  };
                  Clipboard.setData(ClipboardData(
                    text: const JsonEncoder.withIndent('  ').convert(full),
                  ));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('All debug data copied to clipboard')),
                  );
                },
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('Copy All', style: TextStyle(fontSize: 11)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 14),
                label: const Text('Close', style: TextStyle(fontSize: 11)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade800,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ],
        ),
        if (onListRecordings != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onListRecordings,
              icon: const Icon(Icons.folder_open, size: 14),
              label: const Text('View Saved Recordings', style: TextStyle(fontSize: 11)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
