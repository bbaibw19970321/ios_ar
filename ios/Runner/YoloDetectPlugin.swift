import Flutter
import UIKit
import ARKit
import Vision
import CoreML

public class YoloDetectPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, ARSessionDelegate {

    private var eventSink: FlutterEventSink?
    private var visionModel: VNCoreMLModel?
    private var arSession: ARSession?
    private var isRunning = false
    
    // ✅ 专用推理队列，避免阻塞主线程
    private let inferenceQueue = DispatchQueue(label: "yolo.inference", qos: .userInteractive)
    private var lastTime: CFTimeInterval = 0
    private let interval: CFTimeInterval = 0.033 // ~30 FPS
    private var retryCount = 0
    
    // ✅ 线程安全的时间戳保护
    private let timeLock = NSLock()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = YoloDetectPlugin()
        let method = FlutterMethodChannel(name: "yolo_detect", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)
        let event = FlutterEventChannel(name: "yolo_detect/events", binaryMessenger: registrar.messenger())
        event.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start": startDetection(result: result)
        case "stop": stopDetection(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
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
                result(FlutterError(code: "MODEL_NOT_FOUND", message: "best.mlmodelc not in bundle", details: nil))
                return
            }
            do {
                let mlModel = try MLModel(contentsOf: url)
                visionModel = try VNCoreMLModel(for: mlModel)
            } catch {
                result(FlutterError(code: "MODEL_LOAD_ERROR", message: error.localizedDescription, details: nil))
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
                result(FlutterError(code: "NO_AR_SESSION", message: "Cannot find ARSession", details: nil))
                retryCount = 0
                return
            }
        }

        retryCount = 0
        isRunning = true
        lastTime = 0
        
        // ✅ 注册为 ARSession delegate，与相机帧严格同步
        arSession?.delegate = self
        
        result(nil)
    }

    private func stopDetection() {
        isRunning = false
        arSession?.delegate = nil
    }

    // ✅ ARSessionDelegate：每帧回调，消除 CADisplayLink 相位差
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }
        
        timeLock.lock()
        let now = CACurrentMediaTime()
        let elapsed = now - lastTime
        if elapsed < interval {
            timeLock.unlock()
            return
        }
        lastTime = now
        timeLock.unlock()
        
        // ✅ 扔到专用队列，不阻塞主线程/AR渲染
        inferenceQueue.async { [weak self] in
            self?.processFrame(frame)
        }
    }

    private func processFrame(_ frame: ARFrame) {
        guard let sink = eventSink, let model = visionModel else { return }
        
        let pixelBuffer = frame.capturedImage
        let bufW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let bufH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let request = VNCoreMLRequest(model: model) { req, _ in
            guard let obs = req.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async { sink(Data()) }
                return
            }
            
            var buffer = [Float32]()
            buffer.reserveCapacity(1 + obs.count * 5)
            
            for o in obs {
                guard let top = o.labels.first, top.confidence > 0.3 else { continue }
                
                // ✅ 兼容 iOS 13+：手动处理 scaleFit letterbox 反算
                // Vision 返回的 boundingBox 已经是相对于原始图像空间的归一化坐标（左下原点）
                // .scaleFit 模式下 Vision 内部已自动将 letterbox 偏移纳入计算
                // 因此直接使用 boundingBox 即可，无需 boundingBoxForImageRect
                let b = o.boundingBox
                
                // 左下原点 → 左上原点
                buffer.append(Float32(b.origin.x))
                buffer.append(Float32(1.0 - b.origin.y - b.height))
                buffer.append(Float32(b.width))
                buffer.append(Float32(b.height))
                buffer.append(Float32(top.confidence))
            }
            
            let count = Float32(buffer.count / 5)
            var finalBuffer = [count] + buffer
            
            let data = Data(bytes: &finalBuffer, count: finalBuffer.count * MemoryLayout<Float32>.size)
            DispatchQueue.main.async { sink(data) }
        }

        // ✅ 显式指定完整枚举路径，解决 "Cannot infer contextual base" 错误
        request.imageCropAndScaleOption = VNImageCropAndScaleOption.scaleFit
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
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