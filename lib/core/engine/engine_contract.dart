/// Dart mirror of `engine/grablytic_engine/contract.py`.
///
/// The engine and the host speak a line-delimited JSON protocol. The
/// contract is VERSIONED so a host and an engine from different builds
/// refuse to talk to each other instead of half-understanding each
/// other (a renamed field used to surface as a silent null in the
/// middle of a download).
///
/// Keep this file in step with `engine/grablytic_engine/contract.py`.
class EngineContract {
  const EngineContract._();

  /// Bumped when the method set or a field name changes incompatibly.
  /// A mismatched major version is REFUSED by the engine.
  static const int major = 1;

  /// Bumped for backward-compatible additions (a new optional field or
  /// a new error code). A minor mismatch stays compatible.
  static const int minor = 0;

  /// What the host sends in `contract_version`.
  static const int version = major;

  /// Human-readable form ("1.0").
  static const String versionString = '$major.$minor';

  /// The engine refuses a mismatched major version with this code.
  static const String mismatchErrorType = 'ERROR_CONTRACT_MISMATCH';

  /// A missing required parameter now yields this code instead of an
  /// unanswered request.
  static const String invalidParamErrorType = 'ERROR_INVALID_PARAM';

  /// True when an engine speaking [engineMajor] is compatible with us.
  static bool isCompatible(int engineMajor) => engineMajor == major;

  /// Refuse to continue when the engine speaks a different MAJOR
  /// contract version. The two sides would half-understand each other:
  /// a renamed field would surface as a silent null in the middle of a
  /// download.
  ///
  /// Shared by the desktop and platform-channel services — they must
  /// agree on what "compatible" means.
  static void assertCompatible(Map<String, dynamic> bootstrap) {
    final int engineMajor = majorFrom(bootstrap);
    if (engineMajor < 0) {
      // The engine predates the contract: nothing to compare, carry on.
      return;
    }
    if (!isCompatible(engineMajor)) {
      throw StateError(
        'Engine contract $engineMajor.x is incompatible with the host '
        'contract $versionString.',
      );
    }
  }

  /// Read the major version out of a bootstrap payload. Returns -1 when
  /// the engine predates the contract (no version reported).
  static int majorFrom(Map<String, dynamic> payload) {
    final Object? raw = payload['contract_version'];
    if (raw is int) return raw;
    if (raw is String) {
      final int? parsed = int.tryParse(raw.split('.').first);
      return parsed ?? -1;
    }
    return -1;
  }
}
