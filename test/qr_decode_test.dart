import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:vpn_app/core/qr_decode.dart';

/// Renders [text] to a real QR PNG so the decode path is tested end-to-end.
List<int> qrPng(String text) {
  final qr = Encoder.encode(text, ErrorCorrectionLevel.m);
  final m = qr.matrix!;
  const scale = 8, quiet = 4;
  final size = (m.width + quiet * 2) * scale;
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  for (var y = 0; y < m.height; y++) {
    for (var x = 0; x < m.width; x++) {
      if (m.get(x, y) == 1) {
        for (var dy = 0; dy < scale; dy++) {
          for (var dx = 0; dx < scale; dx++) {
            image.setPixelRgb(
                (x + quiet) * scale + dx, (y + quiet) * scale + dy, 0, 0, 0);
          }
        }
      }
    }
  }
  return img.encodePng(image);
}

void main() {
  test('QR round-trip: a vless link encodes and decodes back exactly', () {
    const link =
        'vless://11111111-1111-1111-1111-111111111111@198.51.100.10:443?security=reality&pbk=KEY&sid=ab&sni=m.vk.com#QR';
    final png = qrPng(link);
    expect(looksLikeImage(png), isTrue, reason: 'PNG magic bytes');
    expect(decodeQrFromImage(png), link);
  });

  test('QR round-trip: a base64 subscription blob survives', () {
    const sub = 'aHR0cHM6Ly9leGFtcGxlLmNvbS9zdWI'; // some base64
    expect(decodeQrFromImage(qrPng(sub)), sub);
  });

  test('looksLikeImage detects PNG/JPEG/GIF/BMP, rejects text', () {
    expect(looksLikeImage([0x89, 0x50, 0x4E, 0x47, 0]), isTrue); // PNG
    expect(looksLikeImage([0xFF, 0xD8, 0xFF, 0xE0]), isTrue); // JPEG
    expect(looksLikeImage([0x47, 0x49, 0x46, 0x38]), isTrue); // GIF
    expect(looksLikeImage([0x42, 0x4D, 0, 0]), isTrue); // BMP
    expect(looksLikeImage('vless://x'.codeUnits), isFalse);
    expect(looksLikeImage('{"outbounds"'.codeUnits), isFalse);
  });

  test('decodeQrFromImage returns null for a non-QR image (no crash)', () {
    final plain = img.Image(width: 64, height: 64);
    img.fill(plain, color: img.ColorRgb8(120, 120, 120));
    expect(decodeQrFromImage(img.encodePng(plain)), isNull);
  });

  test('decodeQrFromImage returns null for garbage bytes (no crash)', () {
    expect(decodeQrFromImage([1, 2, 3, 4, 5]), isNull);
  });
}
