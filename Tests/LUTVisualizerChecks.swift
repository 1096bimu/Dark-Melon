import Foundation
import simd
import Metal
import Observation
import os
import SceneKit
@testable import Dark_Melon

@main struct LUTVisualizerChecks {
    @MainActor static func main() async throws {
        var mapping = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1)
        mapping.white = 0.5
        let worker = RAWDeveloper(colorSpace: .sRGB)
        let lut = try await worker.sampleSDRLUT(mapping: mapping, dimension: 17)
        precondition(lut.values.count == 17 * 17 * 17)
        let cube = try LUTCube(data: lut.encoded())
        precondition(cube.dimension == 17)
        let exported = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for i in lut.values.indices {
            for c in 0..<3 { precondition(abs(exported[i * 4 + c] - lut.values[i][c]) < 0.0000001) }
        }
        let gpu = try LUTPointCloud()
        var clippedLUT = lut
        clippedLUT = SDRLUT(dimension: 17, values: lut.values.map { simd_clamp($0 * 1.5 - 0.1, .zero, .one) })
        try gpu.setLUT(clippedLUT)
        var s = LUTViewerSettings()
        precondition(s.density == 17 && s.pointSize == 0.5)
        s.vectors = true
        func region(_ p: SIMD3<Float>, _ name: String) -> Bool {
            switch name {
            case "R": return p.x >= p.y && p.x >= p.z
            case "G": return p.y >= p.x && p.y >= p.z
            case "B": return p.z >= p.x && p.z >= p.y
            case "C": return p.y >= p.x && p.z >= p.x
            case "M": return p.x >= p.y && p.z >= p.y
            case "Y": return p.x >= p.z && p.y >= p.z
            default: return true
            }
        }
        var checks = 0
        func verify() throws {
            let cloud = try gpu.generate(s)
            let n = Int(s.density)
            let positions = cloud.positions.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            let colors = cloud.colors.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            let vectors = cloud.vectors!.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            let rays: [SIMD3<Float>] = [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1), SIMD3(0,1,1), SIMD3(1,0,1), SIMD3(1,1,0), .one]
            var visible = 0, clippedCount = 0
            for i in 0..<cloud.sampleCount {
                let input: SIMD3<Float>
                if s.neutrals { input = SIMD3(repeating: Float(i) / 64) }
                else if s.mode == .rays { input = rays[i / 65] * (Float(i % 65) / 64) }
                else if s.mode == .slice {
                    var p = SIMD3<Float>.zero
                    let axes = (0..<3).filter { $0 != s.axis }
                    p[s.axis] = s.slice
                    p[axes[0]] = Float(i % n) / Float(n - 1)
                    p[axes[1]] = Float(i / n) / Float(n - 1)
                    input = p
                } else { input = SIMD3(Float(i % n), Float(i / n % n), Float(i / (n * n))) / Float(n - 1) }
                let output = clippedLUT.sample(input)
                let e: Float = 0.5 / 255
                let clipped = (0..<3).contains { (output[$0] <= e && input[$0] > e) || (output[$0] >= 1 - e && input[$0] < 1 - e) }
                let included = region(input, s.region)
                if included && clipped { clippedCount += 1 }
                let shown = included && !(s.clipping == .unclipped && clipped)
                precondition((colors[i].w != 0) == shown)
                if !shown { continue }
                visible += 1
                precondition(simd_length(SIMD3(positions[i].x, positions[i].y, positions[i].z) - (output - 0.5)) < 0.00001)
                precondition(simd_length(SIMD3(vectors[i*2].x, vectors[i*2].y, vectors[i*2].z) - (input - 0.5)) < 0.00001)
                precondition(simd_length(vectors[i*2+1] - positions[i]) < 0.00001)
                var rgb = output
                if s.clipping == .highlight {
                    if clipped {
                        if rgb.max() < 0.05 { rgb = input }
                        rgb /= max(rgb.max(), 0.0001)
                    } else { rgb *= 0.18 }
                }
                precondition(simd_length(SIMD3(colors[i].x, colors[i].y, colors[i].z) - rgb) < 0.00001)
            }
            precondition(cloud.visibleCount == visible && cloud.clippedCount == clippedCount)
            checks += 1
        }
        for mode in LUTViewerSettings.Mode.allCases {
            for clipping in LUTViewerSettings.Clipping.allCases {
                for axis in 0..<3 {
                    s.mode = mode; s.clipping = clipping; s.axis = axis; s.slice = 0.37
                    try verify()
                }
            }
        }
        for name in ["All", "R", "G", "B", "C", "M", "Y"] { s.region = name; try verify() }
        s.neutrals = true; s.region = "All"; try verify()
        let model = LUTVisualizerModel()
        model.update(LUTVisualizerInput(mapping: mapping, colorSpace: .sRGB))
        for i in 0..<20 {
            var edit = mapping; edit.shadowFloor = Double(i)
            model.update(LUTVisualizerInput(mapping: edit, colorSpace: .sRGB))
            model.settings.density = i.isMultiple(of: 2) ? 33 : 17
        }
        func wait() async throws {
            for _ in 0..<500 {
                if !model.updating { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(!model.updating && model.error == nil, model.error ?? "Update timed out")
        }
        try await wait()
        precondition(model.lut?.dimension == 17 && model.pointCount == 4913)
        precondition(abs(model.output(.zero).x - 19.0/255) < 0.0001, "Obsolete transform published")
        let old = model.lut!.values
        model.settings.opacity = 0.4
        model.settings.clipping = .unclipped
        precondition(!model.updating && model.lut!.values == old)
        model.settings.density = 65
        try await wait()
        precondition(model.lut?.dimension == 65 && model.lut?.values.count == 274625)
        let larger = try LUTCube(data: model.lut!.encoded())
        precondition(larger.dimension == 65)
        // LUT and status changes must not invalidate observers of the inspector's settings.
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.settings
        } onChange: { changed.withLock { $0 = true } }
        var edited = mapping; edited.shadowFloor = 27
        model.update(LUTVisualizerInput(mapping: edited, colorSpace: .sRGB))
        try await wait()
        precondition(!changed.withLock { $0 }, "LUT update invalidated inspector settings")
        var spatial = mapping; spatial.grain.strength = 1; spatial.vignette.amount = 1
        precondition(LUTVisualizerInput(mapping: spatial, colorSpace: .sRGB) == LUTVisualizerInput(mapping: mapping, colorSpace: .sRGB))
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        view.scene = model.scene
        let interactiveCamera = model.camera.clone()
        interactiveCamera.camera = model.camera.camera!.copy() as? SCNCamera
        model.scene.rootNode.addChildNode(interactiveCamera)
        view.pointOfView = interactiveCamera
        model.attach(view)
        let initialDistance = simd_length(model.camera.simdWorldPosition)
        let initialFOV = model.camera.camera!.fieldOfView
        let initialScale = model.camera.camera!.orthographicScale
        interactiveCamera.simdOrientation = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        interactiveCamera.simdPosition = SIMD3(3, 2, 8)
        interactiveCamera.camera!.fieldOfView = 35
        interactiveCamera.camera!.orthographicScale = 4
        view.defaultCameraController.target = SCNVector3(1, 2, 3)
        let orientation = interactiveCamera.simdWorldOrientation
        let content = model.scene.rootNode.childNodes.first { $0 !== model.camera && $0 !== interactiveCamera }!
        content.eulerAngles = SCNVector3(0.2, 0.7, -0.1)
        let contentOrientation = content.simdOrientation
        model.settings.autoRotate = true
        model.resetZoomAndPan()
        precondition(abs(simd_dot(orientation.vector, interactiveCamera.simdWorldOrientation.vector)) > 0.99999)
        precondition(abs(simd_length(interactiveCamera.simdWorldPosition) - initialDistance) < 0.00001)
        precondition(simd_length(simd_normalize(-interactiveCamera.simdWorldPosition) - interactiveCamera.simdWorldFront) < 0.00001)
        precondition(interactiveCamera.camera!.fieldOfView == initialFOV && interactiveCamera.camera!.orthographicScale == initialScale)
        precondition(SIMD3<Float>(view.defaultCameraController.target) == .zero)
        precondition(abs(simd_dot(contentOrientation.vector, content.simdOrientation.vector)) > 0.99999)
        precondition(model.settings.autoRotate && content.action(forKey: "spin") != nil)
        model.stop()
        print("PASS: shared 17³ export values, \(checks) GPU geometry/filter/clipping/vector scenarios, latest edit wins, display-only reuse, 65³ export, inspector isolation, spatial exclusions, and zoom/pan reset preserving interactive and automatic rotation")
    }
}
