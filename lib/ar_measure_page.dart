import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as v64;

/// AR 测距 + 测面积 页面
class ARMeasurePage extends StatefulWidget {
  const ARMeasurePage({super.key});
  @override
  State<ARMeasurePage> createState() => _ARMeasurePageState();
}

class _ARMeasurePage extends State<ARMeasurePage> {
  ARKitController? _controller;

  // ---------- 状态 ----------
  final List<v64.Vector3> _pts = [];   // 已标记的世界坐标（米）
  final List<String> _nodeIds = [];     // 所有已添加节点的 name（用于清除）
  String _info = '将手机对准地面/桌面，缓慢移动以识别平面';
  String _result = '';

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        // ===== AR 相机视图 =====
        ARKitSceneView(
          planeDetection: ARPlaneDetection.horizontalAndVertical,
          showFeaturePoints: true,
          autoenablesDefaultLighting: true,
          onARKitViewCreated: (c) {
            _controller = c;
          },
          onTap: _onTap,               // ← 点击屏幕 = 打一个测量点
        ),

        // ===== 顶部提示 =====
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 16, right: 16,
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

        // ===== 屏幕中心十字准星 =====
        Center(
          child: Icon(Icons.add, color: Colors.white.withOpacity(0.7), size: 36),
        ),

        // ===== 底部结果 + 按钮 =====
        Positioned(
          left: 16, right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // 测量结果
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
            // 操作按钮
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

  /// 点击屏幕 → 命中检测 → 拿到世界坐标 → 加点 / 画线 / 算距离
  void _onTap(ARKitHitTestResult result) {
    // 从 4×4 世界变换矩阵中提取平移分量 = 世界坐标 (x, y, z)，单位：米
    final pos = result.worldTransform.getTranslation();

    setState(() {
      // 1) 放一个小球标记
      final dotName = 'dot_${_pts.length}';
      _controller!.add(_makeDot(pos), name: dotName);
      _nodeIds.add(dotName);

      // 2) 如果已有上一个点，画连线 + 累加距离
      if (_pts.isNotEmpty) {
        final prev = _pts.last;
        final lineName = 'line_${_pts.length}';
        _controller!.add(_makeLine(prev, pos), name: lineName);
        _nodeIds.add(lineName);
      }

      // 3) 记录坐标
      _pts.add(pos);

      // 4) 刷新显示
      _updateReadout();
    });
  }

  /// 刷新距离 / 面积读数
  void _updateReadout() {
    if (_pts.length < 2) {
      _result = '';
      _info = '已标记 ${_pts.length} 个点，继续点击以测量';
      return;
    }

    // 折线总长
    double total = 0;
    for (int i = 1; i < _pts.length; i++) {
      total += _pts[i].distanceTo(_pts[i - 1]);
    }

    final buf = StringBuffer();
    buf.writeln('📏 距离：${_fmtLen(total)}');

    // 3 个点以上顺带显示面积
    if (_pts.length >= 3) {
      final area = _shoelaceXZ(_pts);
      buf.writeln('📐 面积：${_fmtArea(area)}');
    }

    _result = buf.toString().trim();
    _info = '已标记 ${_pts.length} 个点 ｜ 点击屏幕继续，或点「测面积」';
  }

  /// 点"测面积"按钮 → 闭合多边形 + 显示面积
  void _showArea() {
    if (_pts.length < 3) return;
    setState(() {
      // 画闭合线：最后一个点 → 第一个点
      final closeName = 'line_close';
      _controller!.add(_makeLine(_pts.last, _pts.first), name: closeName);
      _nodeIds.add(closeName);

      final area = _shoelaceXZ(_pts);
      double total = 0;
      for (int i = 1; i < _pts.length; i++) {
        total += _pts[i].distanceTo(_pts[i - 1]);
      }
      total += _pts.last.distanceTo(_pts.first); // 加上闭合边

      _result = '📏 周长：${_fmtLen(total)}\n📐 面积：${_fmtArea(area)}';
      _info = '测量完成！点「清空」重新开始';
    });
  }

  /// 撤销最后一个点
  void _undo() {
    if (_pts.isEmpty) return;
    setState(() {
      _pts.removeLast();
      // 移除最近添加的 1~2 个节点（点 + 线）
      if (_nodeIds.isNotEmpty) {
        _controller!.remove(_nodeIds.removeLast()); // 线
      }
      if (_nodeIds.isNotEmpty) {
        _controller!.remove(_nodeIds.removeLast()); // 点
      }
      _updateReadout();
    });
  }

  /// 清空所有
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

  // ============================================================
  //  3D 对象工厂
  // ============================================================

  /// 小球标记（半径 1cm，黄色）
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

  /// 两点之间的连线（红色）
  ARKitNode _makeLine(v64.Vector3 from, v64.Vector3 to) {
    return ARKitNode(
      geometry: ARKitLine(
        fromVector: from,
        toVector: to,
      ),
      // ARKitLine 自带位置，不需要额外 position
    );
  }

  // ============================================================
  //  数学工具
  // ============================================================

  /// 鞋带公式（Shoelace），投影到 XZ 地面平面，返回面积（m²）
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

  /// 格式化长度
  String _fmtLen(double meters) {
    if (meters < 1) return '${(meters * 100).toStringAsFixed(1)} cm';
    return '${meters.toStringAsFixed(2)} m';
  }

  /// 格式化面积
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