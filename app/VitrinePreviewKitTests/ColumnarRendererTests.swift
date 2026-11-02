import XCTest
@testable import VitrinePreviewKit
import VitrineData
import VitrineSupport

/// Parquet, Arrow / Feather and xlsx in the data view (B-4, G-20; data design "Parquet / Arrow, footer first"): the
/// same grid, Inspector, filter, sort, Copy as and SQL as CSV and SQLite, from VitrineData's own readers. Every file
/// is invented here by the spec-written test writers. roadmap: S-21
@MainActor
final class ColumnarRendererTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-columnar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func render(_ url: URL) async throws -> (RenderedPreview, DataView, ColumnarDataModel) {
        let kind = FileSniffer.kind(of: url)
        XCTAssertTrue(RendererRegistry.renderer(for: kind) is DataRenderer, "\(kind)")
        let preview = try await DataRenderer().render(url: url, kind: kind, context: RenderContext(appearance: .light, defaultsSuite: "vt-columnar"))
        let view = try XCTUnwrap(preview.view as? DataView)
        return (preview, view, try XCTUnwrap(view.model as? ColumnarDataModel))
    }

    /// 2,500 invented trips in five row groups of 500, pages of 100, Snappy.
    private func trips() throws -> URL {
        let n = 2_500
        let zones = ["Riverside", "Harbour", "University", "Waterfront", "Old Town"]
        let columns = [
            TestParquetColumn(name: "trip_id", physical: .int64, optional: false, values: (0..<n).map { .int(Int64($0 + 1)) }),
            TestParquetColumn(name: "zone", physical: .byteArray, logical: .string, encoding: .dictionary,
                              values: (0..<n).map { $0 % 10 == 9 ? .null : .string(zones[$0 % 5]) }),
            TestParquetColumn(name: "fare", physical: .int32, logical: .decimal(precision: 9, scale: 2), values: (0..<n).map { .int(Int64(500 + $0 % 400)) }),
            TestParquetColumn(name: "day", physical: .int32, logical: .date, values: (0..<n).map { .int(20_697 + Int64($0 / 100)) }),
        ]
        var options = TestParquetOptions()
        options.rowGroupRows = 500
        options.pageRows = 100
        options.codec = 1
        options.createdBy = "parquet-cpp-arrow version 17.0.0"
        return try write("trips-2026-09.parquet", TestParquet.file(columns, options))
    }

    func testParquetOpensWithTheFooterInspector() async throws {
        let (preview, view, model) = try await render(try trips())
        XCTAssertEqual(preview.document.kind, .dataset(.parquet))
        XCTAssertEqual(preview.document.fact("headline")?.value, "2,500 rows · 4 columns")
        XCTAssertEqual(preview.document.viewTitles, ["Table", "Schema"])
        XCTAssertEqual(view.grid.table.tableColumns.map(\.title), ["", "trip_id", "zone", "fare", "day"])
        XCTAssertEqual(view.grid.table.numberOfRows, 2_500)
        XCTAssertFalse(view.inspector.isHidden, "Parquet opens with the Inspector on its footer")
        XCTAssertEqual(view.inspector.tab, .file)
        let entries = Dictionary(uniqueKeysWithValues: view.inspector.entries.map { ($0.label, $0.value) })
        XCTAssertEqual(entries["Rows"], "2,500")
        XCTAssertEqual(entries["Row groups"], "5 × 500")
        XCTAssertEqual(entries["Compression"], "SNAPPY")
        XCTAssertEqual(entries["Written by"], "parquet-cpp-arrow 17.0.0")
        guard case .strip(let title, let count, let selected, let caption)? = view.inspector.sections.first else { return XCTFail("strip") }
        XCTAssertEqual(title, "Row groups · 5")
        XCTAssertEqual(count, 5)
        XCTAssertEqual(selected, 0)
        XCTAssertTrue(caption.hasPrefix("Showing group 1 · 500 rows"), caption)
        guard case .entries(_, let ranges)? = view.inspector.sections.last else { return XCTFail("ranges") }
        XCTAssertEqual(ranges.first, DataSectionEntry(label: "trip_id", value: "1 → 2,500"))
        XCTAssertEqual(ranges.last, DataSectionEntry(label: "day", value: "2026-09-01 → 2026-09-25"))

        XCTAssertEqual(model.cell(row: 0, column: 0).text, "1")
        XCTAssertEqual(model.cell(row: 0, column: 2).text, "5.00")
        XCTAssertEqual(model.cell(row: 9, column: 1).style, .missing, "null is drawn dim")
        XCTAssertEqual(model.typeTag(0), "123")
        XCTAssertEqual(model.typeTag(2), "1.5")
        XCTAssertEqual(model.typeTag(3), "date")
        XCTAssertTrue(model.headerTooltip(2).contains("DECIMAL(9, 2)"))

        // A row far down is read in the background; its cell reads "…" until then.
        let far = model.cell(row: 2_345, column: 0)
        XCTAssertEqual(far.text, "…")
        await model.waitForWindows()
        XCTAssertEqual(model.cell(row: 2_345, column: 0).text, "2346")

        // A segment's click scrolls to its group and the strip follows.
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        view.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(model.firstShownRow(ofChunk: 3))
        XCTAssertEqual(row, 1_500)
        view.scrollToRow(row)
        guard case .strip(_, _, let lit, let now)? = view.inspector.sections.first else { return XCTFail("strip") }
        XCTAssertEqual(lit, 3)
        XCTAssertTrue(now.hasPrefix("Showing group 4"), now)
    }

    func testColumnProfileFilterSortAndCopy() async throws {
        let (preview, view, model) = try await render(try trips())
        await model.waitForSample()
        view.inspector.show(.column(1))
        XCTAssertEqual(view.inspector.entries.first?.value, "BYTE_ARRAY · STRING")
        let chart = try XCTUnwrap(model.columnChart(1))
        XCTAssertEqual(chart.empty, 250)
        XCTAssertEqual(chart.top.first?.count, 500)
        XCTAssertTrue(model.profileNote.contains("Profiled all 2,500 rows"), model.profileNote)

        // Filter: every row is read off the main thread.
        _ = await view.filter("harb")
        XCTAssertEqual(model.shownCount, 500)
        XCTAssertEqual(model.rowNumber(0), 2)
        _ = await view.filter("")
        // Sort by fare, descending: decimals by value.
        _ = await view.setSort(column: 2, ascending: false).value
        XCTAssertEqual(model.cell(row: 0, column: 2).text, "8.99")
        XCTAssertEqual(preview.gutter?.trailing, "Sorted by fare ↓")

        // Copy as reads the rows it copies, even ones never scrolled to.
        view.grid.table.selectRowIndexes(IndexSet([0, 1_999]), byExtendingSelection: false)
        let offer = try XCTUnwrap(preview.copyFormats?())
        XCTAssertEqual(offer.heading, "Copy 2 rows as")
        let csv = offer.formats[0].text().split(separator: "\n").map(String.init)
        XCTAssertEqual(csv.first, "trip_id,zone,fare,day")
        XCTAssertEqual(csv.count, 3)
        XCTAssertFalse(csv.contains { $0.contains("…") }, "\(csv)")
    }

    func testSQLOverParquet() async throws {
        let (preview, view, _) = try await render(try trips())
        XCTAssertEqual(preview.findModes, [.filter, .query])
        XCTAssertEqual(preview.queryPlaceholder, "SELECT * FROM t")
        let outcome = try await XCTUnwrap(preview.query)("SELECT zone, count(*) AS n FROM t WHERE zone IS NOT NULL GROUP BY zone ORDER BY zone")
        XCTAssertNil(outcome.message, outcome.message ?? "")
        XCTAssertEqual(outcome.rows, 5)
        let result = try XCTUnwrap(view.queryController?.resultView)
        XCTAssertEqual(result.model.cell(row: 0, column: 0).text, "Harbour")
        XCTAssertEqual(result.model.cell(row: 0, column: 1).text, "500")
        let named = try await XCTUnwrap(preview.query)("SELECT max(day) FROM \"trips-2026-09\"")
        XCTAssertEqual(view.queryController?.resultView?.model.cell(row: 0, column: 0).text, "2026-09-25", named.message ?? "")
    }

    func testArrowFeatherFile() async throws {
        let columns = [
            TestArrowColumn(name: "id", kind: .int64, values: (0..<300).map { .int(Int64($0)) }),
            TestArrowColumn(name: "label", kind: .dictionaryUtf8, values: (0..<300).map { .string(["a", "b", "c"][$0 % 3]) }),
            TestArrowColumn(name: "tags", kind: .listInt32, values: (0..<300).map { .list((0..<($0 % 3)).map { .int(Int64($0)) }) }),
        ]
        let url = try write("frame.feather", TestArrow.ipc(columns, batchRows: 100, file: true))
        let (preview, view, model) = try await render(url)
        XCTAssertEqual(preview.document.kind, .dataset(.feather))
        XCTAssertEqual(preview.document.fact("headline")?.value, "300 rows · 3 columns")
        guard case .strip(let title, _, _, _)? = view.inspector.sections.first else { return XCTFail("strip") }
        XCTAssertEqual(title, "Record batches · 3")
        XCTAssertEqual(model.cell(row: 2, column: 1).text, "c")
        XCTAssertEqual(model.cell(row: 2, column: 2).text, "[0, 1]")
        XCTAssertTrue(model.headerTooltip(2).contains("nested"))
    }

    func testWorkbookSheetsArePartsAndSwitch() async throws {
        let sheet1 = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c></row>"
            + (2...6).map { "<row r=\"\($0)\"><c r=\"A\($0)\" t=\"s\"><v>2</v></c><c r=\"B\($0)\"><v>\($0 * 10)</v></c></row>" }.joined() + "</sheetData>"
        let sheet2 = "<sheetData><row r=\"4\"><c r=\"C4\"><v>1.5</v></c></row></sheetData>"
        let url = try write("book.xlsx", TestXLSX.workbook(sheets: [("Sales", sheet1), ("Other", sheet2)], sharedStrings: ["Region", "Units", "North"]))
        let (preview, view, model) = try await render(url)
        XCTAssertEqual(preview.document.kind, .dataset(.xlsx))
        XCTAssertEqual(preview.document.fact("headline")?.value, "Sales · 5 rows · 2 columns")
        XCTAssertEqual(view.inspector.tabs.label(forSegment: 0), "Workbook")
        XCTAssertEqual(model.parts.map(\.name), ["Sales", "Other"])
        XCTAssertEqual(model.rowNumber(0), 2, "the sheet's own row numbers")
        XCTAssertEqual(model.cell(row: 4, column: 1).text, "60")
        model.selectPart(1)
        XCTAssertEqual(preview.document.fact("headline")?.value, "Other · 1 row · 3 columns")
        XCTAssertEqual(view.grid.table.tableColumns.map(\.title), ["", "A", "B", "C"])
        XCTAssertEqual(model.rowNumber(0), 4)
        XCTAssertEqual(model.cell(row: 0, column: 2).text, "1.5")
        let outcome = try await XCTUnwrap(preview.query)("SELECT C FROM t")
        XCTAssertEqual(outcome.rows, 1, outcome.message ?? "")
    }

    func testRefusalsThrowWithTheReason() async throws {
        let truncated = Array(TestParquet.file([TestParquetColumn(name: "n", physical: .int64, values: [.int(1)])]).dropLast(4))
        let url = try write("cut.parquet", truncated)
        do {
            _ = try await DataRenderer().render(url: url, kind: .dataset(.parquet), context: RenderContext(appearance: .light, defaultsSuite: "vt-columnar"))
            XCTFail("a cut file must not render")
        } catch {
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("cut short") == true, "\(error)")
        }
    }
}
