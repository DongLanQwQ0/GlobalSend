import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/image_signature.dart';

void main() {
  const png = ('image/png', 'png');
  test(
    'container fixes suffixless and placeholder names, retaining real stems',
    () {
      expect(imageFileName('977.pic', png), '977.png');
      expect(imageFileName('Photo', png), 'Photo.png');
      expect(imageFileName('Photo.PNG', png), 'Photo.PNG');
      expect(imageFileName('wrong.jpg', png), 'wrong.png');
      expect(imageFileName('notes.final', png), 'notes.final.png');
      expect(
        imageFileName('original.jpeg', ('image/jpeg', 'jpg')),
        'original.jpeg',
      );
      expect(imageFileName('document.pdf', null), 'document.pdf');
    },
  );
  test('HEIC and AVIF container brands supply the correct suffix', () {
    List<int> header(String major, String compatible) => [
      0,
      0,
      0,
      24,
      ...'ftyp'.codeUnits,
      ...major.codeUnits,
      0,
      0,
      0,
      0,
      ...compatible.codeUnits,
    ];
    expect(imageTypeHeader(header('heic', 'mif1')), ('image/heic', 'heic'));
    expect(imageTypeHeader(header('mif1', 'avif')), ('image/avif', 'avif'));
    expect(imageTypeHeader(header('mp42', 'isom')), isNull);
  });
}
