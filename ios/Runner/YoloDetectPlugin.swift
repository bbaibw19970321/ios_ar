import Flutter
import UIKit
import ARKit
import Vision
import CoreML
import Accelerate

public class YoloDetectPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?
    private var displayLink: CADisplayLink?
    private var visionModel: VNCoreMLModel?
    private var arSession: ARSession?
    private var isRunning = false
    private var lastTime: CFTimeInterval = 0
    private let interval: CFTimeInterval = 0.033
    private var retryCount = 0
    private var exposureLocked = false

    // ✅ 多帧融合缓冲
    private var recentBoxes: [[[String: Any]]] = []
    private let fusionFrames = 3

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
        recentBoxes.removeAll()

        // ✅ 恢复自动曝光
        if exposureLocked {
            if let device = AVCaptureDevice.default(for: .video) {
                do {
                    try device.lockForConfiguration()
                    device.activeMaxExposureDuration = device.activeFormat.maxExposureDuration
                    device.exposureMode = .continuousAutoExposure
                    device.unlockForConfiguration()
                    exposureLocked = false
                } catch {}
            }
        }
    }

    @objc private func tick() {
        guard isRunning,
              let sink = eventSink,
              let model = visionModel,
              let frame = arSession?.currentFrame else { return }

        // ✅ 仅首次锁定曝光
        if !exposureLocked {
            if let device = AVCaptureDevice.default(for: .video) {
                do {
                    try device.lockForConfiguration()
                    device.activeMaxExposureDuration = CMTime(value: 1, timescale: 120)
                    device.exposureMode = .continuousAutoExposure
                    device.unlockForConfiguration()
                    exposureLocked = true
                } catch {}
            }
        }

        let now = CACurrentMediaTime()
        guard now - lastTime >= interval else { return }
        lastTime = now

        let pixelBuffer = frame.capturedImage

        // ✅ 将 kx/ky 提取到闭包外部可访问的位置
        let bufW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let bufH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let imgW = bufH
        let imgH = bufW

        let rImg = min(imgW, imgH) / max(imgW, imgH)
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

        // ✅ 用局部变量捕获 kx/ky，避免闭包作用域问题
        let capturedKx = kx
        let capturedKy = ky

        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self = self else { return }
            guard let obs = req.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async { sink([]) }
                return
            }

            // ✅ 坐标映射完全不变，只是把 kx/ky 换成 capturedKx/capturedKy
            let currentBoxes: [[String: Any]] = obs.compactMap { o in
                guard let top = o.labels.first, top.confidence > 0.3 else { return nil }
                let b = o.boundingBox

                let u = b.origin.x
                let v = 1.0 - b.origin.y - b.height
                let w = b.width
                let h = b.height

                let xN = 0.5 + (u - 0.5) * capturedKx
                let yN = 0.5 + (v - 0.5) * capturedKy
                let wN = w * capturedKx
                let hN = h * capturedKy

                return [
                    "x": xN,
                    "y": yN,
                    "w": wN,
                    "h": hN,
                    "conf": top.confidence,
                    "label": top.identifier
                ]
            }

            // ✅ 多帧融合
            self.recentBoxes.append(currentBoxes)
            if self.recentBoxes.count > self.fusionFrames {
                self.recentBoxes.removeFirst()
            }

            let fused = self.temporalFuse(self.recentBoxes)
            DispatchQueue.main.async { sink(fused) }
        }

        request.imageCropAndScaleOption = .scaleFit
        // ✅ 移除了无效的 VNImageConstraint，Vision 会自动使用模型原生输入尺寸

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right
        )
        try? handler.perform([request])
    }

    /// ✅ 时序融合：跨帧NMS + 置信度加权平均
        /// ✅ 修复版时序融合
    private func temporalFuse(_ frames: [[[String: Any]]]) -> [[String: Any]] {
        // 展平所有帧的框，附带来源帧索引
        var all: [(box: [String: Any], conf: Double, frameIdx: Int)] = []
        for (idx, frame) in frames.enumerated() {
            for b in frame {
                if let c = b["conf"] as? Double, c > 0.2 { // ✅ 降低内部阈值
                    all.append((b, c, idx))
                }
            }
        }
        guard !all.isEmpty else { return [] }

        // 按置信度降序
        all.sort { $0.conf > $1.conf }

        var result: [[String: Any]] = []
        var used = Set<Int>()

        for i in 0..<all.count {
            guard !used.contains(i) else { continue }
            let bi = all[i].box
            guard let xi = bi["x"] as? Double,
                  let yi = bi["y"] as? Double,
                  let wi = bi["w"] as? Double,
                  let hi = bi["h"] as? Double else { continue }

            // ✅ 直接用最高置信度作为基准，不做除法衰减
            var bestConf = all[i].conf
            var sumX = xi * bestConf
            var sumY = yi * bestConf
            var sumW = wi * bestConf
            var sumH = hi * bestConf
            var weightSum = bestConf
            used.insert(i)

            // 合并同组框
            for j in (i+1)..<all.count {
                guard !used.contains(j) else { continue }
                let bj = all[j].box
                guard let xj = bj["x"] as? Double,
                      let yj = bj["y"] as? Double,
                      let wj = bj["w"] as? Double,
                      let hj = bj["h"] as? Double else { continue }

                let ix1 = max(xi, xj), iy1 = max(yi, yj)
                let ix2 = min(xi+wi, xj+wj), iy2 = min(yi+hi, yj+hj)
                let iw = max(0, ix2-ix1), ih = max(0, iy2-iy1)
                let inter = iw * ih
                let union = wi*hi + wj*hj - inter
                let iou = union > 0 ? inter / union : 0.0

                if iou > 0.25 { // ✅ IoU阈值从0.3降到0.25，模糊框变形也能合并
                    let cj = all[j].conf
                    sumX += xj * cj; sumY += yj * cj
                    sumW += wj * cj; sumH += hj * cj
                    weightSum += cj
                    // ✅ 取最大置信度而非平均
                    bestConf = max(bestConf, cj)
                    used.insert(j)
                }
            }

            // ✅ 输出置信度 = 组内最高置信度（不衰减）
            // 多帧命中天然可信，不需要额外boost也不需要除法
            result.append([
                "x": sumX / weightSum,
                "y": sumY / weightSum,
                "w": sumW / weightSum,
                "h": sumH / weightSum,
                "conf": bestConf,
                "label":"snail"
            ])
        }

        // ✅ 只保留置信度 > 0.25 的结果（与Dart端0.3阈值留有余量）
        return result.filter { ($0["conf"] as? Double ?? 0) > 0.25 }
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