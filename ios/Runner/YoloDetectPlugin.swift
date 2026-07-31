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
    private var arView: ARSCNView?
    private var isRunning = false
    private var lastTime: CFTimeInterval = 0
    private let interval: CFTimeInterval = 0.1
    private var retryCount = 0

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = YoloDetectPlugin()
        let method = FlutterMethodChannel(name: "yolo_detect", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)
        let event = FlutterEventChannel(name: "yolo_detect/events", binaryMessenger: registrar.messenger())
        event.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            startDetection(result: result)
        case "stop":
            stopDetection()
            result(nil)

        // ✅ 改进5: 查询 tracking 状态
        case "getTrackingState":
            result(currentTrackingState())

        // ✅ 改进6: 给定两个世界坐标，native 内部投影→插值→hitTest
        case "interpolateWorld":
            handleInterpolateWorld(call, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - ✅ 改进5

    private func currentTrackingState() -> String {
        guard let frame = (arSession ?? findARSession())?.currentFrame else { return "notAvailable" }
        switch frame.camera.trackingState {
        case .normal: return "normal"
        case .limited(let r):
            switch r {
            case .excessiveMotion:      return "limited_motion"
            case .insufficientFeatures: return "limited_features"
            case .initializing:         return "limited_init"
            case .relocalizing:         return "limited_reloc"
            @unknown default:           return "limited"
            }
        case .notAvailable: return "notAvailable"
        @unknown default:   return "unknown"
        }
    }

    // MARK: - ✅ 改进6: 在 native 内部完成投影+插值+hitTest（避免坐标系问题）

    private func handleInterpolateWorld(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let ax = args["ax"] as? Double, let ay = args["ay"] as? Double, let az = args["az"] as? Double,
              let bx = args["bx"] as? Double, let by = args["by"] as? Double, let bz = args["bz"] as? Double,
              let steps = args["steps"] as? Int else {
            result(FlutterError(code: "BAD_ARGS", message: "need ax..bz, steps", details: nil))
            return
        }
        guard let view = ensureARView() else { result([]); return }

        let types: ARHitTestResult.ResultType = [.existingPlaneUsingExtent, .existingPlane, .estimatedHorizontalPlane, .featurePoint]

        // 世界坐标 → 屏幕坐标（ARSCNView 内部坐标系，不会错位）
        let pA = view.projectPoint(SCNVector3(Float(ax), Float(ay), Float(az)))
        let pB = view.projectPoint(SCNVector3(Float(bx), Float(by), Float(bz)))

        var points: [[String: Double]] = []
        for i in 1..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let sx = pA.x + (pB.x - pA.x) * t
            let sy = pA.y + (pB.y - pA.y) * t
            if let hit = view.hitTest(CGPoint(x: sx, y: sy), types: types).first {
                let c = hit.worldTransform.columns.3
                points.append(["x": Double(c.x), "y": Double(c.y), "z": Double(c.z)])
            }
        }
        result(points)
    }

    // MARK: - 工具

    private func ensureARView() -> ARSCNView? {
        if arView == nil { arView = findARView() }
        if arSession == nil { arSession = arView?.session }
        return arView
    }
    private func findARView() -> ARSCNView? {
        guard let w = UIApplication.shared.windows.first else { return nil }
        return searchARView(w)
    }
    private func searchARView(_ v: UIView) -> ARSCNView? {
        if let a = v as? ARSCNView { return a }
        for s in v.subviews { if let r = searchARView(s) { return r } }
        return nil
    }
    private func findARSession() -> ARSession? { return findARView()?.session }

    // MARK: - YOLO 检测（原封不动）

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events; return nil
    }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil; return nil
    }

    private func startDetection(result: @escaping FlutterResult) {
        guard !isRunning else { result(nil); return }
        if visionModel == nil {
            guard let url = Bundle.main.url(forResource: "best", withExtension: "mlmodelc") else {
                result(FlutterError(code: "MODEL_NOT_FOUND", message: "best.mlmodelc not in bundle", details: nil)); return
            }
            do { visionModel = try VNCoreMLModel(for: try MLModel(contentsOf: url)) }
            catch { result(FlutterError(code: "MODEL_LOAD_ERROR", message: error.localizedDescription, details: nil)); return }
        }
        if arSession == nil { arSession = findARSession() }
        if arSession == nil {
            retryCount += 1
            if retryCount <= 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startDetection(result: result) }
                return
            } else {
                result(FlutterError(code: "NO_AR_SESSION", message: "Cannot find ARSession", details: nil))
                retryCount = 0; return
            }
        }
        retryCount = 0; isRunning = true
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.preferredFramesPerSecond = 10
        displayLink?.add(to: .main, forMode: .common)
        result(nil)
    }

    private func stopDetection() { isRunning = false; displayLink?.invalidate(); displayLink = nil }

    @objc private func tick() {
        guard isRunning, let sink = eventSink, let model = visionModel,
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
        let kx: CGFloat, ky: CGFloat
        if rScr < rImg { kx = rImg / rScr; ky = 1.0 } else { kx = 1.0; ky = rScr / rImg }

        let request = VNCoreMLRequest(model: model) { req, _ in
            guard let obs = req.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async { sink([]) }; return
            }
            let boxes: [[String: Any]] = obs.compactMap { o in
                guard let top = o.labels.first, top.confidence > 0.8 else { return nil }
                let b = o.boundingBox
                let u = b.origin.x, v = 1.0 - b.origin.y - b.height
                return ["x": 0.5 + (u - 0.5) * kx, "y": 0.5 + (v - 0.5) * ky,
                        "w": b.width * kx, "h": b.height * ky,
                        "conf": top.confidence, "label": top.identifier]
            }
            DispatchQueue.main.async { sink(boxes) }
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try? handler.perform([request])
    }
}