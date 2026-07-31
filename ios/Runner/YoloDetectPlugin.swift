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
    private weak var arSCNView: ARSCNView?          // ✅ 新增：保存视图引用，用于 hitTest
    private var isRunning = false
    private var lastTime: CFTimeInterval = 0
    private let interval: CFTimeInterval = 0.1
    private var retryCount = 0
    private var confThreshold: Float = 0.5

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
        case "setConf":
            if let n = call.arguments as? NSNumber {
                confThreshold = n.floatValue
                print("🎚 conf threshold = \(confThreshold)")
            }
            result(nil)
        case "hitTestCorners":                       // ✅ 新增：四角 hitTest
            hitTestCorners(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ✅ 新增：屏幕四角 hitTest → 世界坐标
    private func hitTestCorners(result: @escaping FlutterResult) {
    guard let arView = arSCNView else {
        print("❌ hitTestCorners: arSCNView is nil")
        result(FlutterError(code: "NO_AR_VIEW", message: "AR视图未就绪，请等待2秒后重试", details: nil))
        return
    }
    
    let bounds = arView.bounds
    let insets: CGFloat = 20
    let points = [
        CGPoint(x: bounds.minX + insets, y: bounds.minY + insets),
        CGPoint(x: bounds.maxX - insets, y: bounds.minY + insets),
        CGPoint(x: bounds.maxX - insets, y: bounds.maxY - insets),
        CGPoint(x: bounds.minX + insets, y: bounds.maxY - insets),
    ]
    
    var corners: [[Double]] = []
    for (i, pt) in points.enumerated() {
        // 先试 existingPlaneUsingExtent，失败再试 existingPlane，再试 estimatedHorizontalPlane
        var hits = arView.hitTest(pt, types: [.existingPlaneUsingExtent])
        if hits.isEmpty {
            hits = arView.hitTest(pt, types: [.existingPlane])
        }
        if hits.isEmpty {
            hits = arView.hitTest(pt, types: [.estimatedHorizontalPlane])
        }
        
        guard let hit = hits.first else {
            print("❌ hitTestCorners: 角点\(i) 未命中平面, point=\(pt)")
            result(FlutterError(code: "NO_PLANE",
                                message: "角点\(i+1)未检测到平面\n请对准地面/桌面，缓慢左右移动手机扫描",
                                details: nil))
            return
        }
        
        let t = hit.worldTransform
        let pos = [Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z)]
        print("✅ hitTestCorners: 角点\(i) = \(pos)")
        corners.append(pos)
    }
    
    print("✅ hitTestCorners: 返回 \(corners.count) 个角点")
    result(corners)
}

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
                                    message: "best.mlmodelc not in bundle",
                                    details: nil))
                return
            }
            do {
                let mlModel = try MLModel(contentsOf: url)
                visionModel = try VNCoreMLModel(for: mlModel)
            } catch {
                result(FlutterError(code: "MODEL_LOAD_ERROR",
                                    message: error.localizedDescription,
                                    details: nil))
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
                                    message: "Cannot find ARSession",
                                    details: nil))
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
        let thr = confThreshold

        let cw = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let ch = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let rImg = min(cw, ch) / max(cw, ch)
        let scr = UIScreen.main.bounds.size
        let rScr = min(scr.width, scr.height) / max(scr.width, scr.height)
        let kx: CGFloat
        let ky: CGFloat
        if rScr < rImg {
            kx = rImg / rScr
            ky = 1.0
        } else {
            kx = 1.0
            ky = rScr / rImg
        }

        let request = VNCoreMLRequest(model: model) { req, _ in
            guard let obs = req.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async { sink([]) }
                return
            }
            let boxes: [[String: Any]] = obs.compactMap { o in
                guard let top = o.labels.first, top.confidence > thr else { return nil }
                let b = o.boundingBox
                let u = b.origin.x
                let v = 1.0 - b.origin.y - b.height
                let w = b.width
                let h = b.height
                let xN = 0.5 + (u - 0.5) * kx
                let yN = 0.5 + (v - 0.5) * ky
                let wN = w * kx
                let hN = h * ky
                return [
                    "x": xN,
                    "y": yN,
                    "w": wN,
                    "h": hN,
                    "conf": top.confidence,
                    "label": top.identifier
                ]
            }
            DispatchQueue.main.async { sink(boxes) }
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right
        )
        try? handler.perform([request])
    }

    private func findARSession() -> ARSession? {
        guard let window = UIApplication.shared.windows.first else { return nil }
        return searchView(window)
    }

    private func searchView(_ view: UIView) -> ARSession? {
        if let arView = view as? ARSCNView {
            arSCNView = arView                       // ✅ 新增：顺手保存视图引用
            return arView.session
        }
        for sub in view.subviews {
            if let s = searchView(sub) { return s }
        }
        return nil
    }
}