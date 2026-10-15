import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/store_map_link.dart';

void main() {
  test(
    'Korean store name and reserved characters stay inside the map label',
    () {
      final uri = storeMapLink(
        name: '행운/복권 & 1호점',
        address: '서울',
        latitude: 37.5,
        longitude: 127.1,
      );
      expect(uri.host, 'map.kakao.com');
      expect(uri.scheme, 'https');
      expect(uri.pathSegments, ['link', 'map', '행운/복권 & 1호점,37.5,127.1']);
      expect(uri.hasQuery, false);
    },
  );
  test('missing or invalid coordinates use name and address search', () {
    for (final lat in [null, double.nan, 123.0]) {
      final uri = storeMapLink(
        name: '복권',
        address: '서울',
        latitude: lat,
        longitude: 127,
      );
      expect(uri.pathSegments, ['link', 'search', '복권 서울']);
    }
  });
}
