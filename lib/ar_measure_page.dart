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

  final List<vector.Vector3> _pts = [];
  final List<ARKitNode> _nodes = [];
  vector.Vector3? _lastPosition;
  String _info = '将手机对准地面/桌面，缓慢移动后点击屏幕打点';
  String _result = '';

  static const _methodChannel = MethodChannel('yolo_detect');
  static const _eventChannel = EventChannel('yolo_detect/events');
  StreamSubscription? _detectSub;
  List<Detection> _detections = [];
  bool _detecting = false;
  int _snailCount = 0;

  final Map<String, _Track> _tracks = {};
  int _nextId = 0;
  static const int _confirmHits = 1;
  static const int _maxMisses = 4;
  static const double _iouThresh = 0.15;

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
        _tracks.clear();
        _nextId = 0;
        _info = '检测已停止';
      });
    }
  }

  void _onDetections(dynamic data) {
    if (!mounted || data == null) return;
    try {
      final current = (data as List).map((e) {
        final m = Map<String, dynamic>.from(e);
        return Detection(
          x: (m['x'] as num).toDouble(),
          y: (m['y'] as num).toDouble(),
          w: (m['w'] as num).toDouble(),
          h: (m['h'] as num).toDouble(),
          confidence: (m['conf'] as num).toDouble(),
          label: m['label'] as String? ?? 'snail',
        );
      }).where((d) => d.confidence > 0.15).toList();

      for (final t in _tracks.values) t.matched = false;

      final usedTracks = <String>{};
      for (final det in current) {
        String? bestId;
        double bestIou = _iouThresh;
        for (final entry in _tracks.entries) {
          if (usedTracks.contains(entry.key)) continue;
          final iou = _computeIoU(det, entry.value.smoothBox);
          if (iou > bestIou) {
            bestIou = iou;
            bestId = entry.key;
          }
        }
        if (bestId != null) {
          _tracks[bestId]!.update(det);
          usedTracks.add(bestId);
        } else {
          _tracks['t${_nextId++}'] = _Track(det);
        }
      }

      for (final t in _tracks.values) {
        if (!t.matched) t.miss();
      }

      _tracks.removeWhere((_, t) => t.dead);

      final stable = _tracks.values
          .where((t) => t.confirmed)
          .map((t) => t.smoothBox)
          .toList();

      setState(() {
        _detections = stable;
        _snailCount = stable.length;
      });
    } catch (e) {
      debugPrint('⚠️ 跟踪异常: $e');
    }
  }

  double _computeIoU(Detection a, Detection b) {
    final ax2 = a.x + a.w, ay2 = a.y + a.h;
    final bx2 = b.x + b.w, by2 = b.y + b.h;
    final ix1 = a.x > b.x ? a.x : b.x;
    final iy1 = a.y > b.y ? a.y : b.y;
    final ix2 = ax2 < bx2 ? ax2 : bx2;
    final iy2 = ay2 < by2 ? ay2 : by2;
    final iw = ix2 - ix1, ih = iy2 - iy1;
    if (iw <= 0 || ih <= 0) return 0.0;
    final inter = iw * ih;
    final union = a.w * a.h + b.w * b.h - inter;
    return union > 0 ? inter / union : 0.0;
  }

  // ============================================================
  //  UI（完全不变）
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        ARKitSceneView(
          enableTapRecognizer: true,
          onARKitViewCreated: _onARKitViewCreated,
        ),
        if (_detecting)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: DetectionPainter(detections: _detections),
              ),
            ),
          ),
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 16, right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(_info,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              textAlign: TextAlign.center),
          ),
        ),
        if (_detecting && _snailCount > 0)
          Positioned(
            top: MediaQuery.of(context).padding.top + 70, right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.85),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.bug_report, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text('🐌 ×$_snailCount',
                  style: const TextStyle(
                    color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
        Center(
          child: Icon(Icons.add, color: Colors.white.withOpacity(0.6), size: 36)),
        Positioned(
          left: 16, right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_result.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(12)),
                child: Text(_result,
                  style: const TextStyle(
                    color: Colors.greenAccent, fontSize: 24,
                    fontWeight: FontWeight.bold, height: 1.4),
                  textAlign: TextAlign.center),
              ),
            Row(children: [
              _btn('清空', Icons.delete_outline, _clear),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton.icon(
                onPressed: _pts.length >= 3 ? _showArea : null,
                icon: const Icon(Icons.crop_square),
                label: Text('测面积 (${_pts.length} 点)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue, foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              )),
            ]),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _detecting ? _stopDetection : _startDetection,
                icon: Icon(_detecting ? Icons.stop_circle : Icons.radar),
                label: Text(_detecting ? '停止检测' : '开始钉螺检测'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _detecting ? Colors.red : Colors.orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              )),
          ]),
        ),
      ]),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap, icon: Icon(icon), label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.grey[800], foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16)),
    );
  }

  // ============================================================
  //  AR 回调（完全不变）
  // ============================================================

  void _onARKitViewCreated(ARKitController controller) {
    arkitController = controller;
    arkitController.onARTap = (ar) {
      final point = ar.firstWhereOrNull(
        (o) => o.type == ARKitHitTestResultType.featurePoint);
      if (point != null) _onTapPoint(point);
    };
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _startDetection();
    });
  }

  void _onTapPoint(ARKitTestResult hitResult) {
    final position = vector.Vector3(
      hitResult.worldTransform.getColumn(3).x,
      hitResult.worldTransform.getColumn(3).y,
      hitResult.worldTransform.getColumn(3).z);
    setState(() {
      _addDot(position);
      if (_lastPosition != null) _addLine(_lastPosition!, position);
      _pts.add(position);
      _lastPosition = position;
      _updateReadout();
    });
  }

  void _addDot(vector.Vector3 pos) {
    final material = ARKitMaterial(
      lightingModelName: ARKitLightingModel.constant,
      diffuse: ARKitMaterialProperty.color(Colors.yellow));
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
      for (int i = 1; i < _pts.length; i++)
        perimeter += _pts[i].distanceTo(_pts[i - 1]);
      perimeter += _pts.last.distanceTo(_pts.first);
      final area = _shoelaceXZ(_pts);
      _result = '📏 周长：${_fmtLen(perimeter)}\n📐 面积：${_fmtArea(area)}';
      _info = '测量完成！点「清空」重新开始';
    });
  }

  void _clear() {
    setState(() {
      for (final node in _nodes) arkitController.remove(node.name);
      _nodes.clear(); _pts.clear(); _lastPosition = null;
      _result = '';
      _info = '将手机对准地面/桌面，缓慢移动后点击屏幕打点';
    });
  }

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

  String _fmtLen(double m) =>
      m < 1 ? '${(m * 100).toStringAsFixed(1)} cm' : '${m.toStringAsFixed(2)} m';

  String _fmtArea(double sq) =>
      sq < 1 ? '${(sq * 10000).toStringAsFixed(1)} cm²' : '${sq.toStringAsFixed(2)} m²';
}

