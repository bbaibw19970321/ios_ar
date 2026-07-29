import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/material.dart';
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
  vector.Vector3? _lastPosition;
  String _info = '将手机对准地面/桌面，缓慢移动后点击屏幕打点';
  String _result = '';
  int _nodeCount = 0;

  @override
  void dispose() {
    arkitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        // ===== AR 视图（完全按官方示例写法）=====
        ARKitSceneView(
          enableTapRecognizer: true,
          onARKitViewCreated: _onARKitViewCreated,
        ),

        // ===== 顶部提示 =====
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

        // ===== 中心准星 =====
        Center(
          child: Icon(
            Icons.add,
            color: Colors.white.withOpacity(0.6),
            size: 36,
          ),
        ),

        // ===== 底部面板 =====
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // 结果卡片
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
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            // 按钮行
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
  //  AR 回调（完全照搬官方示例）
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
  }

  void _onTapPoint(ARKitTestResult hitResult) {
    // 从 4x4 矩阵第 4 列取世界坐标
    final position = vector.Vector3(
      hitResult.worldTransform.getColumn(3).x,
      hitResult.worldTransform.getColumn(3).y,
      hitResult.worldTransform.getColumn(3).z,
    );

    setState(() {
      // 1) 放小球
      _addDot(position);

      // 2) 如果有上一个点 → 画线 + 标注距离
      if (_lastPosition != null) {
        _addLine(_lastPosition!, position);
        _addDistanceLabel(_lastPosition!, position);
      }

      // 3) 记录
      _pts.add(position);
      _lastPosition = position;

      // 4) 更新底部读数
      _updateReadout();
    });
  }

  // ============================================================
  //  3D 对象添加（完全用官方 API）
  // ============================================================

  void _addDot(vector.Vector3 pos) {
    final material = ARKitMaterial(
      lightingModelName: ARKitLightingModel.constant,
      diffuse: ARKitMaterialProperty.color(Colors.yellow),
    );
    final sphere = ARKitSphere(
      radius: 0.008,
      materials: [material],
    );
    final node = ARKitNode(
      geometry: sphere,
      position: pos,
    );
    arkitController.add(node);
    _nodeCount++;
  }

  void _addLine(vector.Vector3 from, vector.Vector3 to) {
    final line = ARKitLine(
      fromVector: from,
      toVector: to,
    );
    final node = ARKitNode(geometry: line);
    arkitController.add(node);
    _nodeCount++;
  }

  /// 在两点中间放一个 3D 文字标注距离
  void _addDistanceLabel(vector.Vector3 a, vector.Vector3 b) {
    final dist = a.distanceTo(b);
    final label = dist < 1
        ? '${(dist * 100).toStringAsFixed(1)} cm'
        : '${dist.toStringAsFixed(2)} m';

    final mid = vector.Vector3(
      (a.x + b.x) / 2,
      (a.y + b.y) / 2 + 0.02, // 稍微抬高一点
      (a.z + b.z) / 2,
    );

    final textGeometry = ARKitText(
      text: label,
      extrusionDepth: 1,
      materials: [
        ARKitMaterial(
          diffuse: ARKitMaterialProperty.color(Colors.red),
        ),
      ],
    );
    const scale = 0.001;
    final node = ARKitNode(
      geometry: textGeometry,
      position: mid,
      scale: vector.Vector3(scale, scale, scale),
    );
    arkitController.add(node);
    _nodeCount++;
  }

  // ============================================================
  //  读数 / 面积
  // ============================================================

  void _updateReadout() {
    if (_pts.length < 2) {
      _result = '';
      _info = '已标记 ${_pts.length} 个点，继续点击屏幕';
      return;
    }
    double total = 0;
    for (int i = 1; i < _pts.length; i++) {
      total += _pts[i].distanceTo(_pts[i - 1]);
    }
    final buf = StringBuffer();
    buf.writeln('📏 总距离：${_fmtLen(total)}');
    if (_pts.length >= 3) {
      buf.writeln('📐 面积：${_fmtArea(_shoelaceXZ(_pts))}');
    }
    _result = buf.toString().trim();
    _info = '已标记 ${_pts.length} 个点 ｜ 点击继续，或点「测面积」';
  }

  void _showArea() {
    if (_pts.length < 3) return;
    setState(() {
      // 画闭合线
      _addLine(_pts.last, _pts.first);

      // 闭合段距离标注
      _addDistanceLabel(_pts.last, _pts.first);

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

  /// 清空：重新进入页面（最可靠的方式）
  void _clear() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ARMeasurePage()),
    );
  }

  // ============================================================
  //  数学
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