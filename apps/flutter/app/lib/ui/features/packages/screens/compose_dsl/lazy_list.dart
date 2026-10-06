// ignore_for_file: file_names

part of '../ToolPkgUiLauncherScreen.dart';

/// Hosts a virtualized list with stable keys and controlled end scrolling.
class _ComposeLazyList extends StatefulWidget {
  /// Creates a list using the serialized children and a deferred widget builder.
  const _ComposeLazyList({
    required this.axis,
    required this.reverse,
    required this.autoScrollToEnd,
    required this.spacing,
    required this.alignment,
    required this.nodes,
    required this.itemBuilder,
  });

  final Axis axis;
  final bool reverse;
  final bool autoScrollToEnd;
  final double spacing;
  final Alignment alignment;
  final List<_ComposeDslNode> nodes;
  final IndexedWidgetBuilder itemBuilder;

  /// Creates the list's scroll controller owner.
  @override
  State<_ComposeLazyList> createState() => _ComposeLazyListState();
}

class _ComposeLazyListState extends State<_ComposeLazyList> {
  final ScrollController _controller = ScrollController();
  bool _scrollScheduled = false;

  /// Moves to the logical end after updated item dimensions become available.
  void _scheduleEndScroll() {
    if (!widget.autoScrollToEnd || _scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_controller.hasClients || !widget.autoScrollToEnd) {
        return;
      }
      final position = _controller.position;
      final target = widget.reverse
          ? position.minScrollExtent
          : position.maxScrollExtent;
      if ((target - position.pixels).abs() > 0.5) {
        _controller.jumpTo(target);
      }
    });
  }

  /// Releases the controller when the plugin removes the list.
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Builds a lazy viewport using the actual parent constraints.
  @override
  Widget build(BuildContext context) {
    _scheduleEndScroll();
    final indices = <Object, int>{};
    for (var index = 0; index < widget.nodes.length; index++) {
      final key = widget.nodes[index].props['key'];
      if (key != null) {
        if (indices.containsKey(key)) {
          throw StateError('Duplicate Compose list key: $key');
        }
        indices[key] = index;
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _scheduleEndScroll();
            return false;
          },
          child: ComposeDslLazyListView(
            controller: _controller,
            scrollDirection: widget.axis,
            reverse: widget.reverse,
            shrinkWrap: widget.axis == Axis.vertical
                ? !constraints.hasBoundedHeight
                : !constraints.hasBoundedWidth,
            childrenDelegate: SliverChildBuilderDelegate(
              (context, index) {
                final child = widget.itemBuilder(context, index);
                return ComposeDslLazyListItem(
                  key: child.key,
                  axis: widget.axis,
                  alignment: widget.alignment,
                  child: Padding(
                    padding: widget.axis == Axis.vertical
                        ? EdgeInsets.only(
                            bottom: index + 1 < widget.nodes.length
                                ? widget.spacing
                                : 0,
                          )
                        : EdgeInsets.only(
                            right: index + 1 < widget.nodes.length
                                ? widget.spacing
                                : 0,
                          ),
                    child: child,
                  ),
                );
              },
              childCount: widget.nodes.length,
              findChildIndexCallback: (key) =>
                  key is ValueKey ? indices[key.value] : null,
            ),
          ),
        );
      },
    );
  }
}
