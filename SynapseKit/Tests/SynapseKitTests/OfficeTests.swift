import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import SynapseKit

/// Reads back the STORED archives ZipWriter makes, through the central directory.
private struct StoredZip {
    struct Entry {
        var name: String
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var size: Int
        var data: Data
    }

    var entries: [Entry] = []

    init(_ d: Data) throws {
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let eocd = b.count - 22
        guard eocd >= 0, u32(eocd) == 0x06054b50 else { throw OfficeError(message: "no end record") }
        let count = u16(eocd + 10)
        guard u16(eocd + 8) == count else { throw OfficeError(message: "entry counts differ") }
        var p = u32(eocd + 16)
        guard p + u32(eocd + 12) == eocd else { throw OfficeError(message: "directory size/offset wrong") }
        for _ in 0..<count {
            guard u32(p) == 0x02014b50 else { throw OfficeError(message: "bad central header") }
            let nameLength = u16(p + 28)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            let local = u32(p + 42)
            guard u32(local) == 0x04034b50, u16(local + 26) == nameLength, u32(local + 14) == u32(p + 16) else {
                throw OfficeError(message: "local header doesn't match for \(name)")
            }
            let start = local + 30 + nameLength + u16(local + 28)
            let size = u32(p + 24)
            entries.append(Entry(name: name, flags: UInt16(u16(p + 8)), method: UInt16(u16(p + 10)), crc: UInt32(u32(p + 16)),
                                 size: size, data: Data(b[start..<(start + size)])))
            p += 46 + nameLength + u16(p + 30) + u16(p + 32)
        }
    }

    func text(_ name: String) -> String? {
        entries.first { $0.name == name }.map { String(decoding: $0.data, as: UTF8.self) }
    }

    var names: [String] { entries.map(\.name) }
}

private func wellFormed(_ xml: String) -> Bool {
    XMLParser(data: Data(xml.utf8)).parse()
}

private func count(_ needle: String, in s: String) -> Int {
    s.components(separatedBy: needle).count - 1
}

final class OfficeZipTests: XCTestCase {
    func testCRC32KnownValues() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipWriter.crc32(Data()), 0)
        XCTAssertEqual(ZipWriter.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
    }

    func testZipRoundTrip() throws {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", text: "<Types/>")
        zip.add("dir/Résumé ü.txt", text: "héllo\nworld")
        zip.add("empty.bin", data: Data())
        let big = Data((0..<70_000).map { UInt8($0 % 251) })
        zip.add("big.bin", data: big)
        let data = try zip.finish()
        let archive = try StoredZip(data)
        XCTAssertEqual(archive.names, ["[Content_Types].xml", "dir/Résumé ü.txt", "empty.bin", "big.bin"])
        for e in archive.entries {
            XCTAssertEqual(e.flags & 0x0800, 0x0800, "UTF-8 flag on \(e.name)")
            XCTAssertEqual(e.method, 0)
            XCTAssertEqual(ZipWriter.crc32(e.data), e.crc)
        }
        XCTAssertEqual(archive.text("dir/Résumé ü.txt"), "héllo\nworld")
        XCTAssertEqual(archive.entries[3].data, big)
        XCTAssertEqual(archive.entries[2].size, 0)

        var again = ZipWriter()
        again.add("[Content_Types].xml", text: "<Types/>")
        again.add("dir/Résumé ü.txt", text: "héllo\nworld")
        again.add("empty.bin", data: Data())
        again.add("big.bin", data: big)
        XCTAssertEqual(try again.finish(), data, "same input, same bytes")
    }
}

