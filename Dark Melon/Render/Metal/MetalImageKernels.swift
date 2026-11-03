import CoreImage
import Foundation
import OSLog

/// Shared, build-time compiled Core Image kernels. No runtime source compiler or
/// dynamic-library GPU requirement; the same metallib serves macOS and iOS.
nonisolated enum MetalImageKernels {
    private final class BundleToken: NSObject {}
    private static let logger = Logger(subsystem: "DarkMelon", category: "ImageKernels")
    private static let library: Data? = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "default", withExtension: "metallib") else {
            logger.error("Missing bundled Core Image Metal library")
            return nil
        }
        do { return try Data(contentsOf: url) }
        catch { logger.error("Cannot read Metal library: \(error.localizedDescription)"); return nil }
    }()
    static func color(_ name: String) -> CIColorKernel? {
        guard let library else { return nil }
        do { return try CIColorKernel(functionName: name, fromMetalLibraryData: library) }
        catch { logger.error("Cannot load kernel \(name): \(error.localizedDescription)"); return nil }
    }
    static func general(_ name: String) -> CIKernel? {
        guard let library else { return nil }
        do { return try CIKernel(functionName: name, fromMetalLibraryData: library) }
        catch { logger.error("Cannot load kernel \(name): \(error.localizedDescription)"); return nil }
    }
}
