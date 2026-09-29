import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';

/// First screen: pick a name, then create a room or join one with its code.
class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final _name = TextEditingController();
  bool _busy = false;
  bool _prefilled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_prefilled) {
      _prefilled = true;
      _name.text = AppScope.roomOf(context).profile.name ?? '';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  RoomController get _room => AppScope.roomOf(context);

  bool _requireName() {
    if (_name.text.trim().isNotEmpty) return true;
    _tell(S.enterName);
    return false;
  }

  void _tell(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _create() async {
    if (!_requireName()) return;
    setState(() => _busy = true);
    final error = await _room.createRoom(_name.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) _tell(error);
  }

  Future<void> _join() async {
    if (!_requireName()) return;
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _CodeSheet(),
    );
    if (code == null || !mounted) return;
    setState(() => _busy = true);
    final error = await _room.join(code, _name.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) _tell(error);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 32),
                  const Center(child: _Logo()),
                  const SizedBox(height: 28),
                  Text(
                    S.appName,
                    textAlign: TextAlign.center,
                    style: theme.displayLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    S.tagline,
                    textAlign: TextAlign.center,
                    style: theme.bodyLarge?.copyWith(color: p.textSecondary),
                  ),
                  const SizedBox(height: 44),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => FocusScope.of(context).unfocus(),
                    maxLength: 24,
                    style: theme.bodyLarge,
                    decoration: const InputDecoration(
                      hintText: S.yourName,
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _create,
                    child: _label(S.createRoom),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _busy ? null : _join,
                    child: const Text(S.joinRoom),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 150),
    child: _busy
        ? SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: context.palette.onPrimary,
            ),
          )
        : Text(text, key: ValueKey(text)),
  );
}

/// Soft pink tile with a little equalizer: the app's mark until there is a real icon.
class _Logo extends StatefulWidget {
  const _Logo();

  @override
  State<_Logo> createState() => _LogoState();
}

class _LogoState extends State<_Logo> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_pulse.value);
        return Container(
          width: 112,
          height: 112,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(p.primaryContainer, p.primary, 0.25)!,
                p.primaryContainer,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: p.primary.withValues(alpha: 0.12 + 0.1 * t),
                blurRadius: 30 + 12 * t,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Icon(Icons.graphic_eq_rounded, size: 56, color: p.primary),
        );
      },
    );
  }
}

class _CodeSheet extends StatefulWidget {
  const _CodeSheet();

  @override
  State<_CodeSheet> createState() => _CodeSheetState();
}

class _CodeSheetState extends State<_CodeSheet> {
  static const _length = 6;
  final _code = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
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
          FilledButton(onPressed: _submit, child: const Text(S.join)),
        ],
      ),
    );
  }
}
