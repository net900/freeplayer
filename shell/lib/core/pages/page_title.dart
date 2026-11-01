import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Publishes the current page title to the window chrome. Pages report their
/// title through [PageTitleBinding]; the top bar shows the newest one.
class PageTitleController {
  final ValueNotifier<String> _title = ValueNotifier<String>('');
  final ValueNotifier<bool> _hideTitle = ValueNotifier<bool>(false);
  final List<_TitleNode> _nodes = <_TitleNode>[];

  ValueListenable<String> get listenable => _title;
  ValueListenable<bool> get hideTitle => _hideTitle;
  String get value => _title.value;

  _TitleNode push(String title, {bool hide = false}) {
    final node = _TitleNode(title, hide);
    _nodes.add(node);
    _title.value = title;
    _hideTitle.value = hide;
    return node;
  }

  void update(_TitleNode node, String title) {
    node.title = title;
    if (_nodes.isNotEmpty && identical(_nodes.last, node)) {
      _title.value = title;
    }
  }

  void release(_TitleNode node) {
    if (!_nodes.remove(node)) return;
    _title.value = _nodes.isEmpty ? '' : _nodes.last.title;
    _hideTitle.value = _nodes.isEmpty ? false : _nodes.last.hide;
  }
}

class _TitleNode {
  _TitleNode(this.title, this.hide);

  String title;
  final bool hide;
}

class PageTitleScope extends InheritedWidget {
  const PageTitleScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final PageTitleController controller;

  static PageTitleController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageTitleScope>()?.controller;

  static PageTitleController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'PageTitleScope is missing above this widget');
    return controller!;
  }

  @override
  bool updateShouldNotify(PageTitleScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Reports [title] while mounted and restores the previous title on dispose.
class PageTitleBinding extends StatefulWidget {
  const PageTitleBinding({
    super.key,
    required this.title,
    required this.child,
    this.hideInChrome = false,
  });

  final String title;
  final Widget child;

  /// Detail pages show the title in the page body; the chrome repeats nothing.
  final bool hideInChrome;

  @override
  State<PageTitleBinding> createState() => _PageTitleBindingState();
}

class _PageTitleBindingState extends State<PageTitleBinding> {
  PageTitleController? _controller;
  _TitleNode? _node;
  bool _attachScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = PageTitleScope.maybeOf(context);
    if (identical(controller, _controller)) return;
    _detach();
    _controller = controller;
    _scheduleAttach();
  }

  @override
  void didUpdateWidget(PageTitleBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title == widget.title) return;
    final controller = _controller;
    final node = _node;
    if (controller == null || node == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(node, _node)) {
        controller.update(node, widget.title);
      }
    });
  }

  void _scheduleAttach() {
    final controller = _controller;
    if (controller == null || _attachScheduled || _node != null) return;
    _attachScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachScheduled = false;
      if (!mounted || !identical(controller, _controller) || _node != null) {
        return;
      }
      _node = controller.push(widget.title, hide: widget.hideInChrome);
    });
  }

  void _detach() {
    final controller = _controller;
    final node = _node;
    _node = null;
    if (controller == null || node == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.release(node);
    });
  }

  @override
  void dispose() {
    _detach();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