final class OfficeCSVTests: XCTestCase {
    func testQuotesNewlinesAndEmptyCells() {
        let text = "Name,Note,Amount\r\n\"Smith, John\",\"He said \"\"hi\"\"\",12\r\n\"Multi\nline\",,\r\nLast, \"spaced, quoted\" ,3\r\n\r\n"
        XCTAssertEqual(CSV.parse(text), [
            ["Name", "Note", "Amount"],
            ["Smith, John", "He said \"hi\"", "12"],
            ["Multi\nline", "", ""],
            ["Last", "spaced, quoted", "3"],
        ])
        XCTAssertEqual(CSV.parse("a,b\n\n,c\n"), [["a", "b"], [""], ["", "c"]], "interior blank row and empty cells kept")
        XCTAssertEqual(CSV.parse("\u{FEFF}x,y"), [["x", "y"]])
        XCTAssertEqual(CSV.parse(""), [])
        XCTAssertEqual(CSV.parse("\"unterminated,field"), [["unterminated,field"]])
    }

    func testDelimiterDetection() {
        XCTAssertEqual(CSV.detectDelimiter("a;b;c\n1,5;2,5;3,5\n4;5;6"), ";")
        XCTAssertEqual(CSV.detectDelimiter("a\tb\tc\n1\t2\t3"), "\t")
        XCTAssertEqual(CSV.detectDelimiter("a|b\n1|2"), "|")
        XCTAssertEqual(CSV.detectDelimiter("\"x,y\";z\n1;2"), ";")
        XCTAssertEqual(CSV.detectDelimiter("single\ncolumn"), ",")
        XCTAssertEqual(CSV.parse("Item;Price\nTea;1,50"), [["Item", "Price"], ["Tea", "1,50"]])
        XCTAssertEqual(CSV.parse("k\tv\nx\t"), [["k", "v"], ["x", ""]])
    }

    func testMarkdownTable() {
        let md = """
        Here is the table:

        | Item | Cost | Note |
        |:-----|-----:|:----:|
        | Tea  | $3   | hot \\| sweet |
        | **Total** | `=SUM(B2:B2)` | a<br>b |

        Thanks!
        """
        let table = CSV.markdownTable(md)
        XCTAssertEqual(table?.rows, [["Item", "Cost", "Note"], ["Tea", "$3", "hot | sweet"], ["**Total**", "`=SUM(B2:B2)`", "a\nb"]])
        XCTAssertEqual(table?.alignments, [.left, .right, .center])
        XCTAssertEqual(CSV.parse(md).count, 3)
        XCTAssertEqual(CSV.parse("a | b\n--- | ---\n1 | 2"), [["a", "b"], ["1", "2"]], "outer pipes optional")
        XCTAssertTrue(CSV.isTableSeparator("|---|:--:|"))
        XCTAssertFalse(CSV.isTableSeparator("---"))
        XCTAssertFalse(CSV.isTableSeparator("| a | b |"))
    }
}

final class OfficeXLSXTests: XCTestCase {
    func testNumberPercentCurrencyAndFormulaDetection() {
        func check(_ raw: String, _ kind: XLSXWriter.Kind, _ format: String = "General", file: StaticString = #filePath, line: UInt = #line) {
            let c = XLSXWriter.cell(raw)
            XCTAssertEqual(c.kind, kind, raw, file: file, line: line)
            XCTAssertEqual(c.format, format, raw, file: file, line: line)
        }
        check("42", .number(42))
        check("-3.5", .number(-3.5))
        check("1,234.5", .number(1234.5), "#,##0.0")
        check("1,234", .number(1234), "#,##0")
        check(".5", .number(0.5))
        check("12%", .number(0.12), "0%")
        check("-3.3%", .number(-0.033), "0.0%")
        check("$12.50", .number(12.5), "\"$\"#,##0.00")
        check("-$1,200", .number(-1200), "\"$\"#,##0")
        check("£3", .number(3), "\"£\"#,##0")
        check("€4.5", .number(4.5), "\"€\"#,##0.0")
        check("4 €", .number(4), "#,##0\" €\"")
        check("(1,200)", .number(-1200), "#,##0;(#,##0)")
        check("1.5e3", .number(1500))
        check("=SUM(B2:B4)", .formula("SUM(B2:B4)"))
        check("=IF(A1>0; \"ok\"; \"no\")", .formula("IF(A1>0, \"ok\", \"no\")"))
        check("=CONCAT(A1,B1)", .formula("_xlfn.CONCAT(A1,B1)"))
        check("007", .text("007"))
        check("1,23", .text("1,23"))
        check("4111111111111111", .text("4111111111111111"))
        check("2026-01-15", .text("2026-01-15"))
        check("$5%", .text("$5%"))
        check("'00123", .text("00123"))
        check("=", .text("="))
        check("", .empty)
        XCTAssertTrue(XLSXWriter.cell("**Total**").bold)
        XCTAssertEqual(XLSXWriter.cell("**$1,200**").kind, .number(1200))
    }

