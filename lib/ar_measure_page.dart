import 'dart:async';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:collection/collection.dart';

class ARMeasurePage extends StatefulWidget {
  const ARMeasurePage({super.key});
  @override
  State<ARMeasurePage> createState() => _ARMeasurePageState();
}

class _ARMeasurePageState extends State<ARMeasurePage> {
  late ARKitController arkitController;

  // ---- 测量相关 ----
  final List<vector.Vector3> _pts = [];
  final List<ARKitNode> _nodes = [];
  vector.Vector3? _lastPosition;
  String _info = '将手机对准地面/桌面，缓慢移动后点击屏幕打点';
  String _result = '';

  // ---- YOLO 检测相关 ----
  static const _methodChannel = MethodChannel('yolo_detect');
  static const _eventChannel = EventChannel('yolo_detect/events');
  StreamSubscription? _detectSub;
  List<Detection> _detections = [];
  bool _detecting = false;
  int _snailCount = 0;

  @override
  void dispose() {
    _stopDetection();
    arkitController.dispose();
    super.dispose();
  }

  // ============================================================
  //  YOLO 检测控制
  // ============================================================

  Future<void> _startDetection() async {
    if (_detecting) return;
    try {
      await _methodChannel.invokeMethod('start');
      _detectSub = _eventChannel
          .receiveBroadcastStream()
          .listen(_onDetections, onError: (_) {});
      setState(() => _detecting = true);
    } catch (e) {
      debugPrint('启动检测失败: $e');
    }
  }

  Future<void> _stopDetection() async {
    _detectSub?.cancel();
    _detectSub = null;
    try {
      await _methodChannel.invokeMethod('stop');
    } catch (_) {}
    if (mounted) {
      setState(() {
        _detecting = false;
        _detections = [];
        _snailCount = 0;
      });
    }
  }

  void _onDetections(dynamic data) {
    if (!mounted || data == null) return;
    final list = (data as List).map((e) {
      final m = Map<String, dynamic>.from(e);
      return Detection(
        x: (m['x'] as num).toDouble(),
        y: (m['y'] as num).toDouble(),
        w: (m['w'] as num).toDouble(),
        h: (m['h'] as num).toDouble(),
        confidence: (m['confidence'] as num).toDouble(),
        label: m['label'] as String? ?? 'snail',
      );
    }).where((d) => d.confidence > 0.7).toList();

    setState(() {
      _detections = list;
      _snailCount = list.length;
    });
  }

  // ============================================================
  //  UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        // AR 场景
        ARKitSceneView(
          enableTapRecognizer: true,
          onARKitViewCreated: _onARKitViewCreated,
        ),

        // YOLO 检测框叠加层
        if (_detecting)
          Positioned.fill(
            child: CustomPaint(
              painter: DetectionPainter(detections: _detections),
            ),
          ),

