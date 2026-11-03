import Foundation

// MARK: - ColorComparison

extension ToneMapping {
    /// Preview-only bypasses for the two independently editable Color sections.
    func comparingColor(chromaRange: Bool, color: Bool) -> Self {
        var result = self
        if chromaRange { result.vertexWarp = OKLabVertexWarp.defaults }
        if color { result.color = ColorAdjustments() }
        return result
    }
}

// MARK: - EffectsComparison

extension ToneMapping {
    /// Preview-only bypasses. Keep each section's settings isolated, and leave
    /// the stored recipe untouched for release, undo, saving and export.
    func comparingEffects(crossProcessing: Bool, effects: Bool) -> Self {
        var result = self
        if crossProcessing {
            result.channelContrast = [0, 0, 0]
            result.dyeMixers = DyeMixers()
            result.dyePurity = [1, 1, 1]
        }
        if effects {
            result.clarity = 0
            result.hdf = 0
            result.grain.strength = 0
            result.halation.inputCurve = 0
            result.vignette.amount = 0
            result.badHDR = BadHDRSettings()
        }
        return result
    }
}
