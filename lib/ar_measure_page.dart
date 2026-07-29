import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as v64;

class ARMeasurePage extends StatefulWidget {
  const ARMeasurePage({super.key});
  @override
  State<ARMeasurePage> createState() => _ARMeasurePageState();
}

class _ARMeasurePageState extends State<ARMeasurePage> {
  ARKitController? _controller;

  final List<v64.Vector3> _pts = [];
  final List<String> _nodeIds = [];
  String _info = '将手机对准地面/桌面，缓慢移动以识别平面';
  String _result = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        ARKitSceneView(
          planeDetection: ARPlaneDetection.horizontalAndVertical,
          showFeaturePoints: true,
          autoenablesDefaultLighting: true,
          onARKitViewCreated: (c) {
            _controller = c;
          },
          onARTap: _onARTap,
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

  void _onARTap(ARKitHitTestResultType type, List<ARKitNode> nodes) {
    if (nodes.isEmpty) return;
    final pos = nodes.first.position;

    setState(() {
      final dotName = 'dot_${_pts.length}';
      _addNode(_makeDot(pos), dotName);

      if (_pts.isNotEmpty) {
        final prev = _pts.last;
        final lineName = 'line_${_pts.length}';
        _addNode(_makeLine(prev, pos), lineName);
      }

      _pts.add(pos);
      _updateReadout();
    });
  }

  void _addNode(ARKitNode node, String name) {
    node.name = name;
    _controller!.add(node);
    _nodeIds.add(name);
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
      _addNode(_makeLine(_pts.last, _pts.first), 'line_close');
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
      if (_nodeIds.isNotEmpty) _controller!.remove(_nodeIds.removeLast());
      if (_nodeIds.isNotEmpty) _controller!.remove(_nodeIds.removeLast());
      _updateReadout();
    });
  }

  void _clear() {
    setState(() {
      for (final id in _nodeIds) {
        _controller!.remove(id);
      }
      _nodeIds.clear();
      _pts.clear();
      _result = '';
      _info = '将手机对准地面/桌面，缓慢移动以识别平面';
    });
  }

  ARKitNode _makeDot(v64.Vector3 pos) {
    return ARKitNode(
      position: pos,
      geometry: ARKitSphereGeometry(
        radius: 0.01,
        materials: [
          ARKitMaterial(
            diffuse: ARKitMaterialProperty(color: Colors.yellow),
            specular: ARKitMaterialProperty(color: Colors.white),
          ),
        ],
      ),
    );
  }

  ARKitNode _makeLine(v64.Vector3 from, v64.Vector3 to) {
    return ARKitNode(
      geometry: ARKitLine(fromVector: from, toVector: to),
    );
  }

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