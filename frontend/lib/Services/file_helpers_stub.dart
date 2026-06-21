class RecordingFileInfo {
  final String path;
  final String name;
  final int sizeBytes;
  final DateTime modified;
  RecordingFileInfo(this.path, this.name, this.sizeBytes, this.modified);
}

Future<List<RecordingFileInfo>> getSavedRecordings() async => [];

Future<void> deleteRecordingFile(String path) async {}

Future<String> readRecordingFile(String path) async => '';
