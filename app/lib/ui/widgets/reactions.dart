import 'dart:async';
import 'dart:math';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';

/// The quick reactions, one tap each, and the way to all the others: they fly up here at once and on the screens of
/// the others.
class ReactionBar extends StatelessWidget {
  const ReactionBar({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      label: S.react,
      container: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final reaction in Reaction.quick)
            InkResponse(
              key: ValueKey('react-${reaction.name}'),
              radius: 22,
              highlightColor: p.primary.withValues(alpha: 0.12),
              onTap: () {
                HapticFeedback.selectionClick();
                controller.react(reaction);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  reaction.emoji,
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            ),
          ReactButton(controller: controller),
        ],
      ),
    );
  }
}

/// The way to all the emoji. Nothing where the room cannot pass reactions on.
class ReactButton extends StatelessWidget {
  const ReactButton({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => controller.hasChat
        ? IconButton(
            onPressed: () => showReactionPicker(context, controller),
            tooltip: S.reactMore,
            icon: Icon(
              Icons.add_reaction_outlined,
              size: 26,
              color: context.palette.textTertiary,
            ),
          )
        : const SizedBox.shrink(),
  );
}

/// Every emoji, as a keyboard has them. Picking one sends it and the sheet stays, so that one can be sent again and
/// again; they fly up over the grid, and a touch outside the sheet puts it away.
void showReactionPicker(BuildContext context, RoomController controller) {
  showModalBottomSheet<void>(
    useRootNavigator: true,
    useSafeArea: true,
    context: context,
    isScrollControlled: true,
    builder: (context) => _ReactionPicker(controller: controller),
  );
}

class _ReactionPicker extends StatelessWidget {
  const _ReactionPicker({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Where what was sent is seen to fly, over the words that say the sheet stays
          ReactionShower(
            controller: controller,
            child: SizedBox(
              height: _flightHeight,
              width: double.infinity,
              child: Center(
                child: Text(
                  S.reactKeepTapping,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: p.textTertiary),
                ),
              ),
            ),
          ),
          EmojiPicker(
            onEmojiSelected: (_, emoji) {
              HapticFeedback.selectionClick();
              controller.react(Reaction.of(emoji.emoji));
            },
            config: Config(
              height: MediaQuery.sizeOf(context).height * 0.42,
              emojiViewConfig: EmojiViewConfig(
                backgroundColor: Colors.transparent,
                emojiSizeMax: 30,
                noRecents: Text(
                  S.reactNoRecents,
                  style: TextStyle(color: p.textSecondary),
                ),
              ),
              categoryViewConfig: CategoryViewConfig(
                initCategory: Category.SMILEYS,
                backgroundColor: Colors.transparent,
                indicatorColor: p.primary,
                iconColor: p.textTertiary,
                iconColorSelected: p.primary,
              ),
              bottomActionBarConfig: BottomActionBarConfig(
                showBackspaceButton: false,
                backgroundColor: Colors.transparent,
                buttonColor: p.primary.withValues(alpha: 0.12),
                buttonIconColor: p.primary,
              ),
              searchViewConfig: SearchViewConfig(
                backgroundColor: p.surface,
                buttonIconColor: p.textSecondary,
                hintText: S.reactSearch,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The height of what shows the emoji flying above the grid.
const _flightHeight = 120.0;

/// Reactions flying up over [child], from the bottom of the place: the room's, and this device's own. Each one ends
/// by itself after a moment, so nothing keeps the screen drawing once they stop coming.
class ReactionShower extends StatefulWidget {
  const ReactionShower({
    super.key,
    required this.controller,
    required this.child,
  });

  final RoomController controller;
  final Widget child;

  /// How long one reaction takes to rise and fade.
  static const flight = Duration(milliseconds: 3400);

  /// The most reactions in the air at once; more are left out rather than slow the phone down.
  static const maxFlying = 24;

  @override
  State<ReactionShower> createState() => _ReactionShowerState();
}

class _ReactionShowerState extends State<ReactionShower>
    with TickerProviderStateMixin {
  final _flying = <_Flight>[];
  final _random = Random();
  final _waiting = <Timer>[];
  StreamSubscription<RoomReaction>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.controller.reactions.listen(_onReaction);
    widget.controller.watchReactions();
  }

  @override
  void didUpdateWidget(ReactionShower old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _subscription?.cancel();
      old.controller.unwatchReactions();
      _subscription = widget.controller.reactions.listen(_onReaction);
      widget.controller.watchReactions();
    }
  }

  void _onReaction(RoomReaction reaction) {
    // Several taps of somebody else come as one message: they are let out one after another
    for (var i = 0; i < reaction.count; i++) {
      if (i == 0) {
        _launch(reaction, named: !reaction.mine);
      } else {
        late final Timer timer;
        timer = Timer(Duration(milliseconds: 110 * i), () {
          _waiting.remove(timer);
          _launch(reaction, named: false);
        });
        _waiting.add(timer);
      }
    }
  }

  void _launch(RoomReaction reaction, {required bool named}) {
    if (!mounted || _flying.length >= ReactionShower.maxFlying) return;
    final controller = AnimationController(
      vsync: this,
      duration: ReactionShower.flight,
    );
    final flight = _Flight(
      reaction: reaction.reaction,
      name: named ? reaction.name : null,
      controller: controller,
      // Toward the right, where a thumb is, and never off the edge
      x: 0.55 + _random.nextDouble() * 0.33,
      sway: (_random.nextBool() ? 1 : -1) * (10 + _random.nextDouble() * 14),
      rise: 0.45 + _random.nextDouble() * 0.2,
    );
    setState(() => _flying.add(flight));
    controller.forward().whenComplete(() {
      if (!mounted) return;
      setState(() => _flying.remove(flight));
      controller.dispose();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    widget.controller.unwatchReactions();
    for (final timer in _waiting) {
      timer.cancel();
    }
    for (final flight in _flying) {
      flight.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_flying.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final flight in _flying)
                      _FlyingReaction(
                        key: ObjectKey(flight),
                        flight: flight,
                        size: box.biggest,
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Flight {
  _Flight({
    required this.reaction,
    required this.name,
    required this.controller,
    required this.x,
    required this.sway,
    required this.rise,
  });

  final Reaction reaction;

  /// Who sent it, shown under the first of a burst from somebody else.
  final String? name;
  final AnimationController controller;

  /// Where it starts across the place, as a share of its width.
  final double x;

  /// How far it rocks to the side, in logical pixels.
  final double sway;

  /// How far up it goes, as a share of the place's height.
  final double rise;
}

class _FlyingReaction extends StatelessWidget {
  const _FlyingReaction({super.key, required this.flight, required this.size});

  final _Flight flight;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedBuilder(
      animation: flight.controller,
      builder: (context, child) {
        final t = flight.controller.value;
        final eased = Curves.easeOut.transform(t);
        final pop = t < 0.12 ? Curves.easeOutBack.transform(t / 0.12) : 1.0;
        final fade = t < 0.65 ? 1.0 : 1 - (t - 0.65) / 0.35;
        return Positioned(
          left: size.width * flight.x + sin(t * pi * 2.2) * flight.sway - 20,
          bottom: 24 + size.height * flight.rise * eased,
          child: Opacity(
            opacity: fade.clamp(0.0, 1.0),
            child: Transform.scale(scale: 0.6 + 0.4 * pop, child: child),
          ),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(flight.reaction.emoji, style: const TextStyle(fontSize: 34)),
          if (flight.name case final name? when name.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: p.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                name,
                maxLines: 1,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: p.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
