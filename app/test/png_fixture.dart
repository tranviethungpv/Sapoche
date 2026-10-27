import 'dart:io';
import 'dart:typed_data';

/// A picture that really decodes: a PNG of one colour, [side] pixels square.
Uint8List solidPng(int red, int green, int blue, {int side = 16}) =>
    bandsPng(side, side, [
      [red, green, blue],
    ]);

/// A PNG [width] by [height] pixels made of horizontal bands, from the top down, one for each colour given.
Uint8List bandsPng(int width, int height, List<List<int>> bands) {
  final rows = BytesBuilder();
  for (var y = 0; y < height; y++) {
    rows.addByte(0); // no filter
    final rgb = bands[y * bands.length ~/ height];
    for (var x = 0; x < width; x++) {
      rows.add(rgb);
    }
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bits per channel
    ..setUint8(9, 2); // RGB
  return (BytesBuilder()
        ..add([137, 80, 78, 71, 13, 10, 26, 10])
        ..add(_chunk('IHDR', header.buffer.asUint8List()))
        ..add(_chunk('IDAT', zlib.encode(rows.toBytes())))
        ..add(_chunk('IEND', const [])))
      .toBytes();
}

Uint8List _chunk(String type, List<int> data) {
  final body = [...type.codeUnits, ...data];
  final out = ByteData(12 + data.length)..setUint32(0, data.length);
  final bytes = out.buffer.asUint8List()..setRange(4, 4 + body.length, body);
  out.setUint32(8 + data.length, _crc32(body));
  return bytes;
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
