#if os(macOS)
import Foundation

/// Writes exclusively, including when two source files share a basename.
nonisolated enum BatchExportWriter {
    static func write(_ data: Data, source: URL, directory: URL, extension suffix: String) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        var index = 0
        while true {
            try Task.checkCancellation()
            let name = stem + (index == 0 ? "" : "-\(index)") + "." + suffix
            let destination = directory.appendingPathComponent(name)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                index += 1
            }
        }
    }
}


#endif
