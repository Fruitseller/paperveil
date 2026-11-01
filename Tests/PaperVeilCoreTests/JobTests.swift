import Foundation
import Testing
@testable import PaperVeilCore

@Suite struct JobTests {
    func reviewedJob() -> Job {
        var j = Job(originalPath: "/tmp/x.pdf", originalSHA256: "abc", llmRequested: false)
        j.stage = .review
        j.findings = [Finding(documentID: j.id, pageIndex: 0, rects: [PageRect(x: 0, y: 0, width: 10, height: 10)],
                              text: "Max", category: .name, origin: .rule)]
        return j
    }

    func attachExport(_ j: inout Job) {
        j.export = ExportRecord(revision: j.revision, fileName: "e.pdf", sha256: "h\(j.revision)", pageCount: 1,
                                validated: true, validationMessages: [])
    }

    @Test func approvalRequiresResolvedFindingsReviewAndExport() throws {
        var j = reviewedJob()
        #expect(j.displayStatus == .needsReview)
        #expect(throws: JobError.self) { try j.approve() }
        try j.setDecision(.accepted, for: j.findings[0].id)
        try j.confirmReview()
        #expect(j.displayStatus == .needsReview) // no export yet
        attachExport(&j)
        #expect(j.displayStatus == .readyForApproval)
        try j.approve()
        #expect(j.displayStatus == .approved)
        #expect(j.isApprovedForTransfer)
    }

    @Test func changeAfterApprovalRevokesIt() throws {
        var j = reviewedJob()
        try j.setDecision(.accepted, for: j.findings[0].id)
        try j.confirmReview(); attachExport(&j); try j.approve()
        try j.addManualFinding(pageIndex: 0, rect: PageRect(x: 1, y: 1, width: 5, height: 5))
        #expect(!j.isApprovedForTransfer)
        #expect(j.currentExport == nil)
        #expect(j.displayStatus == .needsReview)
    }

    @Test func noApprovalWhileProcessing() throws {
        var j = reviewedJob()
        j.stage = .processing(.llm)
        #expect(j.approvalBlockers.contains("Verarbeitung läuft"))
        #expect(throws: JobError.self) { try j.approve() }
        #expect(throws: JobError.self) { try j.addManualFinding(pageIndex: 0, rect: PageRect(x: 0, y: 0, width: 1, height: 1)) }
    }

    @Test func unacknowledgedWarningBlocksApproval() throws {
        var j = reviewedJob()
        try j.setDecision(.rejected, for: j.findings[0].id)
        j.warnings = [ProcessingWarning(kind: .llmTimeout, message: "t")]
        try j.confirmReview(); attachExport(&j)
        #expect(throws: JobError.self) { try j.approve() }
        j.acknowledgeWarning(j.warnings[0].id)
        try j.approve()
    }

    @Test func restartNeverShowsInterruptedAsDone() throws {
        var j = reviewedJob()
        j.stage = .processing(.exporting)
        j.recoverAfterRestart()
        #expect(j.displayStatus == .failed)
        var t = reviewedJob()
        try t.setDecision(.accepted, for: t.findings[0].id); try t.confirmReview(); attachExport(&t); try t.approve()
        t.transfer = .inProgress(revision: t.revision)
        t.recoverAfterRestart()
        #expect(t.displayStatus == .approved)
    }

    @Test func persistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = JobRepository(paths: AppPaths(root: dir))
        var j = reviewedJob(); j.stage = .processing(.ocr)
        try repo.save([j])
        let loaded = try repo.loadRecovering()
        #expect(loaded.count == 1 && loaded[0].id == j.id && loaded[0].displayStatus == .failed)
        try repo.deleteAll()
    }

    @Test func pageTextMapsRangesToLineRects() {
        let w = [
            TextWord(text: "Max", rect: PageRect(x: 10, y: 100, width: 20, height: 10), source: .pdfText, confidence: 1, line: 0),
            TextWord(text: "Muster-", rect: PageRect(x: 35, y: 100, width: 40, height: 10), source: .pdfText, confidence: 1, line: 0),
            TextWord(text: "mann", rect: PageRect(x: 10, y: 85, width: 25, height: 10), source: .pdfText, confidence: 1, line: 1),
        ]
        let p = PageText(pageIndex: 0, words: w)
        #expect(p.text == "Max Muster-\nmann")
        let r = (p.text as NSString).range(of: "Muster-\nmann")
        let rects = p.rects(for: r)
        #expect(rects.count == 2)
    }
}
