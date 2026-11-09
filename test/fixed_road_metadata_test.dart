import 'package:blackbox_driver_care/services/case_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> record() => {
  'id': 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'device_id': 'dev_front',
  'title': '신호_교차로',
  'status': 'uploaded',
  'created_at': '2026-11-09T00:00:00Z',
};

void main() {
  test('only server policy, not an editable title, locks an expert', () {
    expect(BackendCase.fromJson(record()).fixedRoadPlace, isNull);
    for (final place in [1, 3, 6, 4]) {
      expect(BackendCase.fromJson({
        ...record(),
        'road_policy': {'locked': true, 'place': place, 'reason': 'reference_video'},
      }).fixedRoadPlace, place);
    }
    expect(BackendCase.fromJson({
      ...record(), 'road_policy': {'locked': false, 'place': 5},
    }).fixedRoadPlace, isNull);
  });

  test('malformed locked policy cannot start a wrong-model request', () {
    for (final place in [null, -1, 8, '1']) {
      expect(() => BackendCase.fromJson({
        ...record(), 'road_policy': {'locked': true, 'place': place},
      }), throwsA(isA<InvalidBackendCaseException>()));
    }
  });
}
