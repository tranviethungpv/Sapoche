import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../strings.dart';

/// Asks for a room code. Gives back the six characters, or null when closed. A code on the clipboard
/// or one that came with an invitation is filled in.
Future<String?> showCodeSheet(BuildContext context, {String? initialCode}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CodeSheet(initialCode: initialCode),
    );

class CodeSheet extends StatefulWidget {
  const CodeSheet({super.key, this.initialCode});

  /// Filled in when the sheet was opened by an invitation link.
  final String? initialCode;

  @override
  State<CodeSheet> createState() => _CodeSheetState();
}

class _CodeSheetState extends State<CodeSheet> {
  static const _length = 6;
  final _code = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialCode != null) {
      _code.text = widget.initialCode!;
      return;
    }
    // A code on the clipboard is the common case: offer it right away
    Clipboard.getData(Clipboard.kTextPlain).then((data) {
      final text = data?.text?.trim().toUpperCase() ?? '';
      if (mounted &&
          _code.text.isEmpty &&
          RegExp('^[A-Z0-9]{$_length}\$').hasMatch(text)) {
        setState(() => _code.text = text);
      }
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim().toUpperCase();
    if (code.length != _length) {
      setState(() => _error = S.codeInvalid);
      return;
    }
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        4,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(S.joinRoom, style: theme.headlineSmall),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            textAlign: TextAlign.center,
            maxLength: _length,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
            ],
            style: theme.headlineMedium?.copyWith(letterSpacing: 8),
            decoration: InputDecoration(
              hintText: S.roomCode,
              counterText: '',
              errorText: _error,
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _submit, child: Text(S.join)),
        ],
      ),
    );
  }
}
