// lib/utils/io_web_stub.dart
//
// 웹(Flutter Web) 빌드 전용 dart:io 스텁.
//
// 웹에서는 로컬 파일 시스템(File/Directory)에 접근하는 기능(블랙박스 영상 캐시,
// PDF 로컬 저장, 녹취 저장 등)은 웹에서 호출되지 않는다.
// 블랙박스 원본 영상은 별도 서명 URL을 사용해 네트워크로 재생한다.
//
// 그러나 해당 기능을 구현한 소스들이 File/Directory 타입을 시그니처에
// 사용하기 때문에, 웹 컴파일을 통과시키려면 동일한 이름의 타입이 필요하다.
// 여기서는 컴파일만 통과하도록 최소한의 스텁을 제공하며,
// 실제로 호출되면 UnsupportedError 를 던진다(웹에서는 호출 경로가 없음).
//
// 네이티브(Android/iOS) 빌드에서는 조건부 import 에 의해 실제 dart:io 가
// 사용되므로 이 파일은 포함되지 않는다.

Never _unsupported(String what) =>
    throw UnsupportedError('$what is not available on web');

class FileSystemEntity {
  final String path;
  const FileSystemEntity(this.path);
  Future<bool> exists() async => false;
  Future<FileSystemEntity> delete({bool recursive = false}) async =>
      _unsupported('delete');
  Future<String> resolveSymbolicLinks() async =>
      _unsupported('resolveSymbolicLinks');
}

class FileStat {
  int get size => 0;
  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(0);
  DateTime get changed => DateTime.fromMillisecondsSinceEpoch(0);
  DateTime get accessed => DateTime.fromMillisecondsSinceEpoch(0);
}

class File extends FileSystemEntity {
  File(String path) : super(path);
  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<File> copy(String newPath) async => _unsupported('File.copy');
  Future<File> writeAsBytes(List<int> bytes,
          {bool flush = false}) async =>
      _unsupported('File.writeAsBytes');
  Future<File> writeAsString(String contents, {bool flush = false}) async =>
      _unsupported('File.writeAsString');
  Future<List<int>> readAsBytes() async => _unsupported('File.readAsBytes');
  Future<String> readAsString() async => _unsupported('File.readAsString');
  Future<int> length() async => _unsupported('File.length');
  Stream<List<int>> openRead([int? start, int? end]) =>
      const Stream<List<int>>.empty();
  FileStat statSync() => FileStat();
  File renameSync(String newPath) => _unsupported('File.renameSync');
  void deleteSync({bool recursive = false}) => _unsupported('File.deleteSync');
  @override
  Future<File> delete({bool recursive = false}) async =>
      _unsupported('File.delete');
  Future<DateTime> lastModified() async => _unsupported('File.lastModified');
  @override
  Future<String> resolveSymbolicLinks() async =>
      _unsupported('File.resolveSymbolicLinks');
}

class OSError {
  final String message;
  final int errorCode;
  const OSError([this.message = '', this.errorCode = 0]);
}

class Directory extends FileSystemEntity {
  Directory(String path) : super(path);
  @override
  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<Directory> create({bool recursive = false}) async =>
      _unsupported('Directory.create');
  Stream<FileSystemEntity> list(
          {bool recursive = false, bool followLinks = true}) =>
      const Stream<FileSystemEntity>.empty();
  List<FileSystemEntity> listSync(
          {bool recursive = false, bool followLinks = true}) =>
      const [];
}

class FileSystemException implements Exception {
  final String message;
  final OSError? osError;
  const FileSystemException([this.message = '', this.osError]);
  @override
  String toString() => 'FileSystemException: $message';
}

// dart:io 의 Platform 일부 (사용되는 경우 대비)
class Platform {
  static const bool isIOS = false;
  static const bool isAndroid = false;
  static const bool isWindows = false;
  static const bool isMacOS = false;
  static const bool isLinux = false;
  static const String pathSeparator = '/';
}
