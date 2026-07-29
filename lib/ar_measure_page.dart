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
  final List<ARKitNode> _nodes = [];
  vector.Vector3? _lastPosition;
  String _info = '将手机对准地面/桌面，缓慢移动后点击屏幕打点';
  String _result = '';

  @override
  void dispose() {
    arkitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        ARKitSceneView(
          enableTapRecognizer: true,
          onARKitViewCreated: _onARKitViewCreated,
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
  //  添加 3D 对象
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
  //  读数（只显示最新两点距离）
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

  // ============================================================
  //  清空（不重建页面，环境保留）
  // ============================================================

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