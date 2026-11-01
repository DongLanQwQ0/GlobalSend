bool knownImageName(String name) => const {
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'bmp',
  'heic',
  'heif',
  'avif',
}.contains(name.split('.').last.toLowerCase());

/// A provider's display name may be suffixless or use a placeholder such as
/// .pic. Name the transferred copy from its container; never rename the source.
String imageFileName(String name, (String, String)? type) {
  if (type == null) return name;
  final dot = name.lastIndexOf('.');
  final suffix = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  final actual = type.$2;
  if (suffix == actual ||
      (actual == 'jpg' && suffix == 'jpeg') ||
      (actual == 'heic' && suffix == 'heif'))
    return name;
  final replace =
      knownImageName(name) ||
      const {'pic', 'image', 'img', 'bin', 'tmp', 'dat'}.contains(suffix);
  return '${replace && dot > 0 ? name.substring(0, dot) : name}.$actual';
}

bool ambiguousImageName(String name) =>
    !name.contains('.') ||
    const {
      'pic',
      'image',
      'img',
      'bin',
      'tmp',
      'dat',
    }.contains(name.split('.').last.toLowerCase());

(String, String)? imageTypeHeader(List<int> bytes) {
  bool prefix(List<int> value, [int offset = 0]) {
    if (bytes.length < value.length + offset) return false;
    for (var i = 0; i < value.length; i++) {
      if (bytes[offset + i] != value[i]) return false;
    }
    return true;
  }

  if (prefix([0xff, 0xd8, 0xff])) return ('image/jpeg', 'jpg');
  if (prefix([137, 80, 78, 71, 13, 10, 26, 10])) return ('image/png', 'png');
  if (prefix('GIF87a'.codeUnits) || prefix('GIF89a'.codeUnits)) {
    return ('image/gif', 'gif');
  }
  if (prefix('BM'.codeUnits)) return ('image/bmp', 'bmp');
  if (prefix('RIFF'.codeUnits) && prefix('WEBP'.codeUnits, 8)) {
    return ('image/webp', 'webp');
  }
  if (prefix('ftyp'.codeUnits, 4)) {
    final brands = <String>[
      if (bytes.length >= 12) String.fromCharCodes(bytes.sublist(8, 12)),
      for (var i = 16; i + 4 <= bytes.length; i += 4)
        String.fromCharCodes(bytes.sublist(i, i + 4)),
    ];
    if (brands.any(const {'avif', 'avis'}.contains))
      return ('image/avif', 'avif');
    if (brands.any(const {'heic', 'heix', 'hevc', 'hevx'}.contains))
      return ('image/heic', 'heic');
    if (brands.any(const {'mif1', 'msf1'}.contains))
      return ('image/heif', 'heif');
  }
  return null;
}

bool imageHeader(List<int> bytes) => imageTypeHeader(bytes) != null;
