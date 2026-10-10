import AppKit
import Foundation
import PDFKit

@MainActor enum PaginationChecks {
    static func run() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["LIGHTMD_PDF_FIXTURE"],
              let outputPath = ProcessInfo.processInfo.environment["LIGHTMD_PDF_OUTPUT"] else { return }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let before = try Data(contentsOf: sourceURL)
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let snapshot = PDFSnapshot(source: source, fileURL: sourceURL, title: sourceURL.lastPathComponent, fontSize: 16)
        let warnings = try await PDFExporter.export(snapshot, to: URL(fileURLWithPath: outputPath))
        precondition(warnings.isEmpty)
        let pdf = PDFDocument(url: URL(fileURLWithPath: outputPath))!
        print("fixture_pdf pages=\(pdf.pageCount)")
        for i in 0..<pdf.pageCount {
            let page = pdf.page(at: i)!, text = page.string ?? ""
            print("page=\(i+1) chars=\(text.count) start=\(String(text.prefix(24)).debugDescription) end=\(String(text.suffix(24)).debugDescription)")
        }
        precondition(try! Data(contentsOf: sourceURL) == before)
        precondition(!NSApp.windows.contains(where: \.isVisible))
        print("fixture_original_bytes_and_offscreen_export=passed")
    }
}
