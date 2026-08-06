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
    private let interval: CFTimeInterval = 0.033 
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

    private var recentBoxes: [[[String: Any]]] = []
    private let fusionFrames = 3  // 融合最近3帧

    @objc private func tick() {
        guard isRunning,
              let sink = eventSink,
              let model = visionModel,
              let frame = arSession?.currentFrame else { return }

        // ... 曝光锁定代码保持不变 ...

        let now = CACurrentMediaTime()
        guard now - lastTime >= interval else { return }
        lastTime = now

        let pixelBuffer = frame.capturedImage

        // ... bufW/bufH/kx/ky 计算完全不变 ...

        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self = self else { return }
            guard let obs = req.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async { sink([]) }
                return
            }

            // ✅ 原始单帧结果（坐标映射完全不变）
            let currentBoxes: [[String: Any]] = obs.compactMap { o in
                guard let top = o.labels.first, top.confidence > 0.3 else { return nil }
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
                    "x": xN, "y": yN, "w": wN, "h": hN,
                    "conf": top.confidence,
                    "label": top.identifier
                ]
            }

            // ✅ 多帧融合：保留最近N帧，取置信度加权平均
            self.recentBoxes.append(currentBoxes)
            if self.recentBoxes.count > self.fusionFrames {
                self.recentBoxes.removeFirst()
            }

            let fused = self.temporalFuse(self.recentBoxes)

            DispatchQueue.main.async { sink(fused) }
        }

        request.imageCropAndScaleOption = .scaleFit
        request.resizeConstraint = VNImageConstraint(
            size: CGSize(width: 1280, height: 1280)  // ← 改成你模型的实际输入尺寸
        )
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try? handler.perform([request])
    }

    /// ✅ 时序融合：对最近N帧做跨帧NMS + 置信度聚合
    private func temporalFuse(_ frames: [[[String: Any]]]) -> [[String: Any]] {
        // 展平所有帧的框
        var all: [(box: [String: Any], conf: Double)] = []
        for frame in frames {
            for b in frame {
                if let c = b["conf"] as? Double {
                    all.append((b, c))
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
            let xi = bi["x"] as! Double, yi = bi["y"] as! Double
            let wi = bi["w"] as! Double, hi = bi["h"] as! Double

            var sumX = xi * all[i].conf
            var sumY = yi * all[i].conf
            var sumW = wi * all[i].conf
            var sumH = hi * all[i].conf
            var sumC = all[i].conf
            var count = 1
            used.insert(i)

            // 找同组框（IoU > 0.3）
            for j in (i+1)..<all.count {
                guard !used.contains(j) else { continue }
                let bj = all[j].box
                let xj = bj["x"] as! Double, yj = bj["y"] as! Double
                let wj = bj["w"] as! Double, hj = bj["h"] as! Double

                let ix1 = max(xi, xj), iy1 = max(yi, yj)
                let ix2 = min(xi+wi, xj+wj), iy2 = min(yi+hi, yj+hj)
                let iw = max(0, ix2-ix1), ih = max(0, iy2-iy1)
                let inter = iw * ih
                let union = wi*hi + wj*hj - inter
                let iou = union > 0 ? inter / union : 0.0

                if iou > 0.3 {
                    let cj = all[j].conf
                    sumX += xj * cj; sumY += yj * cj
                    sumW += wj * cj; sumH += hj * cj
                    sumC += cj; count += 1
                    used.insert(j)
                }
            }

            // 置信度加权平均坐标
            result.append([
                "x": sumX / sumC,
                "y": sumY / sumC,
                "w": sumW / sumC,
                "h": sumH / sumC,
                "conf": min(1.0, sumC / Double(count) * (1.0 + 0.1 * Double(count - 1))),
                "label": bi["label"] as! String
            ])
        }
        return result
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