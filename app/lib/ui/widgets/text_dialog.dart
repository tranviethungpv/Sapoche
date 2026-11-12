import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../strings.dart';

/// Asks for one line of text. Gives back what was typed, trimmed, or null when the person cancels.
Future<String?> showTextDialog(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
  int maxLength = 24,
  TextCapitalization capitalization = TextCapitalization.words,
  bool digits = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(
    title: title,
    hint: hint,
    initial: initial,
    maxLength: maxLength,
    capitalization: capitalization,
    digits: digits,
  ),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.maxLength,
    required this.capitalization,
    required this.digits,
  });

  final String title;
  final String hint;
  final String initial;
  final int maxLength;
  final TextCapitalization capitalization;

  /// A number: the number keyboard, and nothing else can be typed.
  final bool digits;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _text.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _text,
        autofocus: true,
        maxLength: widget.maxLength,
        textCapitalization: widget.capitalization,
        keyboardType: widget.digits ? TextInputType.number : null,
        inputFormatters: widget.digits
            ? [FilteringTextInputFormatter.digitsOnly]
            : null,
        decoration: InputDecoration(hintText: widget.hint, counterText: ''),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(S.cancel),
        ),
        TextButton(onPressed: _submit, child: Text(S.save)),
      ],
    );
  }
}