    func testSheetNameSanitizing() {
        let names = XLSXWriter.sanitizedSheetNames(["Budget", "budget", "Q1/Q2: [draft]*?", "", "History", String(repeating: "x", count: 40), "'quoted'", "Budget"])
        XCTAssertEqual(names[0], "Budget")
        XCTAssertEqual(names[1], "budget (2)")
        XCTAssertEqual(names[2], "Q1-Q2- draft")
        XCTAssertEqual(names[3], "Sheet4")
        XCTAssertEqual(names[4], "History (1)")
        XCTAssertEqual(names[5], String(repeating: "x", count: 31))
        XCTAssertEqual(names[6], "quoted")
        XCTAssertEqual(names[7], "Budget (3)")
        XCTAssertTrue(names.allSatisfy { $0.utf16.count <= 31 && !$0.contains(where: { "[]:*?/\\".contains($0) }) })
    }

    func testSheetsFromText() {
        let text = """
        ### Sheet: Budget
        ```csv
        Item,Cost
        Rent,1200
        ```
        ## Summary
        | Metric | Value |
        |---|---|
        | Total | =Budget!B2 |
        # of units,Cost
        """
        let sheets = XLSXWriter.sheets(fromText: text)
        XCTAssertEqual(sheets.map(\.name), ["Budget", "Summary"])
        XCTAssertEqual(sheets[0].rows, [["Item", "Cost"], ["Rent", "1200"]])
        XCTAssertEqual(sheets[1].rows, [["Metric", "Value"], ["Total", "=Budget!B2"]], "text after the table is ignored")
        XCTAssertEqual(XLSXWriter.sheets(fromText: "#,Item\n1,Tea").first?.rows, [["#", "Item"], ["1", "Tea"]])
        XCTAssertEqual(XLSXWriter.sheets(fromText: "Here you go:\n## A\nx,y\n## B\nz").map(\.name), ["A", "B"])
    }

