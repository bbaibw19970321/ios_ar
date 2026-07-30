import UIKit
import Flutter
import ARKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // 注册 YOLO 插件
        if let registrar = self.registrar(forPlugin: "YoloDetectPlugin") {
            YoloDetectPlugin.register(with: registrar)
        }

        // Hook arkit_plugin：每当 ARKitSceneView 创建时，捕获其 ARSession
        hookARKitSession()

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func hookARKitSession() {
        // arkit_plugin 内部用 ARKitHandlerRegistry 存储 session
        // 我们通过 swizzle ARSCNView 的 init 来捕获
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.findARSession()
        }
    }

    private func findARSession() {
        // 遍历所有 window 找到 ARSCNView
        guard let window = self.window else { return }
        findARSCNView(in: window)
    }

    private func findARSCNView(in view: UIView) {
        if let arView = view as? ARSCNView {
            ARSessionRegistry.shared.register(arView.session)
            print("✅ 捕获到 ARSession")
            return
        }
        for sub in view.subviews {
            findARSCNView(in: sub)
        }
    }
}