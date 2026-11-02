import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// The data design for CSV and TSV (r3-a Inspector): a native table with typed columns and the File / Column / Row
/// Inspector, reading rows in pages. All content is invented here.
@MainActor
final class DataRendererTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func render(_ name: String, _ text: String, _ kind: FileKind) async throws -> (RenderedPreview, DataView) {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await DataRenderer().render(url: url, kind: kind, context: RenderContext(appearance: .light, defaultsSuite: "vt-data"))
        return (preview, try XCTUnwrap(preview.view as? DataView))
    }

    private let products = """
    sku\tname\tprice\tstock
    A-100\tLantern\t12.50\t40
    A-101\tKettle\t31.00\t7
    A-102\tCompass\t8.25\t112
    A-103\tHammock\t54.90\t3

    """

    func testRegistryPicksDataForCSV() {
        XCTAssertTrue(RendererRegistry.renderer(for: .csv(delimiter: ",")) is DataRenderer)
    }

    func testTSVColumnsRowsAlignmentAndInspector() async throws {
        let (preview, view) = try await render("products.tsv", products, .csv(delimiter: "\t"))
        let table = view.grid.table
        XCTAssertEqual(table.tableColumns.map(\.title), ["", "sku", "name", "price", "stock"], "row-number gutter, then the columns")
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertEqual(preview.document.fact("headline")?.value, "4 rows × 4 columns")
        if case .text(let source)? = preview.document.views.first { XCTAssertTrue(source.contains("Hammock")) } else { XCTFail("source text view") }

        let price = try XCTUnwrap(table.view(atColumn: 3, row: 0, makeIfNecessary: true) as? DataCell)
        XCTAssertEqual(price.label.stringValue, "12.50")
        XCTAssertEqual(price.label.alignment, .right, "numbers are right-aligned")
        let name = try XCTUnwrap(table.view(atColumn: 2, row: 0, makeIfNecessary: true) as? DataCell)
        XCTAssertEqual(name.label.alignment, .left)
        XCTAssertEqual((table.tableColumns[3].headerCell as? DataHeaderCell)?.quality, false, "every price fits: neutral line")

        let inspector = view.inspector
        XCTAssertEqual(inspector.tab, .file)
        let file = Dictionary(uniqueKeysWithValues: inspector.entries.map { ($0.label, $0.value) })
        XCTAssertEqual(file["Rows"], "4")
        XCTAssertEqual(file["Columns"], "4")
        XCTAssertEqual(file["Delimiter"], "Tab")

        view.grid.selectColumn(2) // price: model columns are 0-based, the table's column 0 is the row-number gutter
        XCTAssertEqual(inspector.tab, .column)
        let column = Dictionary(uniqueKeysWithValues: inspector.entries.map { ($0.label, $0.value) })
        XCTAssertEqual(column["Type"], "Decimal")
        XCTAssertEqual(column["Empty"], "0")
        XCTAssertEqual(column["Distinct"], "4")
        XCTAssertEqual(column["Min"], DataModel.number(8.25))
        XCTAssertEqual(column["Max"], DataModel.number(54.9))

        view.inspector.show(.row(1))
        XCTAssertEqual(inspector.tab, .row)
        XCTAssertEqual(inspector.entries.map(\.label), ["sku", "name", "price", "stock"])
        XCTAssertEqual(inspector.entries.map(\.value), ["A-101", "Kettle", "31.00", "7"])
    }

    func testCSVMisfitTurnsTheQualityLineCaution() async throws {
        var csv = "id,qty,note\n"
        for i in 1...9 { csv += "\(i),\(i + 3),ok\n" }
        csv += "10,two,typo\n"
        let (_, view) = try await render("orders.csv", csv, .csv(delimiter: ","))
        let table = view.grid.table
        XCTAssertEqual(table.tableColumns.map(\.title), ["", "id", "qty", "note"])
        XCTAssertEqual(table.numberOfRows, 10)
        XCTAssertEqual((table.tableColumns[2].headerCell as? DataHeaderCell)?.quality, true, "\"two\" is not an integer")
        let bad = try XCTUnwrap(table.view(atColumn: 2, row: 9, makeIfNecessary: true) as? DataCell)
        XCTAssertTrue(bad.misfit)
        XCTAssertEqual(bad.label.alignment, .right)
    }

    func testLargeFileReadsOnlyTheFirstPage() async throws {
        var text = "n,label,amount\n"
        for i in 0..<20_000 { text += "\(i),item \(i),\(i % 97).5\n" }
        let (preview, view) = try await render("big.csv", text, .csv(delimiter: ","))
        XCTAssertEqual(preview.document.fact("headline")?.value, "20,000 rows × 3 columns", "a file under 8 MB is counted before the first paint")
        let model = try XCTUnwrap(view.grid.model as? DataModel)
        XCTAssertEqual(model.pages.keys.sorted(), [0], "only the first page is loaded at first paint")
        XCTAssertEqual(model.pages[0]?.count, 200)
        await model.waitForIndex()
        XCTAssertEqual(view.grid.table.numberOfRows, 20_000, "the background index grows the row count")
        XCTAssertEqual(model.pages.keys.sorted(), [0], "indexing does not load rows into the grid")
        XCTAssertEqual(model.row(12_345)?[1], "item 12345", "a far row is read through its page")
        XCTAssertEqual(model.pages.keys.sorted(), [0, 12_345 / 200])
    }
}
