// VitrineDetect — the input the Scanner works on. The Engine maps OCR lines to ScanLine;
// this package reads text only; it has no OCR (knowledge/spec/ARCHITECTURE.md §2).

/// One line of recognized text in reading order. `text` is the raw OCR text; the Scanner
/// folds it itself (`ConfusableFold.fold`) and reports ranges valid on both strings.
public struct ScanLine: Sendable, Hashable {
    public let index: Int
    public let text: String

    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}