    func testWorkbookPartsFormulasAndCachedValues() throws {
        let data = try XLSXWriter.write([
            XLSXWriter.Sheet(name: "Budget", rows: [
                ["Item", "Cost", "Share"],
                ["Rent", "$1,200.00", "60%"],
                ["Food", "$800.00", "40%"],
                ["Total", "=SUM(B2:B3)", "=SUM(C2:C3)"],
                ["Check", "=IF(B4>1000,\"over\",\"ok\")", "=B4/0"],
                ["Bad", "=SUM(B2:B3", "=Missing!A1+1"],
                ["Round", "=ROUND(2.675,2)", "=AVERAGE(B2:B3)*10%"],
            ]),
            XLSXWriter.Sheet(name: "Summary", rows: [["Total"], ["=Budget!B4*2"]]),
        ], title: "Home <budget> & co", created: Date(timeIntervalSince1970: 0))
        let zip = try StoredZip(data)
        for part in ["[Content_Types].xml", "_rels/.rels", "docProps/app.xml", "docProps/core.xml", "xl/workbook.xml",
                     "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
            let xml = try XCTUnwrap(zip.text(part), part)
            XCTAssertTrue(wellFormed(xml), part)
        }
        XCTAssertTrue(zip.text("docProps/core.xml")!.contains("<dc:title>Home &lt;budget&gt; &amp; co</dc:title>"))
        let s1 = zip.text("xl/worksheets/sheet1.xml")!
        XCTAssertTrue(s1.contains("<f>SUM(B2:B3)</f><v>2000</v>"))
        XCTAssertTrue(s1.contains("<f>SUM(C2:C3)</f><v>1</v>"))
        XCTAssertTrue(s1.contains("t=\"str\"><f>IF(B4&gt;1000,&quot;over&quot;,&quot;ok&quot;)</f><v>over</v>"))
        XCTAssertTrue(s1.contains("t=\"e\"><f>B4/0</f><v>#DIV/0!</v>"))
        XCTAssertTrue(s1.contains("t=\"inlineStr\"><is><t xml:space=\"preserve\">=SUM(B2:B3</t></is>"), "unbalanced formula kept as text")
        XCTAssertTrue(s1.contains("<f>Missing!A1+1</f></c>"), "unknown sheet: formula without a cached value")
        XCTAssertTrue(s1.contains("<f>ROUND(2.675,2)</f><v>2.68</v>"))
        XCTAssertTrue(s1.contains("<f>AVERAGE(B2:B3)*10%</f><v>100</v>"))
        XCTAssertTrue(s1.contains("<v>0.6</v>"))
        XCTAssertTrue(s1.contains("state=\"frozen\""))
        XCTAssertTrue(zip.text("xl/worksheets/sheet2.xml")!.contains("<f>Budget!B4*2</f><v>4000</v>"))
        let styles = zip.text("xl/styles.xml")!
        XCTAssertTrue(styles.contains("formatCode=\"&quot;$&quot;#,##0.00\""))
        XCTAssertTrue(styles.contains("numFmtId=\"9\""), "percent style")
        XCTAssertTrue(styles.contains("<b/>"))
        XCTAssertTrue(zip.text("xl/workbook.xml")!.contains("<sheet name=\"Budget\" sheetId=\"1\" r:id=\"rId1\"/>"))
    }

    func testFormulaEngineOperators() throws {
        func value(_ formula: String, rows: [[String]] = [["1", "2"], ["3", "x"]]) -> FormulaEngine.Value? {
            var grid = rows.map { $0.map { XLSXWriter.cell($0) } }
            grid.append([XLSXWriter.cell(formula)])
            var engine = FormulaEngine(grids: [grid], sheetIndex: ["s": 0])
            engine.prepare()
            return engine.cached(sheet: 0, row: rows.count, column: 0)
        }
        XCTAssertEqual(value("=-2^2"), .number(4))
        XCTAssertEqual(value("=2+3*4-1"), .number(13))
        XCTAssertEqual(value("=(A1+B1)*A2"), .number(9))
        XCTAssertEqual(value("=50%*A2"), .number(1.5))
        XCTAssertEqual(value("=A1&\"-\"&B2"), .text("1-x"))
        XCTAssertEqual(value("=A1<B1"), .bool(true))
        XCTAssertEqual(value("=B2+1"), .error("#VALUE!"))
        XCTAssertEqual(value("=SUM(A1:B2)"), .number(6), "text in ranges is skipped")
        XCTAssertEqual(value("=COUNT(A1:B2)"), .number(3))
        XCTAssertEqual(value("=COUNTA(A1:B2)"), .number(4))
        XCTAssertEqual(value("=MAX(A1:A2)"), .number(3))
        XCTAssertEqual(value("=SUM(B:B)"), .number(2), "whole-column range")
        XCTAssertNil(value("=SUM(A:A)"), "a range containing the formula itself is circular")
        XCTAssertEqual(value("=IFERROR(1/0,\"n/a\")"), .text("n/a"))
        XCTAssertEqual(value("=MOD(-3,2)"), .number(1))
        XCTAssertNil(value("=VLOOKUP(1,A1:B2,2,FALSE)"), "unsupported function: no cached value")
        XCTAssertNil(value("=A3"), "self reference")
    }
}

final class OfficePPTXTests: XCTestCase {
    let deck = """
    # Quarterly Review
    Q3 2026 · Finance team

    ---
    ## Slide 2: Highlights
    - Revenue up **18%**
      - Driven by *subscriptions*
        - Third level
    - Costs flat
    1. First step
    2. Second step
    A closing paragraph.
    Notes: Mention the 18% figure.
    Pause for questions.

    ---

    ## Numbers
    | Region | Sales |
    |---|---:|
    | EU | 120 |
    | US | 200 |
    """

