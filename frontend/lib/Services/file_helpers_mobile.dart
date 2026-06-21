import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'file_helpers.dart';

Future<List<RecordingFileInfo>> getSavedRecordings() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final sessionsDir = Directory('${dir.path}/sessions');
    if (!await sessionsDir.exists()) return [];
    final files = await sessionsDir.list()
        .where((f) => f is File && f.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files.map((f) => RecordingFileInfo(
      f.path,
      f.uri.pathSegments.last,
      f.lengthSync(),
      f.lastModifiedSync(),
    )).toList();
  } catch (_) {
    return [];
  }
}

Future<void> deleteRecordingFile(String path) async {
  await File(path).delete();
}

Future<String> readRecordingFile(String path) async {
  return await File(path).readAsString();
}
