import Flutter
import UIKit
import ARKit
import Vision
import CoreML

public class YoloDetectPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?
    private var displayLink: CADisplayLink?
    private var visionModel: VNCoreMLModel?
    private var arSession: ARSession?
    private var arView: ARSCNView?          // ✅ 改进1/2/6: 保存 ARSCNView 引用
    private var isRunning = false
    private var lastTime: CFTimeInterval = 0
    private let interval: CFTimeInterval = 0.1
    private var retryCount = 0

    // ✅ 改进3: 锚点（第一个测量点）
    private var measureAnchor: ARAnchor?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = YoloDetectPlugin()

        let method = FlutterMethodChannel(
            name: "yolo_detect",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: method)

        let event = FlutterEventChannel(
            name: "yolo_detect/events",
            binaryMessenger: registrar.messenger()
        )
        event.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            startDetection(result: result)
        case "stop":
            stopDetection()
            result(nil)

        // ✅ 改进5: 获取当前 tracking 状态
        case "getTrackingState":
            result(getTrackingState())

        // ✅ 改进1+2: 稳定 hitTest（平面优先 + 5次采样取中位数）
        case "hitTestStable":
            handleHitTestStable(call, result: result)

        // ✅ 改进6: 两点之间沿屏幕连线自动补点
        case "hitTestAlongLine":
            handleHitTestAlongLine(call, result: result)

        // ✅ 改进3: 重置锚点（清空测量时调用）
        case "resetAnchor":
            if let anchor = measureAnchor {
                arSession?.remove(anchor: anchor)
            }
            measureAnchor = nil
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - ✅ 改进5: Tracking 状态

    private func getTrackingState() -> String {
        guard let frame = arSession?.currentFrame ?? findARSession()?.currentFrame else {
            return "notAvailable"
        }
        switch frame.camera.trackingState {
        case .normal:
            return "normal"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:      return "limited_motion"
            case .insufficientFeatures: return "limited_features"
            case .initializing:         return "limited_initializing"
            case .relocalizing:         return "limited_relocalizing"
            @unknown default:           return "limited_unknown"
            }
        case .notAvailable:
            return "notAvailable"
        @unknown default:
            return "unknown"
        }
    }

    // MARK: - ✅ 改进1+2: 稳定 hitTest

    private func handleHitTestStable(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let x = args["x"] as? Double,
              let y = args["y"] as? Double else {
            result(FlutterError(code: "INVALID_ARGS", message: "Need x, y", details: nil))
            return
        }
        guard let view = ensureARView() else {
            result(FlutterError(code: "NO_AR_VIEW", message: "Cannot find ARSCNView", details: nil))
            return
        }

        let types: ARHitTestResult.ResultType = [
            .existingPlaneUsingExtent,   // ✅ 改进1: 平面优先
            .existingPlane,
            .estimatedHorizontalPlane,
            .featurePoint                // 最后退到特征点
        ]

        // ✅ 改进2: 5次采样（中心 + 四方向±2px），取中位数
        let offsets: [(CGFloat, CGFloat)] = [(0,0), (-2,0), (2,0), (0,-2), (0,2)]
        var positions: [SIMD3<Float>] = []
        var hitType: String = "none"

        for (dx, dy) in offsets {
            let p = CGPoint(x: x + dx, y: y + dy)
            let hits = view.hitTest(p, types: types)
            if let hit = hits.first {
                let t = hit.worldTransform.columns.3
                positions.append(SIMD3<Float>(t.x, t.y, t.z))
                // 记录命中类型（取第一次命中的）
                if hitType == "none" {
                    switch hit.type {
                    case .existingPlaneUsingExtent: hitType = "plane_extent"
                    case .existingPlane:            hitType = "plane"
                    case .estimatedHorizontalPlane: hitType = "estimated_plane"
                    case .featurePoint:             hitType = "feature"
                    default:                        hitType = "other"
                    }
                }
            }
        }

        guard !positions.isEmpty else {
            result(nil)  // 没命中任何东西
            return
        }

        let median = medianPosition(positions)

        // ✅ 改进3: 如果还没有锚点，在第一个命中位置创建
        if measureAnchor == nil {
            let anchor = ARAnchor(transform: simd_float4x4(
                SIMD4<Float>(1,0,0,0),
                SIMD4<Float>(0,1,0,0),
                SIMD4<Float>(0,0,1,0),
                SIMD4<Float>(median.x, median.y, median.z, 1)
            ))
            arSession?.add(anchor: anchor)
            measureAnchor = anchor
        }

        // 返回世界坐标 + 相对锚点坐标
        var localX = median.x, localY = median.y, localZ = median.z
        if let anchor = measureAnchor {
            let anchorPos = anchor.transform.columns.3
            localX = median.x - anchorPos.x
            localY = median.y - anchorPos.y
            localZ = median.z - anchorPos.z
        }

        result([
            "wx": Double(median.x),
            "wy": Double(median.y),
            "wz": Double(median.z),
            "lx": Double(localX),
            "ly": Double(localY),
            "lz": Double(localZ),
            "type": hitType
        ])
    }

    // MARK: - ✅ 改进6: 沿屏幕连线补点

    private func handleHitTestAlongLine(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let x1 = args["x1"] as? Double,
              let y1 = args["y1"] as? Double,
              let x2 = args["x2"] as? Double,
              let y2 = args["y2"] as? Double,
              let steps = args["steps"] as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "Need x1,y1,x2,y2,steps", details: nil))
            return
        }
        guard let view = ensureARView() else { result([]); return }

        let types: ARHitTestResult.ResultType = [
            .existingPlaneUsingExtent, .existingPlane, .estimatedHorizontalPlane, .featurePoint
        ]

        var points: [[String: Double]] = []
        for i in 1..<steps {
            let t = Double(i) / Double(steps)
            let px = x1 + (x2 - x1) * t
            let py = y1 + (y2 - y1) * t
            let p = CGPoint(x: px, y: py)
            if let hit = view.hitTest(p, types: types).first {
                let tr = hit.worldTransform.columns.3
                var lx = tr.x, ly = tr.y, lz = tr.z
                if let anchor = measureAnchor {
                    let ap = anchor.transform.columns.3
                    lx = tr.x - ap.x; ly = tr.y - ap.y; lz = tr.z - ap.z
                }
                points.append([
                    "wx": Double(tr.x), "wy": Double(tr.y), "wz": Double(tr.z),
                    "lx": Double(lx),   "ly": Double(ly),   "lz": Double(lz)
                ])
            }
        }
        result(points)
    }

    // MARK: - 工具方法

    private func medianPosition(_ pts: [SIMD3<Float>]) -> SIMD3<Float> {
        guard pts.count > 1 else { return pts.first ?? SIMD3<Float>(0,0,0) }
        func med(_ arr: [Float]) -> Float {
            let s = arr.sorted()
            let n = s.count
            return n % 2 == 1 ? s[n/2] : (s[n/2-1] + s[n/2]) / 2
        }
        return SIMD3<Float>(
            med(pts.map { $0.x }),
            med(pts.map { $0.y }),
            med(pts.map { $0.z })
        )
    }

    private func ensureARView() -> ARSCNView? {
        if arView == nil { arView = findARView() }
        if arSession == nil { arSession = arView?.session ?? findARSession() }
        return arView
    }

    private func findARView() -> ARSCNView? {
        guard let window = UIApplication.shared.windows.first else { return nil }
        return searchViewForARView(window)
    }

    private func searchViewForARView(_ view: UIView) -> ARSCNView? {
        if let arView = view as? ARSCNView { return arView }
        for sub in view.subviews {
            if let s = searchViewForARView(sub) { return s }
        }
        return nil
    }

    private func findARSession() -> ARSession? {
        return findARView()?.session
    }

    // MARK: - YOLO 检测（原有逻辑不变）

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func startDetection(result: @escaping FlutterResult) {
        guard !isRunning else { result(nil); return }

        if visionModel == nil {
            guard let url = Bundle.main.url(forResource: "best", withExtension: "mlmodelc") else {
                result(FlutterError(code: "MODEL_NOT_FOUND",
                                    message: "best.mlmodelc not in bundle", details: nil))
                return
            }
            do {
                let mlModel = try MLModel(contentsOf: url)
                visionModel = try VNCoreMLModel(for: mlModel)
            } catch {
                result(FlutterError(code: "MODEL_LOAD_ERROR",
                                    message: error.localizedDescription, details: nil))
                return
            }
        }

        if arSession == nil { arSession = findARSession() }
        if arSession == nil {
            retryCount += 1
            if retryCount <= 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startDetection(result: result)
                }
                return
            } else {
                result(FlutterError(code: "NO_AR_SESSION",
                                    message: "Cannot find ARSession", details: nil))
                retryCount = 0
                return
            }
        }

        retryCount = 0
        isRunning = true
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.preferredFramesPerSecond = 10
        displayLink?.add(to: .main, forMode: .common)
        result(nil)
    }

    private func stopDetection() {
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard isRunning,
              let sink = eventSink,
              let model = visionModel,
              let frame = arSession?.currentFrame else { return }

        let now = CACurrentMediaTime()
        guard now - lastTime >= interval else { return }
        lastTime = now

        let pixelBuffer = frame.capturedImage

        let cw = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let ch = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let rImg = min(cw, ch) / max(cw, ch)
        let scr = UIScreen.main.bounds.size
        let rScr = min(scr.width, scr.height) / max(scr.width, scr.height)
        let kx: CGFloat
        let ky: CGFloat
        if rScr < rImg { kx = rImg / rScr; ky = 1.0 }
        else           { kx = 1.0; ky = rScr / rImg }

        let request = VNCoreMLRequest(model: model) { req, _ in
            guard let obs = req.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async { sink([]) }
                return
            }
            let boxes: [[String: Any]] = obs.compactMap { o in
                guard let top = o.labels.first, top.confidence > 0.8 else { return nil }
                let b = o.boundingBox
                let u = b.origin.x
                let v = 1.0 - b.origin.y - b.height
                let xN = 0.5 + (u - 0.5) * kx
                let yN = 0.5 + (v - 0.5) * ky
                let wN = b.width * kx
                let hN = b.height * ky
                return ["x": xN, "y": yN, "w": wN, "h": hN,
                        "conf": top.confidence, "label": top.identifier]
            }
            DispatchQueue.main.async { sink(boxes) }
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try? handler.perform([request])
    }
}