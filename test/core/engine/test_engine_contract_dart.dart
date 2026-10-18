import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_contract.dart';

void main() {
  group('EngineContract', () {
    test('exposes a versioned contract', () {
      expect(EngineContract.major, greaterThanOrEqualTo(1));
      expect(EngineContract.minor, greaterThanOrEqualTo(0));
      expect(EngineContract.version, EngineContract.major);
      expect(EngineContract.versionString, '${EngineContract.major}.${EngineContract.minor}');
    });

    test('accepts a matching major version', () {
      expect(EngineContract.isCompatible(EngineContract.major), isTrue);
    });

    test('refuses a mismatched major version', () {
      expect(EngineContract.isCompatible(EngineContract.major + 1), isFalse);
      expect(EngineContract.isCompatible(EngineContract.major - 1), isFalse);
    });

    test('reads the major version out of a bootstrap payload', () {
      expect(EngineContract.majorFrom({'contract_version': 1}), 1);
      expect(EngineContract.majorFrom({'contract_version': '1.0'}), 1);
      expect(EngineContract.majorFrom({'contract_version': '2.3'}), 2);
    });

    test('treats a payload without a version as pre-contract', () {
      expect(EngineContract.majorFrom({}), -1);
      expect(EngineContract.majorFrom({'contract_version': 'x'}), -1);
      expect(EngineContract.majorFrom({'contract_version': null}), -1);
    });
  });
}
