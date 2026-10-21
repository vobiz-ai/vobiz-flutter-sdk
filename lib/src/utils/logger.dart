typedef LogWriter = void Function(String message);

/// Where the SDK writes its log lines. Pass one to `VobizClient(logger:)`
/// to route SDK logs into your own logging; [writer] receives each line.
class Logger {
  Logger({LogWriter? writer}) : _writer = writer;

  final LogWriter? _writer;

  void info(String message) => _writer?.call('[INFO] $message');
  void warn(String message) => _writer?.call('[WARN] $message');
  void error(String message) => _writer?.call('[ERROR] $message');
}
