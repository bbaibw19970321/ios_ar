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

        // ✅ 计算 .scaleFit 下的 letterbox 补偿参数
        // 相机buffer横屏1920x1080，orientation=.right → 有效图像1080x1920(竖)
        let bufW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))   // 1920
        let bufH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))  // 1080
        let imgW = bufH  // 1080 (旋转后有效宽)
        let imgH = bufW  // 1920 (旋转后有效高)

        // scaleFit: 等比缩放到屏幕内，多余部分留黑边
        let scrW = UIScreen.main.bounds.width
        let scrH = UIScreen.main.bounds.height
        let scaleX = scrW / imgW
        let scaleY = scrH / imgH
        let fitScale = min(scaleX, scaleY)

        // 缩放后图像在屏幕中的实际尺寸
        let fittedW = imgW * fitScale
        let fittedH = imgH * fitScale

        // letterbox 偏移（归一化到 [0,1]）
        let offsetX = (scrW - fittedW) / 2.0 / scrW   // 水平黑边占比
        let offsetY = (scrH - fittedH) / 2.0 / scrH   // 垂直黑边占比
        let normW = fittedW / scrW                      // 有效区域宽度占比
        let normH = fittedH / scrH                      // 有效区域高度占比

        let request = VNCoreMLRequest(model: model) { req, _ in
            guard let obs = req.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async { sink([]) }
                return
            }
            let boxes: [[String: Any]] = obs.compactMap { o in
                guard let top = o.labels.first, top.confidence > 0.3 else { return nil }
                let b = o.boundingBox

                // Vision .scaleFit 返回的坐标是"有效图像区域"内的归一化坐标
                // 需要映射到全屏归一化坐标：screen = offset + vision * normSize
                // Y轴翻转：Vision原点在左下，Flutter原点在左上
                let xN = offsetX + b.origin.x * normW
                let yN = offsetY + (1.0 - b.origin.y - b.height) * normH
                let wN = b.width * normW
                let hN = b.height * normH

                // 钳制到 [0,1]
                let cx = max(0.0, min(1.0, xN))
                let cy = max(0.0, min(1.0, yN))
                let cw = max(0.0, min(1.0 - cx, wN))
                let ch = max(0.0, min(1.0 - cy, hN))

                return [
                    "x": cx,
                    "y": cy,
                    "w": cw,
                    "h": ch,
                    "conf": top.confidence,
                    "label": top.identifier
                ]
            }
            DispatchQueue.main.async { sink(boxes) }
        }

        // ✅ .scaleFit：等比缩放，Vision内部处理letterbox
        // 我们上面手动补偿了letterbox偏移，使坐标对齐Flutter Canvas
        request.imageCropAndScaleOption = .scaleFit

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