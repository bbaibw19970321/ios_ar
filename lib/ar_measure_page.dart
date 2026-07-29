import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as v64;
import 'package:collection/collection.dart';

/// AR 测距 + 测面积 页面（适配 arkit_plugin 1.4.0 官方 API）
class ARMeasurePage extends StatefulWidget {
  const ARMeasurePage({super.key});
  @override
  State<ARMeasurePage> createState() => _ARMeasurePageState();
}

class _ARMeasurePageState extends State<ARMeasurePage> {
  ARKitController? _controller;

  final List<v64.Vector3> _pts = [];
  final List<ARKitNode> _nodes = []; // 存储所有节点引用
  String _info = '将手机对准地面/桌面，缓慢移动以识别平面';
  String _result = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        ARKitSceneView(
          showFeaturePoints: true,
          planeDetection: ARPlaneDetection.horizontalAndVertical,
          autoenablesDefaultLighting: true,
          enableTapRecognizer: true, // ✅ 启用点击识别
          onARKitViewCreated: _onARKitViewCreated,
        ),
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
        Center(
          child: Icon(Icons.add, color: Colors.white.withOpacity(0.7), size: 36),
        ),
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
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            Row(children: [
              _btn('撤销', Icons.undo, _undo),
              const SizedBox(width: 10),
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
  //  核心逻辑
  // ============================================================

  /// ✅ 在 controller 上设置 onARTap 回调（官方写法）
  void _onARKitViewCreated(ARKitController controller) {
    _controller = controller;
    _controller!.onARTap = (List<ARKitTestResult> ar) {
      final planeTap = ar.firstWhereOrNull(
        (tap) => tap.type == ARKitHitTestResultType.existingPlaneUsingExtent,
      );
      if (planeTap != null) {
        _onPlaneTap(planeTap.worldTransform);
      }
    };
  }

  /// 点击平面 → 提取坐标 → 加点/画线
  void _onPlaneTap(v64.Matrix4 transform) {
    final position = v64.Vector3(
      transform.getColumn(3).x,
      transform.getColumn(3).y,
      transform.getColumn(3).z,
    );

    setState(() {
      // 1) 放小球标记
      final dot = _makeDot(position);
      _controller!.add(dot);
      _nodes.add(dot);

      // 2) 画连线
      if (_pts.isNotEmpty) {
        final line = _makeLine(_pts.last, position);
        final lineNode = ARKitNode(geometry: line);
        _controller!.add(lineNode);
        _nodes.add(lineNode);
      }

      // 3) 记录坐标
      _pts.add(position);

      // 4) 刷新
      _updateReadout();
    });
  }

  void _updateReadout() {
    if (_pts.length < 2) {
      _result = '';
      _info = '已标记 ${_pts.length} 个点，继续点击以测量';
      return;
    }
    double total = 0;
    for (int i = 1; i < _pts.length; i++) {
      total += _pts[i].distanceTo(_pts[i - 1]);
    }
    final buf = StringBuffer();
    buf.writeln('📏 距离：${_fmtLen(total)}');
    if (_pts.length >= 3) {
      final area = _shoelaceXZ(_pts);
      buf.writeln('📐 面积：${_fmtArea(area)}');
    }
    _result = buf.toString().trim();
    _info = '已标记 ${_pts.length} 个点 ｜ 点击屏幕继续，或点「测面积」';
  }

  void _showArea() {
    if (_pts.length < 3) return;
    setState(() {
      // 闭合线
      final closeLine = _makeLine(_pts.last, _pts.first);
      final closeNode = ARKitNode(geometry: closeLine);
      _controller!.add(closeNode);
      _nodes.add(closeNode);

      final area = _shoelaceXZ(_pts);
      double total = 0;
      for (int i = 1; i < _pts.length; i++) {
        total += _pts[i].distanceTo(_pts[i - 1]);
      }
      total += _pts.last.distanceTo(_pts.first);
      _result = '📏 周长：${_fmtLen(total)}\n📐 面积：${_fmtArea(area)}';
      _info = '测量完成！点「清空」重新开始';
    });
  }

  void _undo() {
    if (_pts.isEmpty) return;
    setState(() {
      _pts.removeLast();
      // 移除最近的节点（点+线）
      if (_nodes.isNotEmpty) {
        _controller!.remove(_nodes.removeLast().name);
      }
      if (_nodes.isNotEmpty) {
        _controller!.remove(_nodes.removeLast().name);
      }
      _updateReadout();
    });
  }

  void _clear() {
    setState(() {
      for (final n in _nodes) {
        _controller!.remove(n.name);
      }
      _nodes.clear();
      _pts.clear();
      _result = '';
      _info = '将手机对准地面/桌面，缓慢移动以识别平面';
    });
  }

  // ============================================================
  //  3D 对象工厂（官方 API 写法）
  // ============================================================

  /// ✅ ARKitSphere（不是 ARKitSphereGeometry）
  /// ✅ ARKitMaterialProperty.color()（不是 ARKitMaterialProperty(color:)）
  ARKitNode _makeDot(v64.Vector3 pos) {
    final material = ARKitMaterial(
      lightingModelName: ARKitLightingModel.constant,
      diffuse: ARKitMaterialProperty.color(Colors.yellow),
    );
    final sphere = ARKitSphere(
      radius: 0.01,
      materials: [material],
    );
    return ARKitNode(
      geometry: sphere,
      position: pos,
    );
  }

  ARKitLine _makeLine(v64.Vector3 from, v64.Vector3 to) {
    return ARKitLine(
      fromVector: from,
      toVector: to,
    );
  }

  // ============================================================
  //  数学工具
  // ============================================================

  double _shoelaceXZ(List<v64.Vector3> pts) {
    if (pts.length < 3) return 0;
    double s = 0;
    final n = pts.length;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      s += pts[i].x * pts[j].z - pts[j].x * pts[i].z;
    }
    return (s / 2).abs();
  }

  String _fmtLen(double meters) {
    if (meters < 1) return '${(meters * 100).toStringAsFixed(1)} cm';
    return '${meters.toStringAsFixed(2)} m';
  }

  String _fmtArea(double sqMeters) {
    if (sqMeters < 1) return '${(sqMeters * 10000).toStringAsFixed(1)} cm²';
    return '${sqMeters.toStringAsFixed(2)} m²';
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}