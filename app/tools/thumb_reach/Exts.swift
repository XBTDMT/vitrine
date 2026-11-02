import UniformTypeIdentifiers
import Foundation
// For each type identifier on stdin: the preferred filename extension (or nothing).
while let line = readLine() {
    let id = line.trimmingCharacters(in: .whitespaces)
    let ext = UTType(id)?.preferredFilenameExtension ?? UTType(id)?.tags[.filenameExtension]?.first ?? ""
    print("\(id)\t\(ext)")
}
