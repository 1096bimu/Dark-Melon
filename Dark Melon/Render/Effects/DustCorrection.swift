import Foundation
import CoreImage

/// Geometry is stored in native, top-left source coordinates. Lengths use the shorter edge.
nonisolated struct DustSpot: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var center: CGPoint
    var angle = 0.0
    var length = 0.1
    var radius = 0.01
    var feather = 0.015
    var attenuation = 0.0
    var isValid: Bool {
        [center.x, center.y, angle, length, radius, feather, attenuation].allSatisfy(\.isFinite)
        && (0...1).contains(center.x) && (0...1).contains(center.y)
        && length > 0 && length <= 4 && radius >= 0 && radius <= 2
        && feather >= 0.000001 && feather <= 2 && (0...0.95).contains(attenuation)
    }
    static func falloff(_ distance: Double, radius: Double, feather: Double) -> Double {
        let u = min(1, max(0, (distance - radius) / max(0.000001, feather)))
        return 1 - u * u * u * (10 + u * (-15 + 6 * u))
    }
    func transmission(_ distance: Double) -> Double {
        1 - attenuation * Self.falloff(distance, radius: radius, feather: feather)
    }
}

nonisolated struct DustGeometry: Equatable, Sendable {
    var exif: Int32 = 1
    var orientation = SourceOrientation()
    private func oriented(_ p: CGPoint, _ value: Int32) -> CGPoint {
        switch value {
        case 2: CGPoint(x: 1-p.x, y: p.y)
        case 3: CGPoint(x: 1-p.x, y: 1-p.y)
        case 4: CGPoint(x: p.x, y: 1-p.y)
        case 5: CGPoint(x: p.y, y: p.x)
        case 6: CGPoint(x: 1-p.y, y: p.x)
        case 7: CGPoint(x: 1-p.y, y: 1-p.x)
        case 8: CGPoint(x: p.y, y: 1-p.x)
        default: p
        }
    }
    func display(_ native: CGPoint) -> CGPoint {
        var p = oriented(native, exif)
        p = oriented(p, [1,6,3,8][orientation.turns])
        if orientation.mirrored { p.x = 1-p.x }
        return p
    }
    func native(_ display: CGPoint) -> CGPoint {
        var p = display
        if orientation.mirrored { p.x = 1-p.x }
        p = oriented(p, [1,8,3,6][orientation.turns])
        return oriented(p, exif == 6 ? 8 : exif == 8 ? 6 : exif)
    }
    func nativeSize(_ display: CGSize) -> CGSize {
        ((exif >= 5) != (orientation.turns % 2 == 1)) ? CGSize(width: display.height, height: display.width) : display
    }
}

/// The tiny parameter image is a packed list, not a rasterized correction map.
/// Every output pixel evaluates all radial masks analytically in one GPU pass.
nonisolated final class DustCorrection {
    private let kernel = MetalImageKernels.general("dustCorrection")
    private var cached: (spots: [DustSpot], geometry: DustGeometry, image: CIImage)?
    func apply(_ source: CIImage, spots: [DustSpot], geometry: DustGeometry) throws -> CIImage {
        let active = spots.filter { $0.attenuation > 0 && $0.isValid }
        guard !active.isEmpty else { return source }
        let parameters: CIImage
        if let cached, cached.spots == active, cached.geometry == geometry { parameters = cached.image }
        else {
            var values = [Float]()
            for spot in active {
                let p = geometry.display(spot.center)
                values += [Float(p.x), Float(p.y), Float(spot.radius), Float(spot.feather), Float(spot.attenuation), 0, 0, 0]
            }
            let data = values.withUnsafeBytes { Data($0) }
            parameters = CIImage(bitmapData: data, bytesPerRow: active.count * 32,
                size: CGSize(width: active.count * 2, height: 1), format: .RGBAf, colorSpace: nil)
            cached = (active, geometry, parameters)
        }
        let e = source.extent
        guard let image = kernel?.apply(extent: e, roiCallback: { index, rect in
            index == 0 ? rect : parameters.extent
        }, arguments: [source, parameters, active.count,
                       CIVector(x: e.minX, y: e.minY, z: e.width, w: e.height)]) else {
            throw DustFailure.kernel
        }
        return image
    }
}

nonisolated enum DustFailure: LocalizedError {
    case kernel, fit, source
    var errorDescription: String? {
        switch self {
        case .kernel: String(localized: "Unable to render dust correction.")
        case .fit: String(localized: "Could not fit this spot. Extend both ends into clean background or reposition the line.")
        case .source: String(localized: "The dust sampling line must stay inside the image.")
        }
    }
}

