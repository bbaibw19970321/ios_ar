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
    private var isRunning = false
    private var lastTime: CFTimeInterval = 0
    private let interval: CFTimeInterval = 0.1
    private var retryCount = 0

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
        default:
            result(FlutterMethodNotImplemented)
        }
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

        // ---- 计算 aspect-fill 映射系数：相机图归一化 -> 屏幕归一化 ----
        let cw = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let ch = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let rImg = min(cw, ch) / max(cw, ch)                 // 摆正竖图宽高比 (<1)
        let scr = UIScreen.main.bounds.size
        let rScr = min(scr.width, scr.height) / max(scr.width, scr.height)
        let kx: CGFloat
        let ky: CGFloat
        if rScr < rImg {     // 竖屏典型：左右被裁，水平放大
            kx = rImg / rScr
            ky = 1.0
        } else {             // 上下被裁，垂直放大
            kx = 1.0
            ky = rScr / rImg
        }

        let request = VNCoreMLRequest(model: model) { req, _ in
            guard let obs = req.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async { sink([]) }
                return
            }
            let boxes: [[String: Any]] = obs.compactMap { o in
                guard let top = o.labels.first, top.confidence > 0.3 else { return nil }
                let b = o.boundingBox
                // 1) 摆正竖图、左上原点归一化
                let u = b.origin.x
                let v = 1.0 - b.origin.y - b.height
                let w = b.width
                let h = b.height
                // 2) aspect-fill 居中裁剪 -> 屏幕归一化（Dart 直接乘 size 即可）
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
        if let arView = view as? ARSCNView { return arView.session }
        for sub in view.subviews {
            if let s = searchView(sub) { return s }
        }
        return nil
    }
}