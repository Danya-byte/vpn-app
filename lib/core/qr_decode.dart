import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// True if [b] looks like a raster image (PNG/JPEG/GIF/BMP/WebP) by magic bytes
/// — so the import path can try QR-decoding it instead of reading it as text.
bool looksLikeImage(List<int> b) {
  if (b.length < 4) return false;
  // PNG  89 50 4E 47
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true;
  // JPEG FF D8 FF
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
  // GIF  47 49 46
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;
  // BMP  42 4D
  if (b[0] == 0x42 && b[1] == 0x4D) return true;
  // WebP RIFF....WEBP
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return true;
  }
  return false;
}

/// Decode a QR OFF the UI isolate — the pixel loop + `tryHarder` can take a
/// second or more on a large screenshot, which would freeze the window. The
/// import path uses this; the sync [decodeQrFromImage] stays for tests.
Future<String?> decodeQrFromImageInBackground(List<int> bytes) =>
    compute(decodeQrFromImage, bytes);

/// Decode a QR code from a raster image's bytes; returns the embedded text, or
/// null (not an image / no QR / unreadable). Pure Dart — no camera, no native —
/// so a config QR shared in Telegram (the dominant RF distribution channel) can
/// be dropped/picked straight into the app. `tryHarder` so a screenshot/photo
/// of a QR (scaled, slightly skewed) still decodes.
String? decodeQrFromImage(List<int> bytes) {
  try {
    var image = img.decodeImage(Uint8List.fromList(bytes));
    if (image == null) return null;
    // Bound the work: a QR needs only moderate resolution to decode, but a raw
    // 4K screenshot is 8.3M px — a 33 MB Int32List plus a multi-second double
    // loop. Cap the longest side so a dropped screenshot decodes fast (most
    // shared QRs dominate the frame, so this rarely shrinks the code itself).
    const maxSide = 1600;
    if (image.width > maxSide || image.height > maxSide) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxSide)
          : img.copyResize(image, height: maxSide);
    }
    final w = image.width, h = image.height;
    final pixels = Int32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        // zxing2 RGBLuminanceSource expects packed ARGB ints.
        pixels[y * w + x] = (0xFF << 24) |
            (p.r.toInt() << 16) |
            (p.g.toInt() << 8) |
            p.b.toInt();
      }
    }
    final source = RGBLuminanceSource(w, h, pixels);
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    final result = QRCodeReader().decode(
      bitmap,
      hints: DecodeHints()..put(DecodeHintType.tryHarder),
    );
    final text = result.text.trim();
    return text.isNotEmpty ? text : null;
  } catch (_) {
    return null; // no QR found / unreadable image
  }
}