    func testSlideParsing() {
        let slides = PPTXWriter.slides(fromText: deck)
        XCTAssertEqual(slides.count, 3)
        XCTAssertEqual(slides.map(\.title), ["Quarterly Review", "Highlights", "Numbers"])
        XCTAssertEqual(slides[0].items, [PPTXWriter.Slide.Item(kind: .text, text: "Q3 2026 · Finance team")])
        let items = slides[1].items
        XCTAssertEqual(items.map(\.kind), [.bullet, .bullet, .bullet, .bullet, .number, .number, .text])
        XCTAssertEqual(items.map(\.level), [0, 1, 2, 0, 0, 0, 0])
        XCTAssertEqual(items[0].text, "Revenue up **18%**")
        XCTAssertEqual(slides[1].notes, "Mention the 18% figure.\nPause for questions.")
        XCTAssertEqual(slides[2].table, [["Region", "Sales"], ["EU", "120"], ["US", "200"]])
        XCTAssertTrue(slides[2].notes.isEmpty)

        let tabbed = PPTXWriter.slides(fromText: "# T\n---\n## A\n- one\n\t- two\n* three\n**Speaker notes:** say hi")
        XCTAssertEqual(tabbed[1].items.map(\.level), [0, 1, 0])
        XCTAssertEqual(tabbed[1].notes, "say hi")

        // No separators: every # / ## heading starts a slide.
        let headings = PPTXWriter.slides(fromText: "# Deck\nSubtitle\n## One\n- a\n## Two\n- b\n### Detail\ntext")
        XCTAssertEqual(headings.map(\.title), ["Deck", "One", "Two"])
        XCTAssertEqual(headings[2].items, [PPTXWriter.Slide.Item(kind: .bullet, text: "b"), PPTXWriter.Slide.Item(kind: .heading, text: "Detail"),
                                           PPTXWriter.Slide.Item(kind: .text, text: "text")], "### stays inside the slide")
        XCTAssertEqual(PPTXWriter.slides(fromText: "---\n\n---\n# Only").count, 1, "empty slides dropped")
    }

