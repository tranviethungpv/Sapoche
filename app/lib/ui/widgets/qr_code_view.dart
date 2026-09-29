import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// A QR code for [data], black on white whatever the theme, because that is what cameras read best.
class QrCodeView extends StatefulWidget {
  const QrCodeView({super.key, required this.data, this.size = 190});

  final String data;
  final double size;

  @override
  State<QrCodeView> createState() => _QrCodeViewState();
}

class _QrCodeViewState extends State<QrCodeView> {
  late QrImage _image = _encode(widget.data);

  // Choosing the best of the eight mask patterns takes a moment, so it is done once per address
  static QrImage _encode(String data) => QrImage(
    QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
  );

  @override
  void didUpdateWidget(QrCodeView old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data) _image = _encode(widget.data);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _QrPainter(_image),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final module = size.width / image.moduleCount;
    // No anti-aliasing, or hairlines show between neighbouring squares
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (image.isDark(row, col)) {
          canvas.drawRect(
            Rect.fromLTWH(col * module, row * module, module, module),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
