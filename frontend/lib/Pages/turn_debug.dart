import 'dart:convert';

class TurnDebugInfo {
  // Step 1: Check timing
  DateTime? lastCheckTime;
  double? timeSinceLastCheckSec;
  double? distSinceLastCheckM;
  double? speedMs;
  int? minIntervalSec;
  double? minDistanceM;
  bool? shouldRun;
  String? skipReason;

  // Step 2: Detect turn ahead input
  double? scanRadius;
  bool? hasCachedData;
  int? cachedDataCount;
  double? distSinceLastFetch;
  bool? usingCache;
  bool? cacheTooOld;

  // Step 3: HTTP request
  String? fetchUrl;
  int? httpStatus;
  String? httpError;
  int? roadsReturned;
  bool? fallbackUsed;

  // Step 4: Pre-processing
  int? elementsCount;
  String? bestWayId;
  String? bestWayHighway;
  String? bestWayName;
  double? bestSegmentDist;
  int? bestSegmentIndex;
  bool? goingForward;
  int? totalPoints;

  // Phase 1: Junction detection
  bool? hasNodes;
  int? nodeCount;
  int? nodeToWaysCount;
  int? waysCount;
  List<Phase1Entry> phase1Entries = [];
  bool? phase1Executed;
  bool? phase1EarlyReturned;
  String? phase1ReturnType;
  double? phase1ReturnDist;

  // Phase 2: Bend detection
  bool? phase2Executed;
  List<Phase2Entry> phase2Entries = [];
  int? segmentsWithinRadius;
  double? maxAngleChange;
  double? bendThreshold;
  String? phase2Result;
  bool? bendDetected;

  // Result
  Map<String, dynamic>? detectResult;
  Map<String, dynamic>? turnInfoApplied;
  bool? turnExists;
  String? turnType;
  double? turnDistance;

  // WS payload
  Map<String, dynamic>? lastWsPayload;

  void reset() {
    final copy = toJson();
    copy..remove('phase1Entries')..remove('phase2Entries');
    phase1Entries.clear();
    phase2Entries.clear();
  }

  Map<String, dynamic> toSnapshot({
    required double lat,
    required double lng,
    required double speedMs,
    required double headingDeg,
    required String headingSource,
    required List<Map<String, dynamic>> activeThreats,
    required List<Map<String, dynamic>> upcomingTurns,
    required Map<String, dynamic>? turnInfo,
    required double elapsedSec,
  }) {
    return {
      't': elapsedSec,
      'timestamp': DateTime.now().toIso8601String(),
      'position': {
        'lat': lat,
        'lng': lng,
        'speedMs': speedMs,
        'speedKmh': (speedMs * 3.6),
        'headingDeg': headingDeg,
        'headingSource': headingSource,
      },
      'turnDebug': toJson(),
      'turnInfo': turnInfo,
      'threats': activeThreats,
      'upcomingTurns': upcomingTurns,
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'timing': {
        'lastCheckTime': lastCheckTime?.toIso8601String(),
        'timeSinceLastCheckSec': timeSinceLastCheckSec,
        'distSinceLastCheckM': distSinceLastCheckM,
        'speedMs': speedMs,
        'minIntervalSec': minIntervalSec,
        'minDistanceM': minDistanceM,
        'shouldRun': shouldRun,
        'skipReason': skipReason,
      },
      'detectInput': {
        'scanRadius': scanRadius,
        'hasCachedData': hasCachedData,
        'cachedDataCount': cachedDataCount,
        'distSinceLastFetch': distSinceLastFetch,
        'usingCache': usingCache,
        'cacheTooOld': cacheTooOld,
      },
      'httpRequest': {
        'url': fetchUrl,
        'status': httpStatus,
        'error': httpError,
        'roadsReturned': roadsReturned,
        'fallbackUsed': fallbackUsed,
      },
      'preProcessing': {
        'elementsCount': elementsCount,
        'bestWayId': bestWayId,
        'bestWayHighway': bestWayHighway,
        'bestWayName': bestWayName,
        'bestSegmentDist': bestSegmentDist,
        'bestSegmentIndex': bestSegmentIndex,
        'goingForward': goingForward,
        'totalPoints': totalPoints,
      },
      'phase1': {
        'hasNodes': hasNodes,
        'nodeCount': nodeCount,
        'nodeToWaysCount': nodeToWaysCount,
        'waysCount': waysCount,
        'entries': phase1Entries.map((e) => e.toJson()).toList(),
        'executed': phase1Executed,
        'earlyReturned': phase1EarlyReturned,
        'returnType': phase1ReturnType,
        'returnDist': phase1ReturnDist,
      },
      'phase2': {
        'executed': phase2Executed,
        'entries': phase2Entries.map((e) => e.toJson()).toList(),
        'segmentsWithinRadius': segmentsWithinRadius,
        'maxAngleChange': maxAngleChange,
        'bendThreshold': bendThreshold,
        'result': phase2Result,
        'bendDetected': bendDetected,
      },
      'result': {
        'detectResult': detectResult,
        'turnInfoApplied': turnInfoApplied,
        'turnExists': turnExists,
        'turnType': turnType,
        'turnDistance': turnDistance,
      },
      'lastWsPayload': lastWsPayload,
    };
  }

  String toJsonString() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }
}

class Phase1Entry {
  int nodeIndex;
  int nodeId;
  int waysHere;
  double distance;
  bool isJunction;
  String? junctionType;
  Map<String, dynamic>? junctionDetails;

  Phase1Entry({
    required this.nodeIndex,
    required this.nodeId,
    required this.waysHere,
    required this.distance,
    required this.isJunction,
    this.junctionType,
    this.junctionDetails,
  });

  Map<String, dynamic> toJson() => {
    'nodeIndex': nodeIndex,
    'nodeId': nodeId,
    'waysHere': waysHere,
    'distance': distance,
    'isJunction': isJunction,
    'junctionType': junctionType,
    'junctionDetails': junctionDetails,
  };
}

class Phase2Entry {
  int segmentIndex;
  double distance;
  double bearing1;
  double bearing2;
  double angleChange;
  bool aboveThreshold;

  Phase2Entry({
    required this.segmentIndex,
    required this.distance,
    required this.bearing1,
    required this.bearing2,
    required this.angleChange,
    required this.aboveThreshold,
  });

  Map<String, dynamic> toJson() => {
    'segmentIndex': segmentIndex,
    'distance': distance,
    'bearing1': bearing1,
    'bearing2': bearing2,
    'angleChange': angleChange,
    'aboveThreshold': aboveThreshold,
  };
}