    func testDeckPackage() throws {
        let data = try PPTXWriter.write(PPTXWriter.slides(fromText: deck), title: "Q3 <Review>", theme: .dark, created: Date(timeIntervalSince1970: 0))
        let zip = try StoredZip(data)
        let required = ["[Content_Types].xml", "_rels/.rels", "docProps/app.xml", "docProps/core.xml", "ppt/presentation.xml",
                        "ppt/_rels/presentation.xml.rels", "ppt/presProps.xml", "ppt/viewProps.xml", "ppt/tableStyles.xml",
                        "ppt/theme/theme1.xml", "ppt/slideMasters/slideMaster1.xml", "ppt/slideMasters/_rels/slideMaster1.xml.rels",
                        "ppt/slideLayouts/slideLayout1.xml", "ppt/slideLayouts/slideLayout2.xml", "ppt/slides/slide1.xml",
                        "ppt/slides/slide2.xml", "ppt/slides/slide3.xml", "ppt/notesMasters/notesMaster1.xml", "ppt/theme/theme2.xml",
                        "ppt/notesSlides/notesSlide2.xml", "ppt/notesSlides/_rels/notesSlide2.xml.rels"]
        for part in required { XCTAssertNotNil(zip.text(part), part) }
        XCTAssertFalse(zip.names.contains("ppt/notesSlides/notesSlide1.xml"))
        for e in zip.entries { XCTAssertTrue(wellFormed(String(decoding: e.data, as: UTF8.self)), e.name) }

        let types = zip.text("[Content_Types].xml")!
        for e in zip.entries where e.name.hasSuffix(".xml") && e.name != "[Content_Types].xml" {
            XCTAssertTrue(types.contains("PartName=\"/\(e.name)\""), "override for \(e.name)")
        }
        let presentation = zip.text("ppt/presentation.xml")!
        XCTAssertTrue(presentation.contains("<p:sldSz cx=\"12192000\" cy=\"6858000\"/>"))
        XCTAssertTrue(presentation.contains("<p:notesMasterIdLst>"))
        XCTAssertEqual(count("<p:sldId ", in: presentation), 3)
        let theme = zip.text("ppt/theme/theme1.xml")!
        for part in ["<a:clrScheme", "<a:fontScheme", "<a:fillStyleLst>", "<a:lnStyleLst>", "<a:effectStyleLst>", "<a:bgFillStyleLst>"] {
            XCTAssertTrue(theme.contains(part), part)
        }
        XCTAssertEqual(count("<a:gradFill", in: theme), 3)
        let cover = zip.text("ppt/slides/slide1.xml")!
        XCTAssertTrue(cover.contains("type=\"ctrTitle\""))
        XCTAssertTrue(cover.contains("<a:srgbClr val=\"111827\"/>"), "dark background")
        let content = zip.text("ppt/slides/slide2.xml")!
        XCTAssertTrue(content.contains("<a:normAutofit"))
        XCTAssertTrue(content.contains("lvl=\"1\""))
        XCTAssertTrue(content.contains("lvl=\"2\""))
        XCTAssertTrue(content.contains("<a:buAutoNum type=\"arabicPeriod\"/>"))
        XCTAssertTrue(content.contains("b=\"1\" dirty=\"0\"><a:solidFill><a:srgbClr val=\"D1D5DB\"/></a:solidFill></a:rPr><a:t>18%</a:t>"))
        XCTAssertTrue(zip.text("ppt/slides/slide3.xml")!.contains("<a:tbl>"))
        XCTAssertTrue(zip.text("ppt/notesSlides/notesSlide2.xml")!.contains("<a:t>Pause for questions.</a:t>"))
        XCTAssertTrue(zip.text("ppt/slides/_rels/slide2.xml.rels")!.contains("notesSlide2.xml"))
        XCTAssertTrue(zip.text("docProps/core.xml")!.contains("Q3 &lt;Review&gt;"))
    }

    func testDeckWithoutNotesOmitsNotesParts() throws {
        let zip = try StoredZip(PPTXWriter.write(PPTXWriter.slides(fromText: "# Hi\n---\n## A\n- b"), title: "", theme: .ocean))
        XCTAssertFalse(zip.names.contains { $0.contains("notes") })
        XCTAssertFalse(zip.text("ppt/presentation.xml")!.contains("notesMasterIdLst"))
        XCTAssertTrue(zip.text("docProps/core.xml")!.contains("<dc:title>Hi</dc:title>"))
    }

    func testTextFitting() {
        let few = [PPTXWriter.Slide.Item(kind: .bullet, text: "Short point")]
        let many = Array(repeating: PPTXWriter.Slide.Item(kind: .bullet, text: String(repeating: "word ", count: 30)), count: 9)
        let sizes: [Double] = [28, 24, 20, 16, 12, 10]
        XCTAssertEqual(PPTXWriter.fit(few, width: 850, height: 355, sizes: sizes).size, 28)
        let crowded = PPTXWriter.fit(many, width: 850, height: 355, sizes: sizes)
        XCTAssertLessThan(crowded.size, 20)
        XCTAssertEqual(DeckTheme(named: " Sunset "), .sunset)
        XCTAssertEqual(DeckTheme(named: "neon"), .light)
        XCTAssertEqual(DeckTheme(named: nil), .light)
    }
}

final class OfficeDOCXTests: XCTestCase {
    let markdown = """
    # Project Plan

    Intro with **bold**, *italic*, `code` and a [link](https://example.com/a?b=1&c=2).

    ## Steps
    1. Gather
    2. Build
       - sub point
    3. Ship

    Between lists.

    1. Again from one
    - bullet A
    * bullet B

    > Quoted line one
    > line two

    ---

    | Name | Score |
    |:---|---:|
    | Ann | 9 |
    | Bob | 7 |

    ```swift
    let x = 1 < 2
    ```
    """

