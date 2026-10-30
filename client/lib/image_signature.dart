bool knownImageName(String name) => const {
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'bmp',
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
  return null;
}

bool imageHeader(List<int> bytes) => imageTypeHeader(bytes) != null;