// ============================================================
//  检测数据模型（不变）
// ============================================================

class Detection {
  final double x, y, w, h, confidence;
  final String label;
  const Detection({
    required this.x, required this.y,
    required this.w, required this.h,
    required this.confidence, required this.label,
  });
}

// ============================================================
//  ✅ 自适应卡尔曼跟踪器（替代EMA）
// ============================================================

class _Track {
  Detection box;
  Detection smoothBox;
  int hits = 0;
  int misses = 0;
  bool matched = false;

  // 卡尔曼状态: [x, y, vx, vy]
  double _kx, _ky, _kvx, _kvy;
  // 协方差对角线（简化为4个独立维度）
  double _px, _py, _pvx, _pvy;

  // 过程噪声（加速度不确定性）
  static const double _qPos = 0.0005;  // 位置过程噪声
  static const double _qVel = 0.002;   // 速度过程噪声
  // 观测噪声基准
  static const double _rBase = 0.001;

  _Track(Detection det)
      : box = det,
        smoothBox = det,
        _kx = det.x,
        _ky = det.y,
        _kvx = 0,
        _kvy = 0,
        _px = 0.01,
        _py = 0.01,
        _pvx = 0.01,
        _pvy = 0.01;

  void update(Detection det) {
    matched = true;
    misses = 0;
    hits++;
    box = det;

    // --- 卡尔曼预测步 ---
    // 状态转移: x' = x + vx, y' = y + vy, vx'=vx, vy'=vy
    final predX = _kx + _kvx;
    final predY = _ky + _kvy;
    // 协方差预测: P' = P + Q
    final pPredX = _px + _qPos;
    final pPredY = _py + _qPos;
    final pPredVx = _pvx + _qVel;
    final pPredVy = _pvy + _qVel;

    // --- 卡尔曼更新步 ---
    // 观测残差
    final dx = det.x - predX;
    final dy = det.y - predY;

    // ✅ 自适应观测噪声：位移越大说明运动越剧烈，R越小→更信任观测
    final displacement = dx * dx + dy * dy;
    final rAdaptive = _rBase / (1.0 + displacement * 500.0);

    // 卡尔曼增益 K = P_pred / (P_pred + R)
    final kGainX = pPredX / (pPredX + rAdaptive);
    final kGainY = pPredY / (pPredY + rAdaptive);
    final kGainVx = pPredVx / (pPredVx + rAdaptive);
    final kGainVy = pPredVy / (pPredVy + rAdaptive);

    // 状态更新
    _kx = predX + kGainX * dx;
    _ky = predY + kGainY * dy;
    _kvx = _kvx + kGainVx * dx; // 速度修正
    _kvy = _kvy + kGainVy * dy;

    // 协方差更新: P = (1-K)*P_pred
    _px = (1.0 - kGainX) * pPredX;
    _py = (1.0 - kGainY) * pPredY;
    _pvx = (1.0 - kGainVx) * pPredVx;
    _pvy = (1.0 - kGainVy) * pPredVy;

    // ✅ 宽高用简单EMA（变化不大，不需要卡尔曼）
    final sw = 0.7 * det.w + 0.3 * smoothBox.w;
    final sh = 0.7 * det.h + 0.3 * smoothBox.h;

    smoothBox = Detection(
      x: _kx, y: _ky, w: sw, h: sh,
      confidence: det.confidence,
      label: det.label,
    );
  }

  void miss() {
    matched = false;
    misses++;
    // ✅ 纯预测外推（无观测更新）
    _kx += _kvx;
    _ky += _kvy;
    // 协方差增长（不确定性增加）
    _px += _qPos;
    _py += _qPos;

    smoothBox = Detection(
      x: _kx, y: _ky,
      w: smoothBox.w, h: smoothBox.h,
      confidence: box.confidence,
      label: smoothBox.label,
    );
  }

  bool get confirmed =>
      hits >= _ARMeasurePageState._confirmHits &&
      misses <= _ARMeasurePageState._maxMisses;

  bool get dead => misses > _ARMeasurePageState._maxMisses;
}

// ============================================================
//  检测框绘制（不变）
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
        d.x * size.width, d.y * size.height,
        d.w * size.width, d.h * size.height);
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, boxPaint);

      final label = '🐌 ${(d.confidence * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(text: label, style: const TextStyle(
          color: Colors.white, fontSize: 13,
          fontWeight: FontWeight.bold, backgroundColor: Colors.red)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left, rect.top - tp.height - 2));
    }
  }

  @override
  bool shouldRepaint(covariant DetectionPainter old) => true;
}