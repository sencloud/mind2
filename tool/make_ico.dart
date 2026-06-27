// 将多尺寸 PNG 打包为 Windows .ico（PNG 压缩条目）。
// 用法：dart run tool/make_ico.dart
import 'dart:io';
import 'dart:typed_data';

void main() {
  const sizes = [16, 32, 48, 64, 128, 256];
  final images = [
    for (final s in sizes) File('build/icon_$s.png').readAsBytesSync(),
  ];

  final dirSize = 6 + 16 * sizes.length;
  final builder = BytesBuilder();

  final header = ByteData(6)
    ..setUint16(0, 0, Endian.little)
    ..setUint16(2, 1, Endian.little) // 1 = icon
    ..setUint16(4, sizes.length, Endian.little);
  builder.add(header.buffer.asUint8List());

  var offset = dirSize;
  for (var i = 0; i < sizes.length; i++) {
    final s = sizes[i];
    final entry = ByteData(16)
      ..setUint8(0, s >= 256 ? 0 : s)
      ..setUint8(1, s >= 256 ? 0 : s)
      ..setUint8(2, 0)
      ..setUint8(3, 0)
      ..setUint16(4, 1, Endian.little)
      ..setUint16(6, 32, Endian.little)
      ..setUint32(8, images[i].length, Endian.little)
      ..setUint32(12, offset, Endian.little);
    builder.add(entry.buffer.asUint8List());
    offset += images[i].length;
  }
  for (final img in images) {
    builder.add(img);
  }

  File('windows/runner/resources/app_icon.ico')
      .writeAsBytesSync(builder.toBytes());
  stdout.writeln('app_icon.ico written (${builder.length} bytes)');
}