    func testBlocksListsAndTables() {
        let (blocks, starts) = DOCXWriter.parse(markdown)
        let items = blocks.compactMap { b -> (Bool, Int, Int)? in
            if case .item(let ordered, let level, _, let id) = b { return (ordered, level, id) }
            return nil
        }
        XCTAssertEqual(items.map(\.0), [true, true, false, true, true, false, false])
        XCTAssertEqual(items.map(\.1), [0, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(items[0].2, items[3].2, "numbering continues past a nested bullet")
        XCTAssertNotEqual(items[0].2, items[4].2, "a new list restarts")
        XCTAssertEqual(items[5].2, 1)
        XCTAssertEqual(starts.count, 2)
        XCTAssertTrue(blocks.contains(.quote("Quoted line one line two")))
        XCTAssertTrue(blocks.contains(.rule))
        XCTAssertTrue(blocks.contains(.table(rows: [["Name", "Score"], ["Ann", "9"], ["Bob", "7"]], alignments: [.left, .right])))
        XCTAssertTrue(blocks.contains(.code(["let x = 1 < 2"])))
        XCTAssertEqual(DOCXWriter.summary(markdown: markdown), "2 headings, 3 paragraphs, 3 lists, 1 table, 1 code block")
    }

    func testDocumentPackage() throws {
        let data = try DOCXWriter.write(markdown: markdown + "\nControl\u{1}chars\u{0B} & <tags>", title: "Plan \"Q4\"", created: Date(timeIntervalSince1970: 0))
        let zip = try StoredZip(data)
        for part in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml",
                     "word/_rels/document.xml.rels", "word/settings.xml", "docProps/core.xml", "docProps/app.xml"] {
            let xml = try XCTUnwrap(zip.text(part), part)
            XCTAssertTrue(wellFormed(xml), part)
        }
        let doc = zip.text("word/document.xml")!
        XCTAssertTrue(doc.contains("<w:pStyle w:val=\"Title\"/>"), "lone H1 is the title")
        XCTAssertTrue(doc.contains("<w:pStyle w:val=\"Heading2\"/>"))
        XCTAssertTrue(doc.contains("<w:pStyle w:val=\"Quote\"/>"))
        XCTAssertTrue(doc.contains("<w:b/><w:bCs/></w:rPr><w:t xml:space=\"preserve\">bold</w:t>"))
        XCTAssertTrue(doc.contains("<w:i/><w:iCs/></w:rPr><w:t xml:space=\"preserve\">italic</w:t>"))
        XCTAssertTrue(doc.contains("w:ascii=\"Consolas\""))
        XCTAssertTrue(doc.contains("<w:hyperlink r:id=\"rId4\""))
        XCTAssertTrue(doc.contains("<w:numPr><w:ilvl w:val=\"1\"/><w:numId w:val=\"1\"/></w:numPr>"))
        XCTAssertEqual(count("<w:tbl>", in: doc), 1)
        XCTAssertEqual(count("<w:gridCol ", in: doc), 2)
        XCTAssertTrue(doc.contains("<w:insideV w:val=\"single\""))
        XCTAssertTrue(doc.contains("<w:jc w:val=\"right\"/>"))
        XCTAssertTrue(doc.contains("<w:pBdr><w:bottom w:val=\"single\""), "--- is a rule, not a page break")
        XCTAssertFalse(doc.contains("w:type=\"page\""))
        XCTAssertTrue(doc.contains("let x = 1 &lt; 2"))
        XCTAssertTrue(doc.contains("Controlchars &amp; &lt;tags&gt;"))
        XCTAssertFalse(doc.contains("\u{1}"))
        let rels = zip.text("word/_rels/document.xml.rels")!
        XCTAssertTrue(rels.contains("Target=\"https://example.com/a?b=1&amp;c=2\" TargetMode=\"External\""))
        let numbering = zip.text("word/numbering.xml")!
        XCTAssertEqual(count("<w:num ", in: numbering), 3)
        XCTAssertTrue(numbering.contains("<w:startOverride w:val=\"1\"/>"))
        XCTAssertTrue(zip.text("docProps/core.xml")!.contains("<dc:title>Plan &quot;Q4&quot;</dc:title>"))
        let styles = zip.text("word/styles.xml")!
        for id in ["Heading1", "Heading2", "Heading3", "Title", "ListParagraph", "Quote"] {
            XCTAssertTrue(styles.contains("w:styleId=\"\(id)\""), id)
        }
    }
}

final class OfficeDocumentTests: XCTestCase {
    func testXMLEscaping() {
        XCTAssertEqual(OfficeXML.escape("<a & b> \"q\" 'x'"), "&lt;a &amp; b&gt; &quot;q&quot; &apos;x&apos;")
        XCTAssertEqual(OfficeXML.escape("ok\u{0}\u{1}\u{8}\u{B}\u{C}\u{1F}\u{FFFE}\u{FFFF}\t\n\r✓😀"), "ok\t\n\r✓😀")
    }

