import Foundation
import simd

/// Maximum chroma in the SDR RGB cube, independent of hue and lightness.
/// OKLab is homogeneous, so a maximum must lie on a face with an RGB channel at 1.
nonisolated enum OKLCHGamut {
    static let maxima: [ProcessingColorSpace: Double] = Dictionary(uniqueKeysWithValues:
        ProcessingColorSpace.allCases.map { space in
            let matrix = ScopeProjection.matrix(.sRGB).inverse * ScopeProjection.matrix(space)
            func chroma(_ rgb: SIMD3<Double>) -> Double {
                let c = matrix * rgb
                let l = cbrt(simd_dot(c, SIMD3(0.4122214708,0.5363325363,0.0514459929)))
                let m = cbrt(simd_dot(c, SIMD3(0.2119034982,0.6806995451,0.1073969566)))
                let s = cbrt(simd_dot(c, SIMD3(0.0883024619,0.2817188376,0.6299787005)))
                return hypot(1.9779984951*l-2.4285922050*m+0.4505937099*s,
                             0.0259040371*l+0.7827717662*m-0.8086757660*s)
            }
            var maximum = 0.0
            for face in 0..<3 {
                let u = (face+1)%3, v = (face+2)%3
                var best = SIMD3<Double>(repeating: 0)
                best[face] = 1
                var value = chroma(best)
                for x in 0...64 { for y in 0...64 {
                    var point = best
                    point[u] = Double(x)/64; point[v] = Double(y)/64
                    let candidate = chroma(point)
                    if candidate > value { value = candidate; best = point }
                } }
                var step = 1.0/64
                for _ in 0..<24 {
                    var improved = false
                    for dx in -1...1 { for dy in -1...1 {
                        var point = best
                        point[u] = min(1,max(0,best[u]+Double(dx)*step))
                        point[v] = min(1,max(0,best[v]+Double(dy)*step))
                        let candidate = chroma(point)
                        if candidate > value { value = candidate; best = point; improved = true }
                    } }
                    if !improved { step *= 0.5 }
                }
                maximum = max(maximum,value)
            }
            return (space, maximum)
        })
}
