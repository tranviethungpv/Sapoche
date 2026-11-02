import 'package:flutter/widgets.dart';

/// Keeps its child built while it is scrolled far out of the list's reach, which a lazy list would drop.
///
/// For a row that is empty until its answer comes from the network: dropped and built again on the way back, it is empty
/// again for a frame and then grows to its full height above what the person is looking at, which sends that down the
/// page in one step, a jerk in the middle of a fling. Kept, it comes back with the height it had.
class KeptAlive extends StatefulWidget {
  const KeptAlive({super.key, required this.child});

  final Widget child;

  @override
  State<KeptAlive> createState() => _KeptAliveState();
}

class _KeptAliveState extends State<KeptAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