        // 顶部提示
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _info,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
        ),

        // 检测计数徽章（右上角）
        if (_detecting && _snailCount > 0)
          Positioned(
            top: MediaQuery.of(context).padding.top + 70,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.85),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bug_report, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    '🐌 ×$_snailCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // 中心准星
        Center(
          child: Icon(Icons.add, color: Colors.white.withOpacity(0.6), size: 36),
        ),

        // 底部面板
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // 距离/面积结果
            if (_result.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _result,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

            // 按钮行 1：测量操作
            Row(children: [
              _btn('清空', Icons.delete_outline, _clear),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _pts.length >= 3 ? _showArea : null,
                  icon: const Icon(Icons.crop_square),
                  label: Text('测面积 (${_pts.length} 点)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ]),

            const SizedBox(height: 10),

            // 按钮行 2：YOLO 检测开关
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _detecting ? _stopDetection : _startDetection,
                icon: Icon(_detecting ? Icons.stop_circle : Icons.radar),
                label: Text(_detecting ? '停止检测' : '开始钉螺检测'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _detecting ? Colors.red : Colors.orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.grey[800],
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      ),
    );
  }

  // ============================================================
  //  AR 回调
  // ============================================================

  void _onARKitViewCreated(ARKitController controller) {
    arkitController = controller;
    arkitController.onARTap = (ar) {
      final point = ar.firstWhereOrNull(
        (o) => o.type == ARKitHitTestResultType.featurePoint,
      );
      if (point != null) {
        _onTapPoint(point);
      }
    };

    // AR 就绪后自动开始检测
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) _startDetection();
    });
  }

  void _onTapPoint(ARKitTestResult hitResult) {
    final position = vector.Vector3(
      hitResult.worldTransform.getColumn(3).x,
      hitResult.worldTransform.getColumn(3).y,
      hitResult.worldTransform.getColumn(3).z,
    );

    setState(() {
      _addDot(position);
      if (_lastPosition != null) {
        _addLine(_lastPosition!, position);
      }
      _pts.add(position);
      _lastPosition = position;
      _updateReadout();
    });
  }

  // ============================================================
  //  3D 对象
  // ============================================================

  void _addDot(vector.Vector3 pos) {
    final material = ARKitMaterial(
      lightingModelName: ARKitLightingModel.constant,
      diffuse: ARKitMaterialProperty.color(Colors.yellow),
    );
    final sphere = ARKitSphere(radius: 0.008, materials: [material]);
    final node = ARKitNode(geometry: sphere, position: pos);
    arkitController.add(node);
    _nodes.add(node);
  }

  void _addLine(vector.Vector3 from, vector.Vector3 to) {
    final line = ARKitLine(fromVector: from, toVector: to);
    final node = ARKitNode(geometry: line);
    arkitController.add(node);
    _nodes.add(node);
  }

  // ============================================================
  //  测量逻辑
  // ============================================================

  void _updateReadout() {
    if (_pts.length < 2) {
      _result = '';
      _info = '已标记 ${_pts.length} 个点，继续点击屏幕';
      return;
    }
    final dist = _pts.last.distanceTo(_pts[_pts.length - 2]);
    _result = '📏 ${_fmtLen(dist)}';
    _info = '已标记 ${_pts.length} 个点 ｜ 点击继续打点';
  }

  void _showArea() {
    if (_pts.length < 3) return;
    setState(() {
      _addLine(_pts.last, _pts.first);
      double perimeter = 0;
      for (int i = 1; i < _pts.length; i++) {
        perimeter += _pts[i].distanceTo(_pts[i - 1]);
      }
      perimeter += _pts.last.distanceTo(_pts.first);
      final area = _shoelaceXZ(_pts);
      _result = '📏 周长：${_fmtLen(perimeter)}\n📐 面积：${_fmtArea(area)}';
      _info = '测量完成！点「清空」重新开始';
    });
  }

  void _clear() {
    setState(() {
      for (final node in _nodes) {
        arkitController.remove(node.name);
      }
      _nodes.clear();
      _pts.clear();
      _lastPosition = null;
      _result = '';
      _info = '将手机对准地面/桌面，缓慢移动后点击屏幕打点';
    });
  }

  // ============================================================
  //  工具
  // ============================================================

  double _shoelaceXZ(List<vector.Vector3> pts) {
    if (pts.length < 3) return 0;
    double s = 0;
    final n = pts.length;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      s += pts[i].x * pts[j].z - pts[j].x * pts[i].z;
    }
    return (s / 2).abs();
  }

  String _fmtLen(double m) {
    if (m < 1) return '${(m * 100).toStringAsFixed(1)} cm';
    return '${m.toStringAsFixed(2)} m';
  }

  String _fmtArea(double sq) {
    if (sq < 1) return '${(sq * 10000).toStringAsFixed(1)} cm²';
    return '${sq.toStringAsFixed(2)} m²';
  }
}

// ============================================================
//  检测数据模型
// ============================================================

class Detection {
  final double x, y, w, h, confidence;
  final String label;
  const Detection({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.confidence,
    required this.label,
  });
}

// ============================================================
//  检测框绘制
// ============================================================

class DetectionPainter extends CustomPainter {
  final List<Detection> detections;
  DetectionPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final fillPaint = Paint()
      ..color = Colors.red.withOpacity(0.15)
      ..style = PaintingStyle.fill;

    for (final d in detections) {
      final rect = Rect.fromLTWH(
        d.x * size.width,
        d.y * size.height,
        d.w * size.width,
        d.h * size.height,
      );

      // 半透明填充
      canvas.drawRect(rect, fillPaint);
      // 边框
      canvas.drawRect(rect, boxPaint);

      // 标签背景
      final label = '🐌 ${(d.confidence * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.red,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(canvas, Offset(rect.left, rect.top - tp.height - 2));
    }
  }

  @override
  bool shouldRepaint(covariant DetectionPainter old) => true;
}