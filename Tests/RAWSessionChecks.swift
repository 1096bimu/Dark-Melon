import CoreImage
@testable import Dark_Melon

@main struct RAWSessionChecks {
    @MainActor static func main() async throws {
        let legacy = try JSONDecoder().decode(RAWSettings.self,
            from: Data(#"{"values":[],"lensCorrection":false,"highlightRecovery":true}"#.utf8))
        assert(legacy.useRAW9 == nil)
        var raw = RAWSettings(); raw.useRAW9 = true
        let decoded = try JSONDecoder().decode(RAWSettings.self, from: JSONEncoder().encode(raw))
        assert(decoded.useRAW9 == true)
        let sparse = SettingsPasteSelection(items: [.rawDecoder]).applyingRAW(raw, to: nil)!
        assert(sparse.decoderMode == .on && sparse.selectedSwitches == ["decoder"])
        assert(sparse.resolved(using: RAWSettings()).decoderMode == .on)
        let budget: UInt64 = 8 * 1_073_741_824 * 4 / 5
        for count in [1, 2, 50] {
            let result = BatchExportBudget.allocation(costs: Array(repeating: 1_073_741_824, count: count), cpuCount: 8, budget: budget)
            assert(result.parallelism <= min(count, 8))
            assert(UInt64(result.megabytesPerFile * result.parallelism) * 1_048_576 <= budget)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let worker = RAWDeveloper(colorSpace: .displayP3, rawSettings: raw, interactive: true)
        let first = try await worker.develop(url, progressive: true)
        print("RAW 9 support:", first.rawDefaults?.supportsRAW9 == true)
        if first.rawDefaults?.supportsRAW9 == true {
            assert(first.rawDefaults?.supported.contains(.color) == false)
            assert(first.rawDefaults?.supported.contains(.detail) == false)
            assert(first.rawDefaults?.supported.contains(.moire) == false)
        }
        let full = try await worker.prepareFullResolution(first)
        assert(full.fullResolutionReady && full.id == first.id)
        assert(full.linearSource.extent.size == first.linearSource.extent.size)
        raw.values[.exposure] = -1
        await worker.updateRAWSettings(raw, whiteBalance: nil)
        let reused = try await worker.develop(url, progressive: true)
        let freshWorker = RAWDeveloper(colorSpace: .displayP3, rawSettings: raw, interactive: true)
        let fresh = try await freshWorker.develop(url, progressive: true)
        let sampler = ScopeHoverSampler()
        for p in [CGPoint(x:0.2,y:0.2), CGPoint(x:0.5,y:0.5), CGPoint(x:0.8,y:0.7)] {
            let a = try await sampler.sampleRGB(reused.preview, revision: reused.id, position: p, space: .displayP3)!
            let b = try await sampler.sampleRGB(fresh.preview, revision: fresh.id, position: p, space: .displayP3)!
            assert(abs(a.x-b.x)+abs(a.y-b.y)+abs(a.z-b.z) < 0.003)
        }
        print("PASS: legacy/new decoder settings, sparse paste, memory allocation, RAW capabilities, reused session matches fresh decode")
    }
}
