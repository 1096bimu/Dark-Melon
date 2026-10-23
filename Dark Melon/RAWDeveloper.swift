import CoreImage
import simd
import Foundation
import ImageIO
import CoreVideo
import UniformTypeIdentifiers

nonisolated struct RAWDevelopment: @unchecked Sendable {
    let id = UUID()
    let preview: CGImage
    let linearSource: CIImage
    let url: URL
    let width: Int
    let height: Int
    let whitePoint: RAWWhitePoint?
    let metadata: CameraMetadata
    let isRAW: Bool
    let rawDefaults: RAWSettings?
    let sourceHeadroom: Double
}

nonisolated struct HistogramData: Sendable {
    let histogram: [[Int]]
    let belowRange: Int
    let aboveRange: Int
    var sdrLuma: [Int]? = nil
    /// White point with 10% of the shared RGB log-height area to its right.
    var overlapWhitePoint: Double? {
        guard histogram.count == 3, let bins = histogram.first?.count, bins > 0,
              histogram.allSatisfy({ $0.count == bins }) else { return nil }
        let heights = (0..<bins).map { index in
            log1p(Double(max(0, min(histogram[0][index], histogram[1][index], histogram[2][index]))))
        }
        let total = heights.reduce(0, +)
        guard total > 0 else { return nil }
        let target = total * 0.9
        var area = 0.0
        for (index, height) in heights.enumerated() {
            if height > 0, area + height >= target {
                // Each drawn bin is flat: interpolate within it for the exact area split.
                return (Double(index) + (target - area) / height) / Double(bins)
            }
            area += height
        }
        return 1
    }
}

nonisolated struct PreviewImages: @unchecked Sendable {
    let source: CGImage
    let sdr: CGImage
    let hdr: CGImage
    let fullSDR: CGImage
    let fullHDR: CGImage
}