    func testInlineRuns() {
        let runs = OfficeInline.runs("**Bold** and *it* `a*b` [site](https://x.y) snake_case 2 * 3 ~~old~~")
        XCTAssertEqual(runs.map(\.text), ["Bold", " and ", "it", " ", "a*b", " ", "site", " snake_case 2 * 3 ", "old"])
        XCTAssertTrue(runs[0].bold)
        XCTAssertTrue(runs[2].italic)
        XCTAssertTrue(runs[4].code)
        XCTAssertEqual(runs[6].link, "https://x.y")
        XCTAssertTrue(runs[8].strike)
        XCTAssertEqual(OfficeInline.plain("***both*** \\*literal\\* **unclosed"), "both *literal* **unclosed")
    }

    func testFacade() throws {
        XCTAssertEqual(OfficeKind.xlsx.mimeType, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertEqual(OfficeKind.pptx.mimeType, "application/vnd.openxmlformats-officedocument.presentationml.presentation")
        XCTAssertEqual(OfficeKind.docx.mimeType, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertEqual(OfficeKind.allCases.map(\.title), ["Excel spreadsheet", "PowerPoint presentation", "Word document"])
        XCTAssertEqual(OfficeKind.docx.fileExtension, "docx")

        for kind in OfficeKind.allCases {
            XCTAssertThrowsError(try OfficeDocument.make(kind, title: "x", text: "  \n\t")) { error in
                XCTAssertTrue(error is OfficeError)
                XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
            }
        }
        let csv = try StoredZip(OfficeDocument.make(.xlsx, title: "Groceries", text: "```csv\nItem,Qty\nMilk,2\n```"))
        XCTAssertTrue(csv.text("xl/workbook.xml")!.contains("<sheet name=\"Groceries\""), "unnamed sheet takes the title")
        let deck = try StoredZip(OfficeDocument.make(.pptx, title: "T", text: "# A\n---\n## B\n- c", theme: "FOREST"))
        XCTAssertTrue(deck.text("ppt/theme/theme1.xml")!.contains("Synapse Forest"))
        let fallback = try StoredZip(OfficeDocument.make(.pptx, title: "T", text: "# A", theme: "neon"))
        XCTAssertTrue(fallback.text("ppt/theme/theme1.xml")!.contains("Synapse Light"))
        _ = try StoredZip(OfficeDocument.make(.docx, title: "D", text: "Hello"))

        XCTAssertEqual(OfficeDocument.describe(.xlsx, text: "## A\nx,y\n1,2\n## B\nz"), "2 sheets, 3 rows")
        XCTAssertEqual(OfficeDocument.describe(.pptx, text: "# A\n---\n## B\nNotes: hi"), "2 slides, 1 with speaker notes")
        XCTAssertEqual(OfficeDocument.describe(.pptx, text: "# A"), "1 slide")
        XCTAssertEqual(OfficeDocument.describe(.docx, text: "# A\n## B\ntext\n\n| a |\n|---|\n| 1 |"), "2 headings, 1 paragraph, 1 table")
    }
}