nonisolated struct DustProfile: Sendable {
    var values: [Double]
    var stripWidth: Double
    var background: [Double] = []
}

nonisolated enum DustFitter {
    /// Deterministic bounded coordinate search; background is solved analytically for each mask.
    static func fit(_ profile: DustProfile, spot: DustSpot, nativeSize: CGSize) throws -> (DustSpot, DustProfile) {
        let y = profile.values, n = y.count
        guard n >= 32, y.allSatisfy(\.isFinite) else { throw DustFailure.fit }
        let scale = max(1e-12, y.reduce(0,+) / Double(n))
        guard scale > 1e-8 else { throw DustFailure.fit }
        let xs = (0..<n).map { (Double($0) / Double(n-1) - 0.5) * spot.length }
        let end = max(4, n/5)
        let left = y.prefix(end).reduce(0,+) / Double(end), right = y.suffix(end).reduce(0,+) / Double(end)
        let slope = (right-left)/(0.8*spot.length)
        let baseline = xs.map { max(scale*0.01, (left+right)/2 + slope*$0) }
        let residual = zip(y,baseline).map { 1-$0/$1 }
        let index = residual.indices.max(by: { residual[$0] < residual[$1] })!
        let limit = spot.length * 0.4
        // c, radius, feather, attenuation.
        var p = [min(limit*0.6,max(-limit*0.6,xs[index])), spot.length*0.08, spot.length*0.12,
                 min(0.9,max(0.01,residual[index]))]
        func bounded(_ q: [Double]) -> [Double] {
            var q = q
            q[0] = min(limit*0.75,max(-limit*0.75,q[0]))
            q[1] = min(limit-abs(q[0])-spot.length*0.005,max(0,q[1]))
            q[2] = min(limit-abs(q[0])-q[1],max(spot.length*0.005,q[2]))
            q[3] = min(0.95,max(0,q[3]))
            return q
        }
        func evaluate(_ q: [Double]) -> (Double, Double, Double) {
            var transmissions = [Double]()
            for x in xs {
                var f = 0.0
                for j in -2...2 {
                    f += DustSpot.falloff(hypot(x-q[0],Double(j)*profile.stripWidth/4),radius:q[1],feather:q[2]) / 5
                }
                transmissions.append(1-q[3]*f)
            }
            var aa=0.0, ab=0.0, bb=0.0, ay=0.0, by=0.0
            for i in 0..<n {
                let a=transmissions[i], b=a*xs[i], v=y[i]
                aa+=a*a; ab+=a*b; bb+=b*b; ay+=a*v; by+=b*v
            }
            let det=aa*bb-ab*ab
            guard det>1e-20 else { return (.infinity,0,0) }
            let a=(ay*bb-by*ab)/det, b=(by*aa-ay*ab)/det
            guard a-abs(b)*spot.length/2>0 else { return (.infinity,0,0) }
            var loss=0.0
            for i in 0..<n {
                let r=abs((y[i]-(a+b*xs[i])*transmissions[i])/scale)
                loss += r<0.03 ? r*r : 0.06*r-0.0009
            }
            return (loss/Double(n),a,b)
        }
        p=bounded(p)
        var best=evaluate(p)
        var steps=[spot.length*0.08,spot.length*0.08,spot.length*0.08,0.15]
        for _ in 0..<60 {
            var improved=false
            for axis in 0..<4 {
                for sign in [-1.0,1.0] {
                    var q=p; q[axis]+=sign*steps[axis]; q=bounded(q)
                    let test=evaluate(q)
                    if test.0<best.0 { p=q;best=test;improved=true }
                }
            }
            if !improved { steps=steps.map{$0*0.55} }
        }
        guard p[3]>0.005, best.0<0.0025 else { throw DustFailure.fit }
        var fitted=spot
        let edge=min(nativeSize.width,nativeSize.height)
        fitted.center.x += cos(spot.angle)*p[0]*edge/nativeSize.width
        fitted.center.y += sin(spot.angle)*p[0]*edge/nativeSize.height
        fitted.radius=p[1]; fitted.feather=p[2]; fitted.attenuation=p[3]
        guard fitted.isValid else { throw DustFailure.fit }
        var output=profile
        output.background=xs.map{best.1+best.2*$0}
        return (fitted,output)
    }
}