actor RAWDeveloper {
    private let colorSpace: ProcessingColorSpace
    private var linearSpace: CGColorSpace { colorSpace.linear }

    private let rawSettings: RAWSettings?
    private let rawWhiteBalance: RAWWhiteBalance?

    init(colorSpace: ProcessingColorSpace = .sRGB, rawSettings: RAWSettings? = nil, rawWhiteBalance: RAWWhiteBalance? = nil, lutStore: LUTStore = .shared) {
        self.rawSettings = rawSettings
        self.rawWhiteBalance = rawWhiteBalance
        self.lutPipeline = LUTPipeline(store: lutStore)
        self.colorSpace = colorSpace
    }
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])

    private let lutPipeline: LUTPipeline
    private var filmGrain: FilmGrain?
    private lazy var halation = Halation()
    private lazy var vignette = Vignette()

    private lazy var hdfKernel = CIColorKernel(source: """
        kernel vec4 hdfAdd(__sample pixel, __sample blurred, float amount) {
            vec4 p = unpremultiply(pixel);
            vec3 glow = unpremultiply(blurred).rgb;
            return premultiply(vec4(max(p.rgb + amount * glow, vec3(0.0)), p.a));
        }
        """)

    // Soft Light: https://www.w3.org/TR/compositing-1/#blendingsoftlight
    private lazy var clarityKernel = CIColorKernel(source: """
        kernel vec4 clarityAdjust(__sample pixel, __sample blurred, float amount, float ceiling) {
            vec4 p = unpremultiply(pixel);
            vec3 base = clamp(p.rgb / ceiling, 0.0, 1.0);
            vec3 low = unpremultiply(blurred).rgb / ceiling;
            vec3 highPass = clamp(vec3(0.5) + base - low, 0.0, 1.0);
            if (amount < 0.0) { highPass = 1.0 - highPass; }
            vec3 d = mix(((16.0 * base - 12.0) * base + 4.0) * base,
                         sqrt(base), step(vec3(0.25), base));
            vec3 darken = base - (1.0 - 2.0 * highPass) * base * (1.0 - base);
            vec3 lighten = base + (2.0 * highPass - 1.0) * (d - base);
            vec3 blended = mix(darken, lighten, step(vec3(0.5), highPass));
            vec3 result = clamp(mix(base, blended, clamp(abs(amount), 0.0, 2.0)), 0.0, 1.0);
            return premultiply(vec4(result * ceiling, p.a));
        }
        """)

    private lazy var monochromeKernel = CIColorKernel(source: MonochromeKernel.source)


    private lazy var colorPipeline = OKLabColorPipeline()

    private lazy var toneKernel = CIKernel(source: """
        kernel vec4 toneMap(sampler source, sampler table, float black, float span,
                            float lastIndex) {
            vec4 pixel = unpremultiply(sample(source, samplerCoord(source)));
            vec3 t = (pixel.rgb - vec3(black)) / span;
            vec3 u = clamp(t, 0.0, 1.0) * lastIndex + vec3(0.5);
            vec3 mapped = vec3(
                sample(table, samplerTransform(table, vec2(u.r, 0.5))).r,
                sample(table, samplerTransform(table, vec2(u.g, 0.5))).g,
                sample(table, samplerTransform(table, vec2(u.b, 0.5))).b);
            return premultiply(vec4(mapped, pixel.a));
        }
        """)

    private var overviewCache: (UUID, CGSize, CGImage)?

    func overview(_ development: RAWDevelopment, canvas: CGSize) throws -> CGImage {
        try Task.checkCancellation()
        let source = development.linearSource
        let scale = PreviewResolution.overviewScale(source: source.extent.size, canvas: canvas)
        let size = CGSize(width: floor(source.extent.width * scale), height: floor(source.extent.height * scale))
        if let cached = overviewCache, cached.0 == development.id, cached.1 == size { return cached.2 }
        let access = development.url.startAccessingSecurityScopedResource()
        defer { if access { development.url.stopAccessingSecurityScopedResource() } }
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(scaled, from: scaled.extent, format: .RGBAh, colorSpace: linearSpace) else {
            throw DevelopmentError.decode
        }
        try Task.checkCancellation()
        overviewCache = (development.id, size, image)
        return image
    }

    /// Only the final visible rectangle is materialized. The full logical source
    /// extent preserves effect scale, perspective geometry, and blur neighborhoods.
    func detail(_ development: RAWDevelopment, mapping: ToneMapping, hdr: Bool,
                region: PreviewRegion) throws -> PreviewDetail {
        try Task.checkCancellation()
        let access = development.url.startAccessingSecurityScopedResource()
        defer { if access { development.url.stopAccessingSecurityScopedResource() } }
        let output = mapping.transform?.resolution(width: development.width, height: development.height, estimate: .maximum)
            ?? CGSize(width: development.width, height: development.height)
        let scale = PreviewResolution.detailScale(display: region.displayPixels, output: output)
        let source = development.linearSource.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let mapped = try mappedImage(source, mapping: mapping, hdr: hdr)
        let extent = mapped.extent
        let rect = PreviewResolution.renderRect(region: region.rect, extent: extent)
        guard !rect.isEmpty else { throw DevelopmentError.decode }
        try Task.checkCancellation()
        let image = try displayPreview(mapped.cropped(to: rect), hdr: hdr, headroom: mapping.hdrMax)
        return PreviewDetail(image: image,
            rect: CGRect(x: (rect.minX - extent.minX) / extent.width, y: (rect.minY - extent.minY) / extent.height,
                         width: rect.width / extent.width, height: rect.height / extent.height),
            scale: scale, sourceID: development.id, mapping: mapping, hdr: hdr)
    }

    func previews(_ source: CGImage, mapping: ToneMapping) throws -> PreviewImages {
        // Develop without resampling geometry, but retain the committed transform
        // for source-space effects that are anchored to the final crop.
        let input = CIImage(cgImage: source)
        let fullSDR = try displayPreview(developedImage(input, mapping: mapping, hdr: false), hdr: false, headroom: mapping.hdrMax)
        let fullHDR = mapping.hdrEnabled
            ? try displayPreview(developedImage(input, mapping: mapping, hdr: true), hdr: true, headroom: mapping.hdrMax) : fullSDR
        let sdr = try transformedPreview(fullSDR, mapping: mapping, hdr: false)
        let hdr = mapping.hdrEnabled ? try transformedPreview(fullHDR, mapping: mapping, hdr: true) : sdr
        try Task.checkCancellation()
        var overviewMapping = mapping
        overviewMapping.transform = nil
        let lutSDR = try transformedPreview(fullSDR, mapping: overviewMapping, hdr: false)
        let lutHDR = mapping.hdrEnabled ? try transformedPreview(fullHDR, mapping: overviewMapping, hdr: true) : lutSDR
        return PreviewImages(source: source, sdr: sdr, hdr: hdr, fullSDR: lutSDR, fullHDR: lutHDR)
    }

    private func transformedPreview(_ source: CGImage, mapping: ToneMapping, hdr: Bool) throws -> CGImage {
        guard mapping.transform != nil || mapping.lutID != nil else { return source }
        let input = CIImage(cgImage: source)
        let transformed = try mapping.transform?.apply(to: input) ?? input
        return try displayPreview(lutPipeline.apply(transformed, id: mapping.lutID), hdr: hdr, headroom: mapping.hdrMax)
    }

    func preview(_ source: CGImage, mapping: ToneMapping, hdr: Bool = true) throws -> CGImage {
        try Task.checkCancellation()
        let mapped = try mappedImage(CIImage(cgImage: source), mapping: mapping, hdr: hdr)
        return try displayPreview(mapped, hdr: hdr, headroom: mapping.hdrMax)
    }

    /// Average a circular region at at most 256 pixels across.
    private func sampleMean(_ image: CIImage, center: CGPoint, radius: CGFloat) throws -> SIMD3<Double> {
        let r = radius * image.extent.width
        guard r > 0 else { throw DevelopmentError.decode }
        let point = CGPoint(x: center.x * image.extent.width, y: center.y * image.extent.height)
        let crop = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
            .intersection(image.extent).integral
        guard !crop.isEmpty else { throw DevelopmentError.decode }
        let scale = min(1, 256 / max(crop.width, crop.height))
        let sampled = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(crop.width * scale)), height = max(1, Int(crop.height * scale))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context.render(sampled, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: linearSpace)
        }
        var sum = SIMD3<Double>.zero
        var weight = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let dx = (CGFloat(x) + 0.5) / scale + crop.minX - point.x
                let dy = (CGFloat(y) + 0.5) / scale + crop.minY - point.y
                guard dx * dx + dy * dy <= r * r else { continue }
                let i = (y * width + x) * 4
                let alpha = Double(pixels[i + 3])
                let rgb = SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                guard alpha > 0, rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else { continue }
                sum += rgb
                weight += alpha
            }
        }
        try Task.checkCancellation()
        guard weight > 0 else { throw DevelopmentError.decode }
        return sum / weight
    }

    /// Same defaults used by Reset Tone and file-browser exports without saved edits.
    func automaticMapping(for development: RAWDevelopment, bins: Int,
                          histogram: HistogramData? = nil) async throws -> ToneMapping {
        ToneMapping.fresh(isRAW: development.isRAW, sourceHeadroom: development.sourceHeadroom)
    }

    func sampleWhiteBalance(_ source: CGImage, center: CGPoint, radius: CGFloat, mapping: ToneMapping) throws -> WhiteBalance {
        let input = try adjustedInput(CIImage(cgImage: source), mapping: mapping)
        let toned = try applyTone(input, curves: mapping.channelCurves(hdr: false))
        let mean = try sampleMean(toned, center: center, radius: radius)
        guard min(mean.x, mean.y, mean.z) > 1e-6 else { throw DevelopmentError.decode }
        let inverse = SIMD3(1 / mean.x, 1 / mean.y, 1 / mean.z)
        let weights = colorSpace.luminance
        let normalization = inverse.x * weights.x + inverse.y * weights.y + inverse.z * weights.z
        return WhiteBalance(red: inverse.x / normalization, green: inverse.y / normalization, blue: inverse.z / normalization)
    }

    /// RGB white balance and monochrome conversion follow tone and spatial effects.
    private func applyWhiteBalance(_ image: CIImage, mapping: ToneMapping) throws -> CIImage {
        let gains = (mapping.blackAndWhite.isEnabled || mapping.color.monochrome) ? WhiteBalance() : mapping.whiteBalance
        var balanced = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gains.red, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gains.green, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gains.blue, w: 0)
        ])
        if mapping.blackAndWhite.isEnabled {
            let bw = mapping.blackAndWhite, weights = colorSpace.luminance
            guard let gray = monochromeKernel?.apply(extent: balanced.extent, arguments: [
                balanced, CIVector(x: weights.x,y: weights.y,z: weights.z),
                CIVector(x: bw.red,y: bw.yellow,z: bw.green), CIVector(x: bw.cyan,y: bw.blue)
            ]) else { throw DevelopmentError.decode }
            balanced = gray
        }
        return balanced
    }

    private let toneLocatorKernel = CIColorKernel(source: """
        kernel vec4 toneLocator(__sample sourcePixel, __sample preview, vec3 weights,
                                float position, float width, float clipping) {
            vec3 rgb = unpremultiply(sourcePixel).rgb;
            float distance = abs(dot(rgb, weights) - position);
            float mask = 1.0 - smoothstep(width * 0.35, width, distance);
            if (clipping > 0.5) { mask = step(position, max(rgb.r, max(rgb.g, rgb.b))); }
            vec3 highlight = clipping > 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.21404114);
            vec4 base = unpremultiply(preview);
            return premultiply(vec4(mix(base.rgb, highlight, mask * 0.9), base.a));
        }
        """)

    /// One GPU composite over the cached preview; never enters the export or analysis pipeline.
    func toneLocator(_ source: CGImage, preview: CGImage, mapping: ToneMapping, hdr: Bool, clipping: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        let input = try adjustedInput(CIImage(cgImage: source), mapping: mapping)
        let weights = colorSpace.luminance
        guard let image = toneLocatorKernel?.apply(extent: input.extent, arguments: [
            input, CIImage(cgImage: preview),
            CIVector(x: weights.x, y: weights.y, z: weights.z),
            clipping ? mapping.white : mapping.peakPosition, max(0.0001, mapping.white * 0.025),
            clipping ? 1.0 : 0.0
        ]) else { throw DevelopmentError.decode }
        return try displayPreview(try mapping.transform?.apply(to: image) ?? image, hdr: hdr, headroom: mapping.hdrMax)
    }

    func mappedImage(_ image: CIImage, mapping: ToneMapping, hdr: Bool) throws -> CIImage {
        let developed = try developedImage(image, mapping: mapping, hdr: hdr)
        let transformed = try mapping.transform?.apply(to: developed) ?? developed
        return try lutPipeline.apply(transformed, id: mapping.lutID)
    }

    private lazy var offsetKernel = CIColorKernel(source: """
        kernel vec4 inputOffset(__sample pixel, float offset) {
            // Equal linear-light addition. Bound negative RGB, retain HDR values.
            return vec4(max(pixel.rgb + vec3(offset * pixel.a), vec3(0.0)), pixel.a);
        }
        """)

    private func adjustedInput(_ source: CIImage, mapping: ToneMapping) throws -> CIImage {
        var image = source
        if mapping.offset != 0 {
            guard let adjusted = offsetKernel?.apply(extent: source.extent,
                                                     arguments: [source, mapping.offset]) else {
                throw DevelopmentError.decode
            }
            image = adjusted
        }
        image = try applyHDF(image, mapping: mapping)
        image = try vignette.apply(to: image, settings: mapping.vignette, transform: mapping.transform)
        if mapping.hdrEnabled && mapping.halation.inputCurve > 0 {
            image = try halation.apply(to: image, source: image, settings: mapping.halation,
                                       hdrBrightness: mapping.hdrMax, ceiling: 0, monochrome: mapping.color.monochrome)
        }
        if mapping.grain.strength > 0 {
            if filmGrain == nil { filmGrain = try FilmGrain() }
            image = try filmGrain!.apply(to: image, source: image, settings: mapping.grain,
                                        weights: colorSpace.luminance, ceiling: 0)
        }
        return image
    }

    private func developedImage(_ source: CIImage, mapping: ToneMapping, hdr: Bool) throws -> CIImage {
        try Task.checkCancellation()
        let image = try adjustedInput(source, mapping: mapping)
        var color = mapping.color
        if mapping.blackAndWhite.isEnabled {
            color.saturationStart = 1; color.saturationEnd = 1; color.saturationMid = 1; color.saturationHDR = 1
            color.luminanceSaturationStart = 1; color.luminanceSaturationEnd = 1; color.luminanceSaturationMid = 1; color.luminanceSaturationHDR = 1
        }
        // Shared by preview/export: offset → HDF → vignette → halation → grain → tone → RGB WB → OKLab → clarity.
        // RAW decoder white balance is already part of the decoded source.
        let toned = try applyTone(image, curves: mapping.channelCurves(hdr: hdr))
        let balanced = try applyWhiteBalance(toned, mapping: mapping)
        try Task.checkCancellation()
        let colored = try colorPipeline.apply(balanced, color: color, vertices: mapping.vertexWarp,
            space: colorSpace, ceiling: hdr && mapping.hdrEnabled ? mapping.hdrMax : 1,
            domainCeiling: mapping.hdrMax)
        return try applyClarity(colored, mapping: mapping, hdr: hdr)
    }

    private func applyHDF(_ base: CIImage, mapping: ToneMapping) throws -> CIImage {
        guard mapping.hdf != 0 else { return base }
        let scale = EffectResolution.scale(shortSide: min(base.extent.width, base.extent.height))
        let radius = min(200, max(50, mapping.hdfRadius)) * scale
        // Preserve scene-linear highlight energy before either rendition clips or compresses it.
        let blurred = base.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: base.extent)
        guard let result = hdfKernel?.apply(extent: base.extent, arguments: [
            base, blurred, min(0.2, max(0, mapping.hdf))
        ]) else { throw DevelopmentError.decode }
        return result
    }

    private func applyClarity(_ image: CIImage, mapping: ToneMapping, hdr: Bool) throws -> CIImage {
        guard mapping.clarity != 0 else { return image }
        // Keep existing slider/recipe units: 30 means 60 px at the 4000 px reference.
        let scale = EffectResolution.scale(shortSide: min(image.extent.width, image.extent.height))
        let radius = mapping.clarityRadius * 2 * scale
        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
        guard let result = clarityKernel?.apply(extent: image.extent, arguments: [
            image, blurred, mapping.clarity,
            hdr && mapping.hdrEnabled ? mapping.hdrMax : 1
        ]) else { throw DevelopmentError.decode }
        return result
    }

    private func applyTone(_ image: CIImage, curves: [ToneCurve]) throws -> CIImage {
        let curve = curves[0]
        let pixels = curve.values.indices.flatMap { i in
            [Float(curves[0].values[i]), Float(curves[1].values[i]), Float(curves[2].values[i]), Float(1)]
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let table = CIImage(bitmapData: data, bytesPerRow: pixels.count * 4,
                            size: CGSize(width: curve.values.count, height: 1),
                            format: .RGBAf, colorSpace: nil)
        let tableBounds = table.extent
        guard let mapped = toneKernel?.apply(extent: image.extent, roiCallback: { index, rect in
            index == 1 ? tableBounds : rect
        }, arguments: [image, CISampler(image: table, options: [
            kCISamplerFilterMode: kCISamplerFilterLinear,
            kCISamplerWrapMode: kCISamplerWrapClamp
        ]), curve.black, max(ToneMapping.minimumRange, curve.white - curve.black),
                       curve.values.count - 1]) else {
            throw DevelopmentError.decode
        }
        return mapped
    }

    private func displayPreview(_ image: CIImage, hdr: Bool, headroom: Double) throws -> CGImage {
        // SDR is a separate, bounded bitmap tagged with the selected output space.
        let displayImage = hdr ? image.settingContentHeadroom(Float(headroom)) : image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        let space = hdr ? linearSpace : colorSpace.encoded
        guard let result = context.createCGImage(displayImage, from: image.extent,
                                                 format: hdr ? .RGBAh : .RGBA8,
                                                 colorSpace: space) else {
            throw DevelopmentError.decode
        }
        try Task.checkCancellation()
        return result
    }

    func suggestedColorSpace(for url: URL) throws -> ProcessingColorSpace {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let container = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(container) else { throw DevelopmentError.unsupported }
        // RAW imports start in Display P3; tagged rendered images retain gamut detection.
        if UTType(identifier as String)?.conforms(to: .rawImage) == true { return .displayP3 }
        guard let image = CIImage(contentsOf: url, options: [.expandToHDR: true, .toneMapHDRtoSDR: false]) else {
            throw DevelopmentError.unsupported
        }
        return ProcessingColorSpace.covering(image.colorSpace)
    }

    private func sourceImage(_ url: URL, whiteBalance: RAWWhiteBalance? = nil) throws -> (image: CIImage, headroom: Double, whitePoint: RAWWhitePoint?, isRAW: Bool, rawDefaults: RAWSettings?) {
        let image: CIImage
        var rawDefaults: RAWSettings?
        var headroom = 1.0
        var whitePoint: RAWWhitePoint?
        guard let container = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(container) else { throw DevelopmentError.unsupported }
        let type = UTType(identifier as String)
        let isRAW = type?.conforms(to: .rawImage) == true
        if isRAW {
            guard let raw = CIRAWFilter(imageURL: url) else { throw DevelopmentError.unsupported }
            raw.baselineExposure = 0
            raw.shadowBias = 2
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
            raw.exposure = 0
            rawDefaults = RAWSettings(raw)
            rawSettings?.apply(to: raw)
            (whiteBalance ?? rawWhiteBalance)?.apply(to: raw)
            whitePoint = RAWWhitePoint(chromaticity: raw.neutralChromaticity,
                                       temperature: Double(raw.neutralTemperature), tint: Double(raw.neutralTint))
            raw.boostAmount = 0
            raw.localToneMapAmount = 0
            raw.isGamutMappingEnabled = false
            guard let decoded = raw.outputImage else { throw DevelopmentError.decode }
            image = decoded
        } else {
            // Respect embedded profiles and orientation. Expand supported Apple/ISO
            // gain maps and retain native HDR rather than tone mapping it to SDR.
            guard let decoded = CIImage(contentsOf: url, options: [
                .applyOrientationProperty: true,
                .expandToHDR: true,
                .toneMapHDRtoSDR: false
            ]) else { throw DevelopmentError.unsupported }
            let reported = Double(decoded.contentHeadroom)
            headroom = reported.isFinite ? max(1, reported) : 1
            // The editor's input domain is 0...1. Preserve HDR highlight separation
            // by scaling all linear channels together, identically on every decode.
            let scale = 1 / headroom
            image = decoded.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0)
            ])
        }
        guard !image.extent.isEmpty, !image.extent.isInfinite else { throw DevelopmentError.decode }
        return (image, headroom, whitePoint, isRAW, rawDefaults)
    }

    func exportHEIF(_ url: URL, mapping: ToneMapping, settings: HEIFSettings) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let source = try sourceImage(url, whiteBalance: mapping.rawWhiteBalance).image
        return try exportImage(source, mapping: mapping, settings: settings)
    }

    #if os(macOS)
    /// A synchronous actor operation keeps temporary codec objects scoped to one export.
    func exportBatch(_ url: URL, mapping: ToneMapping, settings: HEIFSettings, destination: URL) throws {
        try autoreleasepool {
            try Task.checkCancellation()
            let data = try exportHEIF(url, mapping: mapping, settings: settings)
            try Task.checkCancellation()
            _ = try BatchExportWriter.write(data, source: url, directory: destination,
                                           extension: settings.format.fileExtension)
        }
    }
    #endif

    private var sizeSource: (url: URL, image: CIImage)?

    /// Used by a sheet-scoped worker: decode once, then measure actual encodes.
    func encodedSize(_ url: URL, mapping: ToneMapping, settings: HEIFSettings) throws -> Int {
        try Task.checkCancellation()
        if sizeSource?.url != url {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let source = try sourceImage(url, whiteBalance: mapping.rawWhiteBalance).image
            guard let rendered = context.createCGImage(source, from: source.extent, format: .RGBAf,
                                                       colorSpace: linearSpace) else { throw HEIFExportError.encoding }
            try Task.checkCancellation()
            sizeSource = (url, CIImage(cgImage: rendered))
        }
        return try exportImage(sizeSource!.image, mapping: mapping, settings: settings).count
    }

    func exportImage(_ source: CIImage, mapping: ToneMapping, settings: HEIFSettings) throws -> Data {
        let sourceBounds = source.extent.integral
        let transformedSize = mapping.transform?.resolution(width: Int(sourceBounds.width), height: Int(sourceBounds.height), estimate: .maximum) ?? sourceBounds.size
        let bounds = CGRect(origin: .zero, size: transformedSize)
        let width = max(1, Int((bounds.width * settings.scale).rounded()))
        let height = max(1, Int((bounds.height * settings.scale).rounded()))
        func resized(_ image: CIImage) -> CIImage {
            image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .transformed(by: CGAffineTransform(scaleX: Double(width) / bounds.width,
                                                  y: Double(height) / bounds.height))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if settings.format == .tiff || (settings.format == .jpeg && (!settings.jpegHDR || !mapping.hdrEnabled)) {
            var image = resized(try mappedImage(source, mapping: mapping,
                hdr: settings.format == .tiff && settings.tiffHDR))
            if settings.format == .tiff && settings.tiffHDR && mapping.hdrEnabled {
                let scale = 1 / mapping.hdrMax
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0)
                ])
            }
            return try encodeStandardImage(image, settings: settings)
        }
        if settings.format == .heif && mapping.hdrEnabled && settings.heifHDRMode == .direct {
            let hdr = resized(try mappedImage(source, mapping: mapping, hdr: true))
                .settingContentHeadroom(Float(mapping.hdrMax))
            try Task.checkCancellation()
            return try context.heif10Representation(of: hdr, colorSpace: colorSpace.pq,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): settings.quality])
        }
        let sdr = resized(try mappedImage(source, mapping: mapping, hdr: false))
        guard mapping.hdrEnabled,
              !(settings.format == .heif && settings.heifHDRMode == .off)
        else { return try encodeSDR(sdr, settings: settings) }
        let hdr = resized(try mappedImage(source, mapping: mapping, hdr: true))
            .settingContentHeadroom(Float(mapping.hdrMax))
        return try encodeHEIF(sdr: sdr, hdr: hdr, settings: settings)
    }

    private func encodeStandardImage(_ image: CIImage, settings: HEIFSettings) throws -> Data {
        try Task.checkCancellation()
        // HDR TIFF is normalized into this range before encoding. Preserve the
        // selected gamut profile while storing a conventional integer SDR image.
        let image = image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        let format: CIFormat = settings.format == .tiff && settings.tiff16Bit ? .RGBA16 : .RGBA8
        guard let base = context.createCGImage(image, from: image.extent, format: format,
                                               colorSpace: colorSpace.encoded) else { throw HEIFExportError.encoding }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,
            settings.format.type.identifier as CFString, 1, nil) else { throw HEIFExportError.encoding }
        let properties: [CFString: Any] = settings.format == .tiff
            ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]
            : [kCGImageDestinationLossyCompressionQuality: settings.quality]
        CGImageDestinationAddImage(destination, base, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HEIFExportError.encoding }
        return data as Data
    }

    private func encodeSDR(_ image: CIImage, settings: HEIFSettings) throws -> Data {
        try Task.checkCancellation()
        guard let base = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                               colorSpace: colorSpace.encoded) else { throw HEIFExportError.encoding }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw HEIFExportError.encoding
        }
        CGImageDestinationAddImage(destination, base, [kCGImageDestinationLossyCompressionQuality: settings.quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HEIFExportError.encoding }
        return data as Data
    }

    private lazy var gainKernel = CIColorKernel(source: """
        kernel vec4 gain(__sample base, __sample alternate, float rgb, vec3 weights) {
            vec3 s = max(unpremultiply(base).rgb, vec3(0.0));
            vec3 h = max(unpremultiply(alternate).rgb, vec3(0.0));
            if (rgb < 0.5) {
                s = vec3(dot(s, weights));
                h = vec3(dot(h, weights));
            }
            return vec4(log2((h + vec3(0.00001)) / (s + vec3(0.00001))), 1.0);
        }
        """)

    func encodeHEIF(sdr: CIImage, hdr: CIImage, settings: HEIFSettings) throws -> Data {
        try Task.checkCancellation()
        let outputSpace = colorSpace.encoded
        let weights = colorSpace.luminance
        let width = Int(sdr.extent.width)
        let height = Int(sdr.extent.height)
        let gainWidth = settings.halfSizeGainMap ? max(1, (width + 1) / 2) : width
        let gainHeight = settings.halfSizeGainMap ? max(1, (height + 1) / 2) : height
        let transform = CGAffineTransform(scaleX: Double(gainWidth) / Double(width),
                                         y: Double(gainHeight) / Double(height))
        guard let logGain = gainKernel?.apply(extent: sdr.extent, arguments: [sdr, hdr, settings.rgbGainMap ? 1.0 : 0.0,
            CIVector(x: weights.x, y: weights.y, z: weights.z)]) else {
            throw HEIFExportError.gainMap
        }
        let gain = logGain.transformed(by: transform)
        func extrema(_ filter: String) -> [Float] {
            let reduced = gain.applyingFilter(filter, parameters: ["inputExtent": CIVector(cgRect: gain.extent)])
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                context.render(reduced, toBitmap: $0.baseAddress!, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            }
            return Array(pixel.prefix(3))
        }
        let minimum = Double(extrema("CIAreaMinimum").min() ?? 0)
        let maximum = max(minimum + 0.0001, Double(extrema("CIAreaMaximum").max() ?? 0))
        guard minimum.isFinite, maximum.isFinite else { throw HEIFExportError.gainMap }
        let multiplier = 1 / (maximum - minimum)
        let encodedGain = gain.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: multiplier, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: multiplier, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: multiplier, w: 0),
            "inputBiasVector": CIVector(x: -minimum * multiplier, y: -minimum * multiplier,
                                        z: -minimum * multiplier, w: 0)
        ])
        let bytesPerRow = gainWidth * (settings.rgbGainMap ? 4 : 1)
        var gainPixels = Data(count: bytesPerRow * gainHeight)
        gainPixels.withUnsafeMutableBytes {
            context.render(encodedGain, toBitmap: $0.baseAddress!, rowBytes: bytesPerRow,
                           bounds: CGRect(x: 0, y: 0, width: gainWidth, height: gainHeight),
                           format: settings.rgbGainMap ? .BGRA8 : .L8, colorSpace: nil)
        }
        let metadata = try HEIFGainMetadata.make(minimum: minimum, maximum: maximum,
                                                headroom: Double(max(1, hdr.contentHeadroom)),
                                                rgb: settings.rgbGainMap)
        let payload: [String: Any] = [
            kCGImageAuxiliaryDataInfoData as String: gainPixels,
            kCGImageAuxiliaryDataInfoDataDescription as String: [
                "Width": gainWidth, "Height": gainHeight, "BytesPerRow": bytesPerRow,
                "PixelFormat": settings.rgbGainMap ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_OneComponent8
            ],
            kCGImageAuxiliaryDataInfoMetadata as String: metadata
        ]
        guard let base = context.createCGImage(sdr, from: sdr.extent, format: .RGBA8, colorSpace: outputSpace) else {
            throw HEIFExportError.gainMap
        }
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, settings.format.type.identifier as CFString, 1, nil) else {
            throw HEIFExportError.encoding
        }
        CGImageDestinationAddImage(destination, base, [
            kCGImageDestinationLossyCompressionQuality: settings.quality
        ] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeISOGainMap, payload as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HEIFExportError.encoding }
        let result = data as Data
        guard let check = CGImageSourceCreateWithData(result as CFData, nil),
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(check, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil else {
            throw HEIFExportError.gainMap
        }
        try Task.checkCancellation()
        return result
    }

    func develop(_ url: URL, previewCanvas: CGSize = CGSize(width: 2560, height: 2560)) throws -> RAWDevelopment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let source = try sourceImage(url)
        let image = source.image
        let bounds = image.extent.integral
        let scale = PreviewResolution.overviewScale(source: bounds.size, canvas: previewCanvas)
        let previewImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let preview = context.createCGImage(previewImage, from: previewImage.extent,
                                                  format: .RGBAh, colorSpace: linearSpace) else {
            throw DevelopmentError.decode
        }
        let container = CGImageSourceCreateWithURL(url as CFURL, nil)
        let properties = container.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any] ?? [:]
        let development = RAWDevelopment(preview: preview, linearSource: image, url: url, width: Int(bounds.width), height: Int(bounds.height), whitePoint: source.whitePoint, metadata: CameraMetadata(properties: properties), isRAW: source.isRAW, rawDefaults: source.rawDefaults, sourceHeadroom: source.headroom)
        overviewCache = (development.id, CGSize(width: floor(image.extent.width * scale), height: floor(image.extent.height * scale)), preview)
        return development
    }

    private var gpuHistogram: GPUHistogram?
    /// Analyze the cached, unmodified linear preview. Never decode a second
    /// full-resolution source or allocate a source-sized histogram texture.
    func buildHistogram(_ development: RAWDevelopment, bins: Int) async throws -> HistogramData {
        if gpuHistogram == nil { gpuHistogram = try GPUHistogram(colorSpace: colorSpace) }
        return try await gpuHistogram!.calculate(image: CIImage(cgImage: development.preview),
                                                  sourceID: development.id, bins: bins)
    }

}

private enum DevelopmentError: LocalizedError {
    case unsupported, decode
    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "This image format is not supported by Core Image.")
        case .decode: String(localized: "Core Image could not decode this image.")
        }
    }
}
