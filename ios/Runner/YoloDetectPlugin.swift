import Flutter
import ARKit
import Vision
import CoreML

class YoloDetectPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?
    private var displayLink: CADisplayLink?
    private var visionModel: VNCoreMLModel?
    private var isRunning = false
    private var lastProcessTime: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 0.1  // 最多 10fps 推理，省电

    // MARK: - Plugin 注册

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = YoloDetectPlugin()

        let method = FlutterMethodChannel(name: "yolo_detect", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)

        let event = FlutterEventChannel(name: "yolo_detect/events", binaryMessenger: registrar.messenger())
        event.setStreamHandler(instance)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            startDetection()
            result(nil)
        case "stop":
            stopDetection()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - EventChannel

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - 检测控制

    private func startDetection() {
        guard !isRunning else { return }

        // 加载模型（只需一次）
        if visionModel == nil {
            guard let url = Bundle.main.url(forResource: "best", withExtension: "mlmodelc"),
                  let model = try? MLModel(contentsOf: url),
                  let vnModel = try? VNCoreMLModel(for: model) else {
                print("❌ YOLO 模型加载失败")
                return
            }
            visionModel = vnModel
        }

        isRunning = true
        displayLink = CADisplayLink(target: self, selector: #selector(processFrame))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
        displayLink?.add(to: .main, forMode: .common)
        print("✅ YOLO 检测已启动")
    }

    private func stopDetection() {
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        print("🛑 YOLO 检测已停止")
    }

    // MARK: - 每帧推理

    @objc private func processFrame() {
        guard isRunning,
              let sink = eventSink,
              let model = visionModel else { return }

        // 限流
        let now = CACurrentMediaTime()
        guard now - lastProcessTime >= minInterval else { return }
        lastProcessTime = now

        // 从 ARKit 当前帧拿画面（不抢 delegate）
        guard let session = ARSessionRegistry.shared.currentSession,
              let frame = session.currentFrame else { return }

        let pixelBuffer = frame.capturedImage
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

        // Vision 请求
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let results = req.results as? [VNRecognizedObjectObservation] else {
                sink([])
                return
            }

            // 转成 Flutter 可用的字典数组
            let detections: [[String: Any]] = results.compactMap { obs in
                guard let label = obs.labels.first else { return nil }
                let box = obs.boundingBox  // 归一化坐标，原点在左下
                return [
                    "x": Double(box.origin.x),
                    "y": Double(1.0 - box.origin.y - box.height),  // 转成左上角原点
                    "w": Double(box.width),
                    "h": Double(box.height),
                    "confidence": Double(label.confidence),
                    "label": label.identifier,
                    "imageWidth": imageWidth,
                    "imageHeight": imageHeight,
                ]
            }

            DispatchQueue.main.async {
                sink(detections)
            }
        }
        request.imageCropAndScaleOption = .scaleFill

        // 执行推理
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try? handler.perform([request])
    }
}

// MARK: - ARSession 注册表（获取 arkit_plugin 的 session）

class ARSessionRegistry {
    static let shared = ARSessionRegistry()
    private(set) var currentSession: ARSession?

    func register(_ session: ARSession) {
        currentSession = session
    }
}