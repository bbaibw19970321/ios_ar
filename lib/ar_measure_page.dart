import 'dart:async';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:collection/collection.dart';

// ✅ 新增：测量模式
enum MeasureMode { fullFrame, manual }

class ARMeasurePage extends StatefulWidget {
  const ARMeasurePage({super.key});
  @override
  State<ARMeasurePage> createState() => _ARMeasurePageState();
}

class _ARMeasurePageState extends State<ARMeasurePage> {
  late ARKitController arkitController;

  // ---- 手动选点 ----
  final List<vector.Vector3> _pts = [];
  final List<ARKitNode> _nodes = [];
  vector.Vector3? _lastPosition;

  String _info = '将手机对准地面/桌面，缓慢移动后点击屏幕打点';
  String _result = '';

  // ---- 检测 ----
  static const _methodChannel = MethodChannel('yolo_detect');
  static const _eventChannel = EventChannel('yolo_detect/events');
  StreamSubscription? _detectSub;
  List<Detection> _detections = [];
  bool _detecting = false;
  int _snailCount = 0;
  double _conf = 0.5;

  // ---- ✅ 新增：模式 & 整图面积 ----
  MeasureMode _mode = MeasureMode.fullFrame;
  double? _fullFrameArea;
  bool _measuring = false;
  Timer? _liveTimer;
  bool _liveMode = false;

  @override
  void dispose() {
    _liveTimer?.cancel();
    _stopDetection();
    arkitController.dispose();
    super.dispose();
  }

  // ============================================================
  //  YOLO 检测控制（不变）
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
      debugPrint('❌ 启动失败: ${e.code} - ${e.message}');
      if (mounted) {
        setState(() => _info = '❌ 启动失败: ${e.message}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检测启动失败: ${e.message}')),
        );
      }
    } catch (e) {
      debugPrint('❌ 启动失败: $e');
      if (mounted) setState(() => _info = '❌ 启动失败: $e');
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
        _info = '检测已停止';
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
      }).where((d) => d.confidence > _conf).toList();

      setState(() {
        _detections = list;
        _snailCount = list.length;
      });
    } catch (e) {
      debugPrint('⚠️ 解析检测结果出错: $e');
    }
  }

  // ============================================================
  //  ✅ 新增：整图面积测量
  // ============================================================

  Future<void> _measureFullFrame() async {
    if (_measuring) return;
    setState(() => _measuring = true);
    try {
      final raw = await _methodChannel.invokeMethod('hitTestCorners');
      final corners = (raw as List)
          .map((e) => vector.Vector3(
                (e[0] as num).toDouble(),
                (e[1] as num).toDouble(),
                (e[2] as num).toDouble(),
              ))
          .toList();
      final area = _shoelace3D(corners);
      if (mounted) {
        setState(() {
          _fullFrameArea = area;
          _result = '📐 整图面积：${_fmtArea(area)}';
          _info = _snailCount > 0
              ? '🐌 密度：${_snailCount / area.toStringAsFixed(2)} 只/m²'
              : '测量完成，移动手机可重新测量';
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _info = '⚠️ ${e.message ?? "测量失败，请对准平面"}');
      }
    } catch (e) {
      if (mounted) setState(() => _info = '⚠️ 测量失败: $e');
    } finally {
      if (mounted) setState(() => _measuring = false);
    }
  }

  /// 3D 多边形面积（鞋带公式 + 叉积）
  double _shoelace3D(List<vector.Vector3> pts) {
    if (pts.length < 3) return 0;
    var cross = vector.Vector3.zero();
    for (int i = 0; i < pts.length; i++) {
      final j = (i + 1) % pts.length;
      cross += pts[i].cross(pts[j]);
    }
    return cross.length / 2.0;
  }

  void _toggleLive() {
    if (_liveMode) {
      _liveTimer?.cancel();
      _liveTimer = null;
      setState(() => _liveMode = false);
    } else {
      setState(() => _liveMode = true);
      _measureFullFrame();
      _liveTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
        _measureFullFrame();
      });
    }
  }

  // ============================================================
  //  ✅ 新增：模式切换
  // ============================================================

  void _switchMode(MeasureMode m) {
    if (_mode == m) return;
    _liveTimer?.cancel();
    _liveTimer = null;
    setState(() {
      _mode = m;
      _liveMode = false;
      _result = '';
      _fullFrameArea = null;
      if (m == MeasureMode.fullFrame) {
        _info = '将手机对准地面/桌面，点击「测量整图面积」';
      } else {
        _info = '将手机对准地面/桌面，缓慢移动后点击屏幕打点';
      }
    });
  }

  // ============================================================
  //  UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      body: Stack(children: [
        ARKitSceneView(
          enableTapRecognizer: true,
          onARKitViewCreated: _onARKitViewCreated,
        ),

        // 检测框（两种模式都显示）
        if (_detecting)
          Positioned.fill(
            child: CustomPaint(
              painter: DetectionPainter(detections: _detections),
            ),
          ),

        // 顶部信息栏
        Positioned(
          top: topPad + 12,
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

        // ✅ 模式切换（顶部第二行）
        Positioned(
          top: topPad + 62,
          left: 16,
          right: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _modeChip('📐 整图面积', MeasureMode.fullFrame),
              const SizedBox(width: 8),
              _modeChip('✏️ 手动选点', MeasureMode.manual),
            ],
          ),
        ),

        // 钉螺计数（两种模式都显示）
        if (_detecting && _snailCount > 0)
          Positioned(
            top: topPad + 110,
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

        // 手动模式：中心十字准星
        if (_mode == MeasureMode.manual)
          Center(
            child: Icon(Icons.add,
                color: Colors.white.withOpacity(0.6), size: 36),
          ),

        // 底部控制区
        Positioned(
          left: 16,
          right: 16,
          bottom: botPad + 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // 置信度滑块
            if (_detecting)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Text('置信度',
                        style: TextStyle(color: Colors.white, fontSize: 13)),
                    Expanded(
                      child: Slider(
                        value: _conf,
                        min: 0.05,
                        max: 0.95,
                        divisions: 18,
                        activeColor: Colors.greenAccent,
                        label: _conf.toStringAsFixed(2),
                        onChanged: (v) {
                          setState(() => _conf = v);
                          _methodChannel.invokeMethod('setConf', v);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 34,
                      child: Text(
                        _conf.toStringAsFixed(2),
                        style: const TextStyle(
                            color: Colors.greenAccent, fontSize: 13),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),

            // 结果展示
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

            // ✅ 整图模式按钮
            if (_mode == MeasureMode.fullFrame) ...[
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _measuring ? null : _measureFullFrame,
                    icon: _measuring
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.crop_free),
                    label: Text(_measuring ? '测量中...' : '测量整图面积'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _btn(_liveMode ? '停止实时' : '实时测量',
                    _liveMode ? Icons.pause_circle : Icons.play_circle,
                    _toggleLive),
              ]),
            ],

            // ✅ 手动模式按钮
            if (_mode == MeasureMode.manual) ...[
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
            ],

            const SizedBox(height: 10),

            // 检测开关（两种模式共用）
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

  // ✅ 模式切换 chip
  Widget _modeChip(String label, MeasureMode m) {
    final selected = _mode == m;
    return GestureDetector(
      onTap: () => _switchMode(m),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.greenAccent : Colors.black54,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected ? Colors.greenAccent : Colors.white38),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ),
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
      // ✅ 只有手动模式才响应打点
      if (_mode != MeasureMode.manual) return;
      final point = ar.firstWhereOrNull(
        (o) => o.type == ARKitHitTestResultType.featurePoint,
      );
      if (point != null) {
        _onTapPoint(point);
      }
    };

    Future.delayed(const Duration(seconds: 2), () {
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
  //  手动测量逻辑（不变）
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

      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, boxPaint);

      final label = '钉螺 ${(d.confidence * 100).toStringAsFixed(0)}%';
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