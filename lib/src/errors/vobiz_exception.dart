/// A request to the webhook server failed, or the server refused it.
///
/// [code] says which operation failed (`setup_failed`, `transfer_failed`,
/// `recordings_failed`) and [message] carries the server's own explanation
/// when it gave one, such as an invalid Auth Token.
class VobizException implements Exception {
  const VobizException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;

  /// The HTTP status the server answered with, when it answered at all.
  final int? statusCode;

  @override
  String toString() =>
      'VobizException($code${statusCode != null ? ', HTTP $statusCode' : ''}): $message';
}
