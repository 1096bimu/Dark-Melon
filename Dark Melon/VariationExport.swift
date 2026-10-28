import Foundation
import CoreGraphics

/// Frozen before execution, so later edits or Brew presses cannot change a job.
nonisolated struct VariationExport: Sendable {
    let grid: Int
    let generations: [DyeMixers.Generation]

    init(grid: Int, strength: Double) {
        self.grid = min(8, max(2, grid))
        let amount = UInt16((min(3, max(0, strength.isFinite ? strength : 1)) / 3 * 65535).rounded())
        generations = (0..<(self.grid * self.grid)).map { _ in
            .init(seed: UInt64.random(in: .min ... .max), strength: amount)
        }
    }

    // Integer boundaries cover every output pixel, including non-divisible sizes.
    func tile(_ index: Int, width: Int, height: Int) -> CGRect {
        let column = index % grid, row = grid - 1 - index / grid
        let x = column * width / grid, y = row * height / grid
        return CGRect(x: x, y: y, width: (column + 1) * width / grid - x,
                      height: (row + 1) * height / grid - y)
    }
}
