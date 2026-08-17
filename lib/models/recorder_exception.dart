/// User-facing failure with optional technical details for logs.
class RecorderException implements Exception {
  final String userMessage;
  final String? technicalDetails;

  const RecorderException({
    required this.userMessage,
    this.technicalDetails,
  });

  @override
  String toString() {
    if (technicalDetails == null || technicalDetails!.isEmpty) {
      return 'RecorderException: $userMessage';
    }
    return 'RecorderException: $userMessage ($technicalDetails)';
  }
}

class InvalidStateException extends RecorderException {
  InvalidStateException(String operation, String state)
      : super(userMessage: 'Cannot $operation while $state.');
}
