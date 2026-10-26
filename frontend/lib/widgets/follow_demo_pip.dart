import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 跟做画面上的示范小窗。拖动窗口移动，拖右下角按原比例缩放。
class FollowDemoPip extends StatefulWidget {
  const FollowDemoPip({
    super.key,
    required this.child,
    required this.aspectRatio,
    required this.waiting,
  });

  final Widget child;
  final double aspectRatio;
  final bool waiting;

  @override
  State<FollowDemoPip> createState() => _FollowDemoPipState();
}

/// 上一轮顾客拖好的位置和大小。同一台设备上会一直保留。
class FollowDemoPipMemory {
  static const widthKey = 'follow_demo_pip_width';
  static const leftKey = 'follow_demo_pip_left';
  static const topKey = 'follow_demo_pip_top';

  static double? width;
  static double? left;
  static double? top;
  static bool loaded = false;
  static int _revision = 0;

  static Future<void> load() async {
    if (loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      width ??= prefs.getDouble(widthKey);
      left ??= prefs.getDouble(leftKey);
      top ??= prefs.getDouble(topKey);
    } catch (_) {
      // 测试环境没有原生存储时，仍使用本进程里记下的位置。
    }
    loaded = true;
  }

  static void remember({
    required double width,
    required double left,
    required double top,
  }) {
    FollowDemoPipMemory.width = width;
    FollowDemoPipMemory.left = left;
    FollowDemoPipMemory.top = top;
    loaded = true;
    final revision = ++_revision;
    unawaited(_write(revision));
  }

  static Future<void> _write(int revision) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (revision != _revision) return;
      final width = FollowDemoPipMemory.width;
      final left = FollowDemoPipMemory.left;
      final top = FollowDemoPipMemory.top;
      if (width == null || left == null || top == null) return;
      await prefs.setDouble(widthKey, width);
      if (revision != _revision) return;
      await prefs.setDouble(leftKey, left);
      if (revision != _revision) return;
      await prefs.setDouble(topKey, top);
    } catch (_) {}
  }

  @visibleForTesting
  static void debugReset() {
    width = null;
    left = null;
    top = null;
    loaded = false;
  }
}

class _FollowDemoPipState extends State<FollowDemoPip> {
  static const _minWidth = 96.0;
  static const _initialWidth = 120.0;
  static const _margin = 12.0;
  static const _bottomReserve = 88.0;

  double _width = _initialWidth;
  Offset? _topLeft;
  Rect? _laidOut;

  double get _aspect =>
      widget.aspectRatio <= 0 || !widget.aspectRatio.isFinite
      ? 9 / 16
      : widget.aspectRatio;

  @override
  void initState() {
    super.initState();
    _applyMemory();
    if (!FollowDemoPipMemory.loaded) {
      unawaited(
        FollowDemoPipMemory.load().then((_) {
          if (!mounted) return;
          setState(_applyMemory);
        }),
      );
    }
  }

  void _applyMemory() {
    final width = FollowDemoPipMemory.width;
    final left = FollowDemoPipMemory.left;
    final top = FollowDemoPipMemory.top;
    if (width == null || left == null || top == null || width < _minWidth) {
      return;
    }
    _width = width;
    _topLeft = Offset(left, top);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = Size(constraints.maxWidth, constraints.maxHeight);
        final frame = _frameFor(area);
        _laidOut = frame;
        return Stack(
          children: [
            Positioned(
              left: frame.left,
              top: frame.top,
              width: frame.width,
              height: frame.height,
              child: _window(area),
            ),
          ],
        );
      },
    );
  }

  Rect _frameFor(Size area) {
    final maxWidth = _maxWidth(area, 0, 0);
    final width = _width.clamp(_minWidth, math.max(_minWidth, maxWidth)).toDouble();
    final height = width / _aspect;
    final maxLeft = math.max(0.0, area.width - width);
    final maxTop = math.max(0.0, area.height - height);
    final fallbackTop = math.max(0.0, area.height - height - _bottomReserve);
    final origin = _topLeft ?? Offset(_margin, fallbackTop);
    return Rect.fromLTWH(
      origin.dx.clamp(0.0, maxLeft).toDouble(),
      origin.dy.clamp(0.0, maxTop).toDouble(),
      width,
      height,
    );
  }

  double _maxWidth(Size area, double left, double top) {
    final byRight = math.max(0.0, area.width - left);
    final byBottom = math.max(0.0, area.height - top) * _aspect;
    return math.min(byRight, byBottom);
  }

  Widget _window(Size area) {
    final waiting = widget.waiting;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onPanUpdate: (details) => _move(details, area),
            onPanEnd: (_) => _remember(),
            child: DecoratedBox(
              key: const ValueKey('follow_demo_pip'),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: waiting ? const Color(0xFFFFC107) : Colors.white70,
                  width: 2,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.child,
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          waiting ? '已暂停' : '演示',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: GestureDetector(
            key: const ValueKey('follow_demo_pip_resize'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onPanUpdate: (details) => _resize(details, area),
            onPanEnd: (_) => _remember(),
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.all(5),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xCC111111),
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                    child: SizedBox.square(
                      dimension: 22,
                      child: Icon(
                        Icons.open_in_full,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _move(DragUpdateDetails details, Size area) {
    final current = _topLeft ?? _laidOut?.topLeft ?? Offset.zero;
    final height = _width / _aspect;
    setState(() {
      _topLeft = Offset(
        (current.dx + details.delta.dx)
            .clamp(0.0, math.max(0.0, area.width - _width))
            .toDouble(),
        (current.dy + details.delta.dy)
            .clamp(0.0, math.max(0.0, area.height - height))
            .toDouble(),
      );
    });
    final saved = _topLeft;
    if (saved != null) {
      FollowDemoPipMemory.remember(width: _width, left: saved.dx, top: saved.dy);
    }
  }

  void _resize(DragUpdateDetails details, Size area) {
    final fromHeight = details.delta.dy * _aspect;
    final delta = details.delta.dx.abs() >= fromHeight.abs()
        ? details.delta.dx
        : fromHeight;
    final origin = _topLeft ?? _laidOut?.topLeft ?? Offset.zero;
    final maxWidth = _maxWidth(area, origin.dx, origin.dy);
    final upper = math.max(_minWidth, maxWidth);
    final nextWidth = (_width + delta).clamp(_minWidth, upper).toDouble();
    setState(() {
      _width = nextWidth;
      _topLeft = origin;
    });
    FollowDemoPipMemory.remember(
      width: nextWidth,
      left: origin.dx,
      top: origin.dy,
    );
  }

  void _remember() {
    final origin = _topLeft;
    if (origin == null || _width < _minWidth) return;
    FollowDemoPipMemory.remember(width: _width, left: origin.dx, top: origin.dy);
  }
}
