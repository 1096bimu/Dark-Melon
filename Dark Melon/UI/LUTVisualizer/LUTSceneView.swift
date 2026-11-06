#if os(macOS)
import SwiftUI
import SceneKit

/// Keep direct access to SceneKit's interactive camera without publishing gesture frames.
struct LUTSceneView: NSViewRepresentable {
    let model: LUTVisualizerModel

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = model.scene
        view.pointOfView = model.camera
        view.allowsCameraControl = true
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        model.attach(view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}
}
#endif
