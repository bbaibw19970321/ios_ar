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

  // ✅ 改进3: 世界坐标(显示) + 局部坐标(计算)
  final List<vector.Vector3> _worldPts = [];
  final List<vector.Vector3> _localPts = [];
  vector.Vector3? _origin; // 第一个点 = 局部原点

  final List<ARKitNode> _nodes = [];
  String _info = '将手机对准地面，缓慢移动后点击屏幕打点';
  String _result = '';

  // ✅ 改进5: tracking
  bool _trackingOK = true;
  Timer? _trackingTimer;

  // ✅ 改进2: 防抖
  DateTime? _lastTapTime;
  vector.Vector3? _lastTapPos;

  // YOLO
  static const _ch = MethodChannel('yolo_detect');
  static const _evCh = EventChannel('yolo_detect/events');
  StreamSubscription? _detectSub;
  List<Detection> _detections = [];
  bool _detecting = false;
  int _snailCount = 0;

  @override
  void initState() {
    super.initState();
    // ✅ 改进5: 每 500ms 轮询 tracking 状态
    _trackingTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _pollTracking());
  }

  @override
  void dispose() {
    _trackingTimer?.cancel();
    _stopDetection();
    arkitController.dispose();
    super.dispose();
  }

  // ============================================================
  //  ✅ 改进5: 轮询 tracking
  // ============================================================

  Future<void> _pollTracking() async {
    try {
      final state = await _ch.invokeMethod<String>('getTrackingState') ?? 'unknown';
      if (!mounted) return;
      final ok = state == 'normal';
      if (ok != _trackingOK) {
        setState(() {
          _trackingOK = ok;
          if (!ok) _info = '⚠️ ${_hint(state)}，请缓慢移动对准地面';
        });
      }
    } catch (_) {}
  }

  String _hint(String s) {
    if (s.contains('motion')) return '移动过快';
    if (s.contains('features')) return '特征不足';
    if (s.contains('init')) return '正在初始化';
    if (s.contains('reloc')) return '重新定位中';
    return '追踪不稳定';
  }

  // ============================================================
  //  YOLO（不变）
  // ============================================================

  Future<void> _startDetection() async {
    if (_detecting) return;
    try {
      await _ch.invokeMethod('start');
      _detectSub = _evCh.receiveBroadcastStream().listen(_onDetections,
          onError: (e) => debugPrint('❌ $e'));
      setState(() { _detecting = true; _info = '🔍 钉螺检测已启动'; });
    } on PlatformException catch (e) {
      if (mounted) setState(() => _info = '❌ ${e.message}');
    }
  }

  Future<void> _stopDetection() async {
    _detectSub?.cancel(); _detectSub = null;
    try { await _ch.invokeMethod('stop'); } catch (_) {}
    if (mounted) setState(() { _detecting = false; _detections = []; _snailCount = 0; });
  }

  void _onDetections(dynamic data) {
    if (!mounted || data == null) return;
    try {
      final list = (data as List).map((e) {
        final m = Map<String, dynamic>.from(e);
        return Detection(
          x: (m['x'] as num).toDouble(), y: (m['y'] as num).toDouble(),
          w: (m['w'] as num).toDouble(), h: (m['h'] as num).toDouble(),
          confidence: (m['conf'] as num).toDouble(),
          label: m['label'] as String? ?? 'snail',
        );
      }).where((d) => d.confidence > 0.8).toList();
      setState(() { _detections = list; _snailCount = list.length; });
    } catch (_) {}
  }

  // ============================================================
  //  UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        // ✅ 保持 enableTapRecognizer: true（不动！）
        ARKitSceneView(
          enableTapRecognizer: true,
          onARKitViewCreated: _onARKitViewCreated,
        ),

        if (_detecting)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: DetectionPainter(detections: _detections)),
            ),
          ),

        Positioned(
          top: MediaQuery.of(context).padding.top + 12, left: 16, right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _trackingOK ? Colors.black54 : Colors.orange.shade900.withOpacity(0.9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(_info, style: const TextStyle(color: Colors.white, fontSize: 14), textAlign: TextAlign.center),
          ),
        ),

        if (_detecting && _snailCount > 0)
          Positioned(
            top: MediaQuery.of(context).padding.top + 70, right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.red.withOpacity(0.85), borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.bug_report, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text('🐌 ×$_snailCount', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ]),
            ),
          ),

        Center(child: Icon(Icons.add, color: Colors.white.withOpacity(0.6), size: 36)),

        Positioned(
          left: 16, right: 16, bottom: MediaQuery.of(context).padding.bottom + 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_result.isNotEmpty)
              Container(
                width: double.infinity, padding: const EdgeInsets.all(14), margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                child: Text(_result, style: const TextStyle(color: Colors.greenAccent, fontSize: 22, fontWeight: FontWeight.bold, height: 1.4), textAlign: TextAlign.center),
              ),
            Row(children: [
              _btn('清空', Icons.delete_outline, _clear),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _localPts.length >= 3 ? _showArea : null,
                  icon: const Icon(Icons.crop_square),
                  label: Text('测面积 (${_worldPts.length} 点)'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _detecting ? _stopDetection : _startDetection,
                icon: Icon(_detecting ? Icons.stop_circle : Icons.radar),
                label: Text(_detecting ? '停止检测' : '开始钉螺检测'),
                style: ElevatedButton.styleFrom(backgroundColor: _detecting ? Colors.red : Colors.orange, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap, icon: Icon(icon), label: Text(label),
      style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800], foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16)),
    );
  }

  // ============================================================
  //  AR 回调
  // ============================================================

  void _onARKitViewCreated(ARKitController controller) {
    arkitController = controller;

    arkitController.onARTap = (ar) {
      // ✅ 改进5: tracking 不好就不打点
      if (!_trackingOK) return;

      // ✅ 改进1: 平面优先（原来是只取 featurePoint）
      final point = ar.firstWhereOrNull(
            (o) => o.type == ARKitHitTestResultType.existingPlaneUsingExtent,
          ) ??
          ar.firstWhereOrNull(
            (o) => o.type == ARKitHitTestResultType.existingPlane,
          ) ??
          ar.firstWhereOrNull(
            (o) => o.type == ARKitHitTestResultType.estimatedHorizontalPlane,
          ) ??
          ar.firstWhereOrNull(
            (o) => o.type == ARKitHitTestResultType.featurePoint,
          );

      if (point == null) return;

      final pos = vector.Vector3(
        point.worldTransform.getColumn(3).x,
        point.worldTransform.getColumn(3).y,
        point.worldTransform.getColumn(3).z,
      );

      // ✅ 改进2: 防抖——300ms 内且距离 < 3cm 的重复点击合并
      final now = DateTime.now();
      if (_lastTapTime != null &&
          _lastTapPos != null &&
          now.difference(_lastTapTime!).inMilliseconds < 300 &&
          pos.distanceTo(_lastTapPos!) < 0.03) {
        return; // 忽略重复点击
      }
      _lastTapTime = now;
      _lastTapPos = pos;

      _commitPoint(pos);
    };

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _startDetection();
    });
  }

  // ============================================================
  //  提交测量点
  // ============================================================

  void _commitPoint(vector.Vector3 worldPos) {
    // ✅ 改进3: 第一个点作为局部原点
    _origin ??= worldPos;
    final localPos = worldPos - _origin!;

    setState(() {
      _addDot(worldPos);
      if (_worldPts.isNotEmpty) {
        _addLine(_worldPts.last, worldPos);
      }
      _worldPts.add(worldPos);
      _localPts.add(localPos);
      _updateReadout();
    });

    // ✅ 改进6: 两点之间自动补点（异步）
    if (_worldPts.length >= 2) {
      _interpolate(_worldPts[_worldPts.length - 2], worldPos, _worldPts.length - 2);
    }
  }

  // ============================================================
  //  ✅ 改进6: native 内部投影+插值+hitTest
  // ============================================================

  Future<void> _interpolate(vector.Vector3 a, vector.Vector3 b, int insertIdx) async {
    List<dynamic>? pts;
    try {
      pts = await _ch.invokeMethod('interpolateWorld', {
        'ax': a.x, 'ay': a.y, 'az': a.z,
        'bx': b.x, 'by': b.y, 'bz': b.z,
        'steps': 4, // 中间插 3 个点
      });
    } catch (_) { return; }
    if (pts == null || pts.isEmpty) return;

    final newWorld = <vector.Vector3>[];
    final newLocal = <vector.Vector3>[];
    for (final p in pts) {
      final m = Map<String, dynamic>.from(p);
      final w = vector.Vector3(
        (m['x'] as num).toDouble(),
        (m['y'] as num).toDouble(),
        (m['z'] as num).toDouble(),
      );
      newWorld.add(w);
      newLocal.add(w - _origin!);
    }
    if (newWorld.isEmpty) return;

    setState(() {
      _worldPts.insertAll(insertIdx + 1, newWorld);
      _localPts.insertAll(insertIdx + 1, newLocal);
      _rebuildLines();
      _updateReadout();
    });
  }

  void _rebuildLines() {
    // 只删线节点，保留点节点
    final lineNodes = _nodes.where((n) => n.geometry is ARKitLine).toList();
    for (final n in lineNodes) {
      arkitController.remove(n.name);
      _nodes.remove(n);
    }
    for (int i = 1; i < _worldPts.length; i++) {
      _addLine(_worldPts[i - 1], _worldPts[i]);
    }
  }

  // ============================================================
  //  3D 对象
  // ============================================================

  void _addDot(vector.Vector3 pos) {
    final mat = ARKitMaterial(
      lightingModelName: ARKitLightingModel.constant,
      diffuse: ARKitMaterialProperty.color(Colors.yellow),
    );
    final node = ARKitNode(geometry: ARKitSphere(radius: 0.008, materials: [mat]), position: pos);
    arkitController.add(node);
    _nodes.add(node);
  }

  void _addLine(vector.Vector3 from, vector.Vector3 to) {
    final node = ARKitNode(geometry: ARKitLine(fromVector: from, toVector: to));
    arkitController.add(node);
    _nodes.add(node);
  }

  // ============================================================
  //  测量
  // ============================================================

  void _updateReadout() {
    if (_localPts.length < 2) {
      _result = '';
      _info = '已标记 ${_worldPts.length} 个点，继续点击';
      return;
    }
    final dist = _localPts.last.distanceTo(_localPts[_localPts.length - 2]);
    _result = '📏 ${_fmtLen(dist)}';
    _info = '已标记 ${_worldPts.length} 个点 ｜ 点击继续';
  }

  void _showArea() {
    if (_localPts.length < 3) return;
    setState(() {
      _addLine(_worldPts.last, _worldPts.first);
      double perimeter = 0;
      for (int i = 1; i < _localPts.length; i++) {
        perimeter += _localPts[i].distanceTo(_localPts[i - 1]);
      }
      perimeter += _localPts.last.distanceTo(_localPts.first);

      // ✅ 改进4: 3D 三角剖分
      final area = _area3D(_localPts);
      _result = '📏 周长：${_fmtLen(perimeter)}\n📐 面积：${_fmtArea(area)}';
      _info = '测量完成！点「清空」重新开始';
    });
  }

  // ✅ 改进4
  double _area3D(List<vector.Vector3> pts) {
    if (pts.length < 3) return 0;
    double total = 0;
    for (int i = 1; i < pts.length - 1; i++) {
      final a = pts[i] - pts[0];
      final b = pts[i + 1] - pts[0];
      total += a.cross(b).length / 2.0;
    }
    return total;
  }

  void _clear() {
    setState(() {
      for (final n in _nodes) { arkitController.remove(n.name); }
      _nodes.clear();
      _worldPts.clear();
      _localPts.clear();
      _origin = null;
      _lastTapTime = null;
      _lastTapPos = null;
      _result = '';
      _info = '将手机对准地面，缓慢移动后点击屏幕打点';
    });
  }

  // ============================================================
  //  工具
  // ============================================================

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

class Detection {
  final double x, y, w, h, confidence;
  final String label;
  const Detection({required this.x, required this.y, required this.w, required this.h, required this.confidence, required this.label});
}

class DetectionPainter extends CustomPainter {
  final List<Detection> detections;
  DetectionPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()..color = Colors.red..style = PaintingStyle.stroke..strokeWidth = 3;
    final fillPaint = Paint()..color = Colors.red.withOpacity(0.15)..style = PaintingStyle.fill;
    for (final d in detections) {
      final rect = Rect.fromLTWH(d.x * size.width, d.y * size.height, d.w * size.width, d.h * size.height);
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, boxPaint);
      final tp = TextPainter(
        text: TextSpan(text: '🐌 ${(d.confidence * 100).toStringAsFixed(0)}%',
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, backgroundColor: Colors.red)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left, rect.top - tp.height - 2));
    }
  }

  @override
  bool shouldRepaint(covariant DetectionPainter old) => true;
}