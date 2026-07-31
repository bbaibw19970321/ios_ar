import 'dart:async';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

class ARMeasurePage extends StatefulWidget {
  const ARMeasurePage({super.key});
  @override
  State<ARMeasurePage> createState() => _ARMeasurePageState();
}

class _ARMeasurePageState extends State<ARMeasurePage> {
  late ARKitController arkitController;

  // ✅ 改进3: 世界坐标（用于显示）+ 局部坐标（用于计算）
  final List<vector.Vector3> _worldPts = [];
  final List<vector.Vector3> _localPts = [];
  final List<Offset> _screenPts = []; // ✅ 改进6: 记录屏幕坐标用于补点

  final List<ARKitNode> _dotNodes = [];
  final List<ARKitNode> _lineNodes = [];

  String _info = '将手机对准地面，缓慢移动后点击屏幕打点';
  String _result = '';

  // ✅ 改进5: tracking 状态
  bool _trackingOK = true;
  String _trackingHint = '';

  // YOLO 检测
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
  //  YOLO 检测（不变）
  // ============================================================

  Future<void> _startDetection() async {
    if (_detecting) return;
    try {
      await _methodChannel.invokeMethod('start');
      _detectSub = _eventChannel.receiveBroadcastStream().listen(
        _onDetections,
        onError: (e) => debugPrint('❌ 事件流错误: $e'),
      );
      setState(() {
        _detecting = true;
        _info = '🔍 钉螺检测已启动，对准目标...';
      });
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _info = '❌ 启动失败: ${e.message}');
      }
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
    try {
      final list = (data as List).map((e) {
        final m = Map<String, dynamic>.from(e);
        return Detection(
          x: (m['x'] as num).toDouble(),
          y: (m['y'] as num).toDouble(),
          w: (m['w'] as num).toDouble(),
          h: (m['h'] as num).toDouble(),
          confidence: (m['conf'] as num).toDouble(),
          label: m['label'] as String? ?? 'snail',
        );
      }).where((d) => d.confidence > 0.8).toList();

      setState(() {
        _detections = list;
        _snailCount = list.length;
      });
    } catch (e) {
      debugPrint('⚠️ 解析检测结果出错: $e');
    }
  }

  // ============================================================
  //  ✅ 改进5: 点击前检查 tracking 状态
  // ============================================================

  Future<void> _onTapDown(TapDownDetails details) async {
    final sx = details.localPosition.dx;
    final sy = details.localPosition.dy;

    // 先查 tracking 状态
    String state;
    try {
      state = await _methodChannel.invokeMethod('getTrackingState') ?? 'unknown';
    } catch (_) {
      state = 'unknown';
    }

    if (state != 'normal') {
      setState(() {
        _trackingOK = false;
        _trackingHint = _trackingHintText(state);
        _info = '⚠️ $_trackingHint';
      });
      // 1.5秒后恢复提示
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _trackingOK = true);
      });
      return;
    }

    setState(() => _trackingOK = true);

    // ✅ 改进1+2: 调用 native 稳定 hitTest（平面优先 + 中位数）
    Map<dynamic, dynamic>? hit;
    try {
      hit = await _methodChannel.invokeMethod('hitTestStable', {'x': sx, 'y': sy});
    } catch (e) {
      debugPrint('hitTest 失败: $e');
      return;
    }
    if (hit == null) {
      setState(() => _info = '未检测到地面，请对准平坦区域');
      return;
    }

    final worldPos = vector.Vector3(
      (hit['wx'] as num).toDouble(),
      (hit['wy'] as num).toDouble(),
      (hit['wz'] as num).toDouble(),
    );
    final localPos = vector.Vector3(
      (hit['lx'] as num).toDouble(),
      (hit['ly'] as num).toDouble(),
      (hit['lz'] as num).toDouble(),
    );

    _commitPoint(worldPos, localPos, Offset(sx, sy));
  }

  String _trackingHintText(String state) {
    if (state.contains('motion')) return '移动过快，请放慢速度';
    if (state.contains('features')) return '特征不足，请对准有纹理的地面';
    if (state.contains('initializing')) return '正在初始化，请稍候...';
    if (state.contains('relocalizing')) return '正在重新定位...';
    return '追踪不稳定，请缓慢移动手机';
  }

  // ============================================================
  //  提交一个测量点
  // ============================================================

  void _commitPoint(vector.Vector3 worldPos, vector.Vector3 localPos, Offset screenPos) {
    setState(() {
      // 画点
      _addDot(worldPos);
      _worldPts.add(worldPos);
      _localPts.add(localPos);
      _screenPts.add(screenPos);

      // 画线（连到上一个点）
      if (_worldPts.length >= 2) {
        _addLine(_worldPts[_worldPts.length - 2], worldPos);
      }

      _updateReadout();
    });

    // ✅ 改进6: 两点之间自动补点（异步，不阻塞 UI）
    if (_screenPts.length >= 2) {
      _interpolateBetween(
        _screenPts[_screenPts.length - 2],
        screenPos,
        _worldPts.length - 2, // 插入位置索引
      );
    }
  }

  // ============================================================
  //  ✅ 改进6: 自动补点
  // ============================================================

  Future<void> _interpolateBetween(Offset a, Offset b, int insertIndex) async {
    List<dynamic>? pts;
    try {
      pts = await _methodChannel.invokeMethod('hitTestAlongLine', {
        'x1': a.dx, 'y1': a.dy,
        'x2': b.dx, 'y2': b.dy,
        'steps': 4, // 中间插 3 个点
      });
    } catch (_) {
      return;
    }
    if (pts == null || pts.isEmpty) return;

    final newWorld = <vector.Vector3>[];
    final newLocal = <vector.Vector3>[];
    for (final p in pts) {
      final m = Map<String, dynamic>.from(p);
      newWorld.add(vector.Vector3(
        (m['wx'] as num).toDouble(),
        (m['wy'] as num).toDouble(),
        (m['wz'] as num).toDouble(),
      ));
      newLocal.add(vector.Vector3(
        (m['lx'] as num).toDouble(),
        (m['ly'] as num).toDouble(),
        (m['lz'] as num).toDouble(),
      ));
    }

    if (newWorld.isEmpty) return;

    setState(() {
      // 插入到 insertIndex+1 位置（在 A 和 B 之间）
      _worldPts.insertAll(insertIndex + 1, newWorld);
      _localPts.insertAll(insertIndex + 1, newLocal);
      // 屏幕坐标插占位（补点没有精确屏幕坐标，用插值）
      for (int i = 0; i < newWorld.length; i++) {
        final t = (i + 1) / (newWorld.length + 1);
        _screenPts.insert(
          insertIndex + 1 + i,
          Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t),
        );
      }
      // 重画所有线
      _rebuildLines();
      _updateReadout();
    });
  }

  void _rebuildLines() {
    // 删除旧线
    for (final node in _lineNodes) {
      arkitController.remove(node.name);
    }
    _lineNodes.clear();
    // 重画
    for (int i = 1; i < _worldPts.length; i++) {
      _addLine(_worldPts[i - 1], _worldPts[i]);
    }
  }

  // ============================================================
  //  UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        // AR 视图（关闭内置 tap，由 GestureDetector 接管）
        ARKitSceneView(
          enableTapRecognizer: false, // ✅ 改用 GestureDetector
          onARKitViewCreated: _onARKitViewCreated,
        ),

        // ✅ 手势层：接收点击
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: _onTapDown,
          ),
        ),

        // YOLO 检测框
        if (_detecting)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: DetectionPainter(detections: _detections),
              ),
            ),
          ),

        // 顶部信息栏
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _trackingOK ? Colors.black54 : Colors.orange.shade900.withOpacity(0.9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _info,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
        ),

        // 钉螺计数
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

        // 中心十字
        Center(
          child: Icon(Icons.add, color: Colors.white.withOpacity(0.6), size: 36),
        ),

        // 底部按钮
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

            Row(children: [
              _btn('清空', Icons.delete_outline, _clear),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _localPts.length >= 3 ? _showArea : null,
                  icon: const Icon(Icons.crop_square),
                  label: Text('测面积 (${_worldPts.length} 点)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
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
    // 2秒后自动启动 YOLO
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _startDetection();
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
    _dotNodes.add(node);
  }

  void _addLine(vector.Vector3 from, vector.Vector3 to) {
    final line = ARKitLine(fromVector: from, toVector: to);
    final node = ARKitNode(geometry: line);
    arkitController.add(node);
    _lineNodes.add(node);
  }

  // ============================================================
  //  测量逻辑
  // ============================================================

  void _updateReadout() {
    if (_localPts.length < 2) {
      _result = '';
      _info = '已标记 ${_worldPts.length} 个点，继续点击屏幕';
      return;
    }
    // ✅ 改进3: 用局部坐标算距离（抗漂移）
    final dist = _localPts.last.distanceTo(_localPts[_localPts.length - 2]);
    _result = '📏 ${_fmtLen(dist)}';
    _info = '已标记 ${_worldPts.length} 个点 ｜ 点击继续打点';
  }

  void _showArea() {
    if (_localPts.length < 3) return;
    setState(() {
      // 闭合线
      _addLine(_worldPts.last, _worldPts.first);

      // 周长（用局部坐标）
      double perimeter = 0;
      for (int i = 1; i < _localPts.length; i++) {
        perimeter += _localPts[i].distanceTo(_localPts[i - 1]);
      }
      perimeter += _localPts.last.distanceTo(_localPts.first);

      // ✅ 改进4: 3D 三角剖分面积
      final area = _area3D(_localPts);

      _result = '📏 周长：${_fmtLen(perimeter)}\n📐 面积：${_fmtArea(area)}';
      _info = '测量完成！点「清空」重新开始';
    });
  }

  // ✅ 改进4: 3D 扇形三角剖分（平地=XZ鞋带，坡地=真实表面积）
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
      for (final node in _dotNodes) {
        arkitController.remove(node.name);
      }
      for (final node in _lineNodes) {
        arkitController.remove(node.name);
      }
      _dotNodes.clear();
      _lineNodes.clear();
      _worldPts.clear();
      _localPts.clear();
      _screenPts.clear();
      _result = '';
      _info = '将手机对准地面，缓慢移动后点击屏幕打点';
    });
    // ✅ 改进3: 重置 native 锚点
    _methodChannel.invokeMethod('resetAnchor').catchError((_) {});
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
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, boxPaint);

      final label = '🐌 ${(d.confidence * 1).toStringAsFixed(0)}%';
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