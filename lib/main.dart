import 'package:ar_flutter_plugin/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin/models/ar_anchor.dart';
import 'package:flutter/material.dart';

class ARMeasureScreen extends StatefulWidget {
  @override
  _ARMeasureScreenState createState() => _ARMeasureScreenState();
}

class _ARMeasureScreenState extends State<ARMeasureScreen> {
  late ARSessionManager arSessionManager;
  List<ARAnchor> anchors = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ARView(
        onARViewCreated: onARViewCreated,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: addMeasurePoint,
        child: Icon(Icons.add),
      ),
    );
  }

  void onARViewCreated(ARSessionManager sessionManager) {
    arSessionManager = sessionManager;
    arSessionManager.onInitialize(
      showFeaturePoints: true,
      showPlanes: true,
    );
  }

  void addMeasurePoint() async {
    // 添加测量点
    var hitTest = await arSessionManager.performHitTestOnPlane(
      x: 0.5, // 屏幕中心
      y: 0.5,
    );
    if (hitTest.isNotEmpty) {
      var anchor = ARPlaneAnchor(hitTest.first);
      arSessionManager.addAnchor(anchor);
      anchors.add(anchor);

      // 计算距离（示例：计算前两个点的距离）
      if (anchors.length >= 2) {
        var p1 = anchors[anchors.length - 2].transform.getTranslation();
        var p2 = anchors[anchors.length - 1].transform.getTranslation();
        var distance = calculateDistance(p1, p2);
        print("两点距离: ${distance.toStringAsFixed(2)} 米");
      }
    }
  }

  double calculateDistance(List<double> p1, List<double> p2) {
    return Math.sqrt(
      Math.pow(p2[0] - p1[0], 2) +
      Math.pow(p2[1] - p1[1], 2) +
      Math.pow(p2[2] - p1[2], 2),
    );
  }
}