#if DEBUG && os(macOS)
import SwiftUI
import SceneKit
import Observation
import simd
import Metal
import UniformTypeIdentifiers

@MainActor @Observable
final class LUTVisualizerModel {
    private(set) var lut: SDRLUT?
    var settings = LUTViewerSettings() {
        didSet {
            if settings.density != oldValue.density { requestSamples() }
            else { rebuild() }
        }
    }
    var error: String?
    private(set) var updating = false
    private(set) var saving = false
    @ObservationIgnored private var input: LUTVisualizerInput?
    @ObservationIgnored private var worker: RAWDeveloper?
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    var pointCount = 0
    var clippedCount = 0
    @ObservationIgnored let scene = SCNScene()
    @ObservationIgnored let camera = SCNNode()
    @ObservationIgnored private let cloud = SCNNode()
    @ObservationIgnored private let content = SCNNode()
    @ObservationIgnored private var lastSettings: LUTViewerSettings?
    @ObservationIgnored private var gpu: LUTPointCloud?
    @ObservationIgnored private var viewport = CGSize(width: 700, height: 700)
    @ObservationIgnored private var displayScale: CGFloat = 2
    @ObservationIgnored private var pointNode: SCNNode?
    @ObservationIgnored private weak var sceneView: SCNView?
    @ObservationIgnored private let initialPosition = SIMD3<Float>(1.6, 1.2, 1.8)
    @ObservationIgnored private var initialFieldOfView: CGFloat = 60
    @ObservationIgnored private var initialOrthographicScale = 1.0


    init() {
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 100
        camera.camera?.automaticallyAdjustsZRange = false
        initialFieldOfView = camera.camera!.fieldOfView
        initialOrthographicScale = camera.camera!.orthographicScale
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(content)
        content.addChildNode(cloud)
        addFrame()
        camera.simdPosition = initialPosition
        camera.look(at: SCNVector3Zero)
        do { gpu = try LUTPointCloud() }
        catch { self.error = error.localizedDescription }
    }

    func attach(_ view: SCNView) { sceneView = view }

    func resetZoomAndPan() {
        let controller = sceneView?.defaultCameraController
        controller?.stopInertia()
        // SceneKit creates an interactive point of view when camera control begins.
        let pointOfView = sceneView?.pointOfView ?? camera
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        pointOfView.simdWorldPosition = -pointOfView.simdWorldFront * simd_length(initialPosition)
        pointOfView.camera?.fieldOfView = initialFieldOfView
        pointOfView.camera?.orthographicScale = initialOrthographicScale
        controller?.target = SCNVector3Zero
        SCNTransaction.commit()
    }

    func update(_ input: LUTVisualizerInput) {
        guard self.input != input else { return }
        if worker == nil || self.input?.colorSpace != input.colorSpace {
            worker = RAWDeveloper(colorSpace: input.colorSpace)
        }
        self.input = input
        requestSamples()
    }

    private func requestSamples() {
        sampling?.cancel()
        guard let input, let worker, gpu != nil else { return }
        let token = UUID()
        generation = token
        let dimension = Int(settings.density)
        updating = true
        error = nil
        sampling = Task { [weak self] in
            do {
                await worker.useLUTConfiguration(input.configuration)
                try Task.checkCancellation()
                let result = try await worker.sampleSDRLUT(mapping: input.mapping, dimension: dimension)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                try self.gpu?.setLUT(result)
                self.lut = result
                self.rebuild(force: true)
                self.updating = false
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == token else { return }
                self.lut = nil
                self.error = error.localizedDescription
                self.updating = false
            }
        }
    }

    func stop() {
        sampling?.cancel()
        sampling = nil
        generation = UUID()
    }

    func output(_ input: SIMD3<Float>) -> SIMD3<Float> { lut?.sample(input) ?? input }

    func save(in window: NSWindow?) {
        guard let lut, !updating, !saving else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.nameFieldStringValue = "Dark Melon Look.cube"
        panel.title = String(localized: "Export SDR LUT")
        panel.message = "\(lut.dimension) × \(lut.dimension) × \(lut.dimension) · sRGB input and output"
        panel.canCreateDirectories = true
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.saving = true
            Task {
                defer { self.saving = false }
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try lut.encoded() }.value
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try data.write(to: url, options: .atomic)
                } catch { self.error = error.localizedDescription }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }

    func rebuild(force: Bool = false) {
        let old = lastSettings
        lastSettings = settings
        if old?.background != settings.background {
            scene.background.contents = NSColor(white: CGFloat(settings.background), alpha: 1)
        }
        if old?.autoRotate != settings.autoRotate {
            if settings.autoRotate {
                content.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 40)), forKey: "spin")
            } else { content.removeAction(forKey: "spin") }
        }
        if old?.pointSize != settings.pointSize || old?.opacity != settings.opacity { updatePointAppearance() }
        if !force, var old {
            old.background = settings.background
            old.autoRotate = settings.autoRotate
            old.showRamp = settings.showRamp
            old.pointSize = settings.pointSize
            old.opacity = settings.opacity
            if old == settings { return }
        }
        guard let gpu, lut?.dimension == Int(settings.density) else { return }
        do {
            apply(try gpu.generate(settings))
        } catch { self.error = error.localizedDescription }
    }

    func updateViewport(_ size: CGSize, scale: CGFloat) {
        viewport = size
        displayScale = scale
        updatePointAppearance()
    }

    private func updatePointAppearance() {
        guard let node = pointNode, let element = node.geometry?.elements.first else { return }
        let radius = CGFloat(settings.pointRadius(shortEdge: Double(min(viewport.width, viewport.height)), scale: Double(displayScale)))
        // SceneKit's screen-space point limits are in pixels; account for backing scale.
        element.pointSize = radius
        element.minimumPointScreenSpaceRadius = radius
        element.maximumPointScreenSpaceRadius = radius
        node.opacity = CGFloat(settings.opacity)
    }

    private func apply(_ data: LUTPointCloud.Result) {
        func geometry(positions: MTLBuffer, colors: MTLBuffer? = nil,
                      count: Int, type: SCNGeometryPrimitiveType) -> SCNGeometry {
            var sources = [SCNGeometrySource(buffer: positions, vertexFormat: .float3,
                                              semantic: .vertex, vertexCount: count, dataOffset: 0, dataStride: 16)]
            if let colors {
                sources.append(SCNGeometrySource(buffer: colors, vertexFormat: .float4,
                                                  semantic: .color, vertexCount: count, dataOffset: 0, dataStride: 16))
            }
            let element = SCNGeometryElement(data: nil, primitiveType: type,
                                            primitiveCount: type == .line ? count / 2 : count, bytesPerIndex: 0)
            let result = SCNGeometry(sources: sources, elements: [element])
            // GPU sources have no CPU-side bounds. Cover every supported output coordinate,
            // while excluding the off-screen sentinel used for filtered points.
            result.boundingBox = (SCNVector3(-10.5, -10.5, -10.5), SCNVector3(10.5, 10.5, 10.5))
            return result
        }
        cloud.childNodes.forEach { $0.removeFromParentNode() }
        let points = geometry(positions: data.positions, colors: data.colors, count: data.sampleCount, type: .point)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        points.materials = [material]
        let node = SCNNode(geometry: points)
        cloud.addChildNode(node)
        pointNode = node
        if let vectors = data.vectors {
            let lines = geometry(positions: vectors, count: data.sampleCount * 2, type: .line)
            lines.materials = [lineMaterial(white: 0.6, alpha: 0.25)]
            cloud.addChildNode(SCNNode(geometry: lines))
        }
        updatePointAppearance()
        pointCount = data.visibleCount
        clippedCount = data.clippedCount
    }

    private func position(_ p: SIMD3<Float>) -> SCNVector3 {
        // Keep pathological file values within a finite drawable range; values remain intact in the LUT.
        let v = simd_clamp(p, SIMD3(repeating: -10), SIMD3(repeating: 10)) - SIMD3(repeating: 0.5)
        return SCNVector3(v.x, v.y, v.z)
    }

    private func lineNode(_ vertices: [SCNVector3], white: CGFloat, alpha: CGFloat) -> SCNNode {
        let element = SCNGeometryElement(indices: (0..<vertices.count).map { UInt32($0) }, primitiveType: .line)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
        geometry.materials = [lineMaterial(white: white, alpha: alpha)]
        return SCNNode(geometry: geometry)
    }

    private func lineMaterial(white: CGFloat, alpha: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(white: white, alpha: alpha)
        return material
    }

    private func addFrame() {
        var lines = [SCNVector3]()
        for axis in 0..<3 { for a in 0...1 { for b in 0...1 {
            let others = (0..<3).filter { $0 != axis }
            var p = SIMD3<Float>.zero
            p[others[0]] = Float(a); p[others[1]] = Float(b)
            lines.append(position(p))
            p[axis] = 1
            lines.append(position(p))
        } } }
        content.addChildNode(lineNode(lines, white: 0.5, alpha: 0.5))
        for (label, point) in [("R", SIMD3<Float>(1.12, 0, 0)), ("G", SIMD3<Float>(0, 1.12, 0)), ("B", SIMD3<Float>(0, 0, 1.12))] {
            let text = SCNText(string: label, extrusionDepth: 0)
            text.flatness = 0.2
            let node = SCNNode(geometry: text)
            node.scale = SCNVector3(0.0035, 0.0035, 0.0035)
            node.position = position(point)
            node.constraints = [SCNBillboardConstraint()]
            content.addChildNode(node)
        }
    }
}

#endif
