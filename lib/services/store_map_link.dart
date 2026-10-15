/// Kakao's HTTPS map links work through an installed map app or a browser.
Uri storeMapLink({
  required String name,
  required String address,
  num? latitude,
  num? longitude,
}) {
  if (latitude != null &&
      longitude != null &&
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180 &&
      (latitude != 0 || longitude != 0)) {
    final label = Uri.encodeComponent(name.replaceAll(',', ' '));
    return Uri.parse(
      'https://map.kakao.com/link/map/$label,$latitude,$longitude',
    );
  }
  return Uri.parse(
    'https://map.kakao.com/link/search/${Uri.encodeComponent('$name $address'.trim())}',
  );
}
