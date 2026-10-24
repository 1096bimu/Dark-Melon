import Foundation

/// Admission estimates, not a hard cap on Core Image/codec allocations.
nonisolated enum BatchExportBudget {
    static func bytes(pixels: Double, scale: Double) -> UInt64 {
        // Source decode plus simultaneous SDR/HDR renders, gain map and encoder scratch.
        let estimate = 256 * 1_048_576 + pixels * (48 + 80 * scale * scale)
        return UInt64(min(Double(UInt64.max / 2), max(256 * 1_048_576, estimate)))
    }
    static func limit(memory: UInt64) -> UInt64 { memory * 4 / 5 }
    static func admits(cost: UInt64, reserved: UInt64, active: Int, cpuLimit: Int,
                       budget: UInt64, pressured: Bool) -> Bool {
        // An oversized image can still make progress, but runs alone.
        if active == 0 { return true }
        return !pressured && active < cpuLimit && cost <= budget && reserved <= budget - cost
    }
}
