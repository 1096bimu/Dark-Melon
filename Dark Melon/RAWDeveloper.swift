import CoreImage
import Foundation
import ImageIO
import CoreVideo
import UniformTypeIdentifiers

nonisolated struct RAWDevelopment: @unchecked Sendable {
    let id = UUID()
    let preview: CGImage
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
    let sdr: CGImage
    let hdr: CGImage
}

actor RAWDeveloper {
    private let colorSpace: ProcessingColorSpace
    private var linearSpace: CGColorSpace { colorSpace.linear }

    private let rawSettings: RAWSettings?
    private let rawWhiteBalance: RAWWhiteBalance?

    init(colorSpace: ProcessingColorSpace = .sRGB, rawSettings: RAWSettings? = nil, rawWhiteBalance: RAWWhiteBalance? = nil) {
        self.rawSettings = rawSettings
        self.rawWhiteBalance = rawWhiteBalance
        self.colorSpace = colorSpace
    }
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])

    private var filmGrain: FilmGrain?

    private lazy var hdfKernel = CIColorKernel(source: """
        kernel vec4 hdfAdd(__sample pixel, __sample blurred, float amount, float ceiling) {
            vec4 p = unpremultiply(pixel);
            vec3 glow = unpremultiply(blurred).rgb;
            return premultiply(vec4(clamp(p.rgb + amount * glow, 0.0, ceiling), p.a));
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

    private lazy var hlsKernel = CIColorKernel(source: HLSPixelKernel.source)

    private lazy var colorKernel = CIColorKernel(source: ColorPixelKernel.source)

    private lazy var toneKernel = CIKernel(source: """
        kernel vec4 toneMap(sampler source, sampler table, float black, float span,
                            float lastIndex) {
            vec4 pixel = unpremultiply(sample(source, samplerCoord(source)));
            vec3 t = (pixel.rgb - vec3(black)) / span;
            vec3 u = clamp(t, 0.0, 1.0) * lastIndex + vec3(0.5);
            vec3 mapped = vec3(
                sample(table, samplerTransform(table, vec2(u.r, 0.5))).r,
                sample(table, samplerTransform(table, vec2(u.g, 0.5))).r,
                sample(table, samplerTransform(table, vec2(u.b, 0.5))).r);
            return premultiply(vec4(mapped, pixel.a));
        }
        """)

    func previews(_ source: CGImage, mapping: ToneMapping) throws -> PreviewImages {
        let sdr = try preview(source, mapping: mapping, hdr: false)
        let hdr = mapping.hdrEnabled ? try preview(source, mapping: mapping, hdr: true) : sdr
        try Task.checkCancellation()
        return PreviewImages(sdr: sdr, hdr: hdr)
    }

    func preview(_ source: CGImage, mapping: ToneMapping, hdr: Bool = true) throws -> CGImage {
        try Task.checkCancellation()
        let mapped = try mappedImage(CIImage(cgImage: source), mapping: mapping, hdr: hdr)
        return try displayPreview(mapped, hdr: hdr, headroom: mapping.hdrMax)
    }

    /// Average a circular region of the unedited linear preview, at at most 256 pixels across.
    private func sampleMean(_ source: CGImage, center: CGPoint, radius: CGFloat) throws -> SIMD3<Double> {
        let image = CIImage(cgImage: source)
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
        var automatic = ToneMapping()
        guard development.isRAW else {
            automatic.concentration = 0
            automatic.hdrConcentrationOffset = 0
            if development.sourceHeadroom <= 1 { automatic.hdrMax = 1 }
            return automatic
        }
        let sourceHistogram: HistogramData
        if let histogram { sourceHistogram = histogram }
        else {
            sourceHistogram = try await buildHistogram(development.url, sourceID: development.id, bins: bins)
        }
        if let white = sourceHistogram.overlapWhitePoint {
            automatic.white = min(1, max(automatic.black + ToneMapping.minimumRange, white))
        }
        let image = try preview(development.preview, mapping: automatic, hdr: false)
        let gpu = try GPUHistogram(colorSpace: colorSpace, encoded: true)
        let result = try await gpu.calculate(image: CIImage(cgImage: image), sourceID: UUID(), bins: 256)
        try Task.checkCancellation()
        if let statistics = SDRStatistics(counts: result.sdrLuma),
           let contrast = AutoContrast.suggestion(median: statistics.median, mapping: automatic, space: colorSpace) {
            automatic.setContrastPreservingHDR(contrast)
        }
        automatic.setAutomaticHDRGain()
        return automatic
    }

    func sampleWhiteBalance(_ source: CGImage, center: CGPoint, radius: CGFloat) throws -> WhiteBalance {
        let mean = try sampleMean(source, center: center, radius: radius)
        guard min(mean.x, mean.y, mean.z) > 1e-6 else { throw DevelopmentError.decode }
        let inverse = SIMD3(1 / mean.x, 1 / mean.y, 1 / mean.z)
        let weights = colorSpace.luminance
        let normalization = inverse.x * weights.x + inverse.y * weights.y + inverse.z * weights.z
        return WhiteBalance(red: inverse.x / normalization, green: inverse.y / normalization, blue: inverse.z / normalization)
    }

    /// Shared input domain for tone mapping and the temporary Tone locator.
    private func toneInput(_ image: CIImage, mapping: ToneMapping) throws -> CIImage {
        let gains = mapping.blackAndWhite.isEnabled ? WhiteBalance() : mapping.whiteBalance
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
                                float position, float width) {
            vec3 rgb = unpremultiply(sourcePixel).rgb;
            float distance = abs(dot(rgb, weights) - position);
            float mask = 1.0 - smoothstep(width * 0.35, width, distance);
            vec4 base = unpremultiply(preview);
            return premultiply(vec4(mix(base.rgb, vec3(1.0, 0.0, 0.65), mask * 0.9), base.a));
        }
        """)

    /// One GPU composite over the cached preview; never enters the export or analysis pipeline.
    func toneLocator(_ source: CGImage, preview: CGImage, mapping: ToneMapping, hdr: Bool) throws -> CGImage {
        try Task.checkCancellation()
        let input = try toneInput(CIImage(cgImage: source), mapping: mapping)
        let weights = colorSpace.luminance
        guard let image = toneLocatorKernel?.apply(extent: input.extent, arguments: [
            input, CIImage(cgImage: preview),
            CIVector(x: weights.x, y: weights.y, z: weights.z),
            mapping.peakPosition, max(0.0001, (mapping.white - mapping.black) * 0.025)
        ]) else { throw DevelopmentError.decode }
        return try displayPreview(image, hdr: hdr, headroom: mapping.hdrMax)
    }

    func mappedImage(_ image: CIImage, mapping: ToneMapping, hdr: Bool) throws -> CIImage {
        try Task.checkCancellation()
        let balanced = try toneInput(image, mapping: mapping)
        var color = mapping.color
        if mapping.blackAndWhite.isEnabled {
            color.saturationStart = 1; color.saturationEnd = 1; color.saturationCurve = 0
            color.luminanceSaturationStart = 1; color.luminanceSaturationEnd = 1; color.luminanceSaturationCurve = 0
        }
        let toned = try applyTone(balanced, curve: mapping.curve(hdr: hdr))
        try Task.checkCancellation()
        let split = color.splitTone
        let hasHLS = !mapping.blackAndWhite.isEnabled && !mapping.hls.allSatisfy(\.isIdentity)
        // All tonal color controls share the SDR black/white points and tone curve.
        let reference = hdr && mapping.hdrEnabled && (!split.isIdentity || hasHLS || !color.isLuminanceSaturationIdentity || mapping.grain.strength > 0)
            ? try applyTone(balanced, curve: mapping.curve(hdr: false)) : toned
        let mapped = try applyHLS(toned, reference: reference, mapping: mapping, hdr: hdr)
        guard !color.isIdentity else { return try applyEffects(mapped, reference: reference, mapping: mapping, hdr: hdr) }
        let start = split.huePoint(at: 0), end = split.huePoint(at: 1)
        let naturalRadius = hypot(split.chordMidpoint.x, split.chordMidpoint.y)
        let radius = (split.midpointRadius ?? naturalRadius).clamped(to: 0...1)
        let middle = split.hueNormal * radius
        let rimWeight = radius > naturalRadius && naturalRadius < 1 - 0.000001
            ? (radius - naturalRadius) / (1 - naturalRadius) : 0
        let amountLimits = BoundedQuadraticCurve.coefficientRange(start: split.shadowAmount, end: split.highlightAmount,
                                                                outputRange: 0...SplitToneSettings.maximumAmount, curvatureScale: 1)
        let saturationLimits = BoundedQuadraticCurve.coefficientRange(
            start: color.saturationStart, end: color.saturationEnd,
            outputRange: 0...2, curvatureScale: 1)
        let luminanceSaturationLimits = BoundedQuadraticCurve.coefficientRange(
            start: color.luminanceSaturationStart, end: color.luminanceSaturationEnd,
            outputRange: 0...2, curvatureScale: 1)
        guard let colored = colorKernel?.apply(extent: mapped.extent, arguments: [
            mapped, reference, hdr && mapping.hdrEnabled ? mapping.hdrMax : 1,
            CIVector(x: color.saturationStart, y: color.saturationEnd,
                     z: color.saturationCurve.clamped(to: saturationLimits)),
            CIVector(x: color.luminanceSaturationStart, y: color.luminanceSaturationEnd,
                     z: color.luminanceSaturationCurve.clamped(to: luminanceSaturationLimits)),
            CIVector(x: start.x, y: start.y, z: end.x, w: end.y),
            CIVector(x: middle.x, y: middle.y), rimWeight,
            CIVector(x: split.shadowAmount, y: split.highlightAmount, z: split.amountCurveA.clamped(to: amountLimits)),
            CIVector(x: colorSpace.luminance.x, y: colorSpace.luminance.y, z: colorSpace.luminance.z)
        ]) else { throw DevelopmentError.decode }
        return try applyEffects(colored, reference: reference, mapping: mapping, hdr: hdr)
    }

    private func applyHLS(_ image: CIImage, reference: CIImage, mapping: ToneMapping, hdr: Bool) throws -> CIImage {
        let controls = mapping.hls
        guard !mapping.blackAndWhite.isEnabled else { return image }
        guard !controls.allSatisfy(\.isIdentity) else { return image }
        let weights = colorSpace.luminance
        var arguments: [Any] = [image, reference, hdr && mapping.hdrEnabled ? mapping.hdrMax : 1,
                                CIVector(x: weights.x, y: weights.y, z: weights.z)]
        arguments += controls.map {
            CIVector(x: $0.shadowHue, y: $0.midtoneHue, z: $0.highlightHue, w: $0.saturation)
        }
        arguments += [CIVector(x: controls[0].lightness, y: controls[1].lightness, z: controls[2].lightness),
                      CIVector(x: controls[3].lightness, y: controls[4].lightness, z: controls[5].lightness)]
        guard let result = hlsKernel?.apply(extent: image.extent, arguments: arguments) else {
            throw DevelopmentError.decode
        }
        return result
    }

    private func applyEffects(_ image: CIImage, reference: CIImage, mapping: ToneMapping, hdr: Bool) throws -> CIImage {
        let clarified = try applyClarity(image, mapping: mapping, hdr: hdr)
        let base = try applyHDF(clarified, mapping: mapping, hdr: hdr)
        guard mapping.grain.strength > 0 else { return base }
        if filmGrain == nil { filmGrain = try FilmGrain() }
        return try filmGrain!.apply(to: base, reference: reference, settings: mapping.grain,
                                   weights: colorSpace.luminance, ceiling: hdr && mapping.hdrEnabled ? mapping.hdrMax : 1)
    }

    private func applyHDF(_ base: CIImage, mapping: ToneMapping, hdr: Bool) throws -> CIImage {
        guard mapping.hdf != 0 else { return base }
        let scale = EffectResolution.scale(shortSide: min(base.extent.width, base.extent.height))
        let radius = min(200, max(50, mapping.hdfRadius)) * scale
        let blurred = base.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: base.extent)
        guard let result = hdfKernel?.apply(extent: base.extent, arguments: [
            base, blurred, min(0.2, max(0, mapping.hdf)), hdr && mapping.hdrEnabled ? mapping.hdrMax : 1
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

    private func applyTone(_ image: CIImage, curve: ToneCurve) throws -> CIImage {
        let pixels = curve.values.flatMap { [Float($0), Float($0), Float($0), Float(1)] }
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
        let bounds = source.extent.integral
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
        guard mapping.hdrEnabled else { return try encodeSDR(sdr, settings: settings) }
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

    func develop(_ url: URL) throws -> RAWDevelopment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let source = try sourceImage(url)
        let image = source.image
        let bounds = image.extent.integral
        let scale = min(1, 2560 / max(bounds.width, bounds.height))
        let previewImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let preview = context.createCGImage(previewImage, from: previewImage.extent,
                                                  format: .RGBAh, colorSpace: linearSpace) else {
            throw DevelopmentError.decode
        }
        let container = CGImageSourceCreateWithURL(url as CFURL, nil)
        let properties = container.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any] ?? [:]
        return RAWDevelopment(preview: preview, url: url, width: Int(bounds.width), height: Int(bounds.height), whitePoint: source.whitePoint, metadata: CameraMetadata(properties: properties), isRAW: source.isRAW, rawDefaults: source.rawDefaults, sourceHeadroom: source.headroom)
    }

    private var gpuHistogram: GPUHistogram?
    private var histogramImage: CIImage?
    private var histogramSourceID: UUID?

    func buildHistogram(_ url: URL, sourceID: UUID, bins: Int) async throws -> HistogramData {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if histogramSourceID != sourceID {
            histogramImage = try sourceImage(url).image
            histogramSourceID = sourceID
        }
        guard let image = histogramImage else { throw DevelopmentError.decode }
        if gpuHistogram == nil { gpuHistogram = try GPUHistogram(colorSpace: colorSpace) }
        return try await gpuHistogram!.calculate(image: image, sourceID: sourceID, bins: bins)
    }

}

private enum DevelopmentError: LocalizedError {
    case unsupported, decode
    var errorDescription: String? {
        switch self {
        case .unsupported: "This image format is not supported by Core Image."
        case .decode: "Core Image could not decode this image."
        }
    }
}
