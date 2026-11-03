import Foundation

/// Admission estimates, not a hard cap on Core Image/codec allocations.
nonisolated enum BatchExportBudget {
    static func bytes(pixels: Double, scale: Double) -> UInt64 {
        // Source decode plus simultaneous SDR/HDR renders, gain map and encoder scratch.
        let estimate = 256 * 1_048_576 + pixels * (48 + 80 * scale * scale)
        return UInt64(min(Double(UInt64.max / 2), max(256 * 1_048_576, estimate)))
    }
    static func limit(memory: UInt64) -> UInt64 { memory * 4 / 5 }
    struct Allocation {
        let parallelism: Int
        let megabytesPerFile: Int
    }
    static func allocation(costs: [UInt64], cpuCount: Int, budget: UInt64) -> Allocation {
        // Fix the divisor for a run, so overlapping jobs never each assume they own
        // the budget. Use the largest image estimate to keep every slot admissible.
        let memorySlots = max(1, Int(budget / max(1, costs.max() ?? 1)))
        let slots = max(1, min(max(1, cpuCount), max(1, costs.count), memorySlots))
        return Allocation(parallelism: slots,
                          megabytesPerFile: max(1, Int(budget / UInt64(slots) / 1_048_576)))
    }
    static var singleFileMegabytes: Int {
        max(1, Int(limit(memory: ProcessInfo.processInfo.physicalMemory) / 1_048_576))
    }
    static func admits(cost: UInt64, reserved: UInt64, active: Int, cpuLimit: Int,
                       budget: UInt64, pressured: Bool) -> Bool {
        // An oversized image can still make progress, but runs alone.
        if active == 0 { return true }
        return !pressured && active < cpuLimit && cost <= budget && reserved <= budget - cost
    }
}
