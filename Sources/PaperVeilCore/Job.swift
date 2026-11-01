import Foundation

public enum ProcessingPhase: String, Codable, Sendable {
    case validatingInput, extractingText, ocr, rules, llm, exporting, validatingExport
}

public enum JobStage: Codable, Hashable, Sendable {
    case queued
    case processing(ProcessingPhase)
    case review
    case failed(String)
    case cancelled
}

/// User-facing status. None of these claims anonymity.
public enum DisplayStatus: String, Sendable, CaseIterable {
    case waiting = "Wartet"
    case processing = "Verarbeitung"
    case needsReview = "Prüfung nötig"
    case readyForApproval = "Bereit zur Freigabe"
    case approved = "Freigegeben"
    case transferring = "Übertragung"
    case transferred = "Übertragen (verifiziert)"
    case cancelled = "Abgebrochen"
    case failed = "Fehler"
}

public struct ExportRecord: Codable, Hashable, Sendable {
    public var revision: Int
    /// Path relative to the job's work directory.
    public var fileName: String
    public var sha256: String
    public var pageCount: Int
    public var validated: Bool
    public var validationMessages: [String]
    public init(revision: Int, fileName: String, sha256: String, pageCount: Int, validated: Bool, validationMessages: [String]) {
        self.revision = revision; self.fileName = fileName; self.sha256 = sha256; self.pageCount = pageCount
        self.validated = validated; self.validationMessages = validationMessages
    }
}

public struct ApprovalRecord: Codable, Hashable, Sendable {
    public var revision: Int
    public var exportSHA256: String
    public var date: Date
}

public enum TransferState: Codable, Hashable, Sendable {
    case inProgress(revision: Int)
    case verified(revision: Int, remotePath: String, sha256: String, date: Date)
    case failed(revision: Int, message: String)
}

public enum JobError: Error, Equatable, CustomStringConvertible {
    case busy, notApproved, approvalPreconditions(String), staleExport
    public var description: String {
        switch self {
        case .busy: "Dokument wird gerade verarbeitet."
        case .notApproved: "Diese Exportrevision ist nicht zur Übertragung freigegeben."
        case .approvalPreconditions(let s): "Freigabe nicht möglich: \(s)"
        case .staleExport: "Der Export entspricht nicht der aktuellen Revision."
        }
    }
}

public struct Job: Identifiable, Codable, Hashable, Sendable {
    public var id: DocumentID
    /// Local-only reference to the original. Never part of exports, manifests or logs.
    public var originalPath: String
    public var originalSHA256: String
    public var pageCount: Int
    public var stage: JobStage
    public var findings: [Finding]
    public var warnings: [ProcessingWarning]
    /// Content revision; bumped on every change that affects the export.
    public var revision: Int
    public var reviewConfirmedRevision: Int?
    public var export: ExportRecord?
    public var approval: ApprovalRecord?
    public var transfer: TransferState?
    public var llmRequested: Bool

    public init(id: DocumentID = .generate(), originalPath: String, originalSHA256: String, llmRequested: Bool) {
        self.id = id; self.originalPath = originalPath; self.originalSHA256 = originalSHA256
        self.pageCount = 0; self.stage = .queued; self.findings = []; self.warnings = []; self.revision = 1
        self.export = nil; self.approval = nil; self.transfer = nil; self.llmRequested = llmRequested
    }

    public var isBusy: Bool {
        if case .processing = stage { return true }
        if case .inProgress = transfer { return true }
        return false
    }

    public var currentExport: ExportRecord? {
        guard let e = export, e.revision == revision, e.validated else { return nil }
        return e
    }

    public var isApprovedForTransfer: Bool {
        guard let a = approval, let e = currentExport else { return false }
        return a.revision == revision && a.exportSHA256 == e.sha256
    }

    /// Reasons that block approval. Empty means the user may approve.
    public var approvalBlockers: [String] {
        var r: [String] = []
        if isBusy { r.append("Verarbeitung läuft") }
        guard case .review = stage else { r.append("Dokument ist nicht im Prüfschritt"); return r }
        let open = findings.filter { $0.decision == .proposed }.count
        if open > 0 { r.append("\(open) Fundstelle(n) ungeprüft") }
        let warn = warnings.filter { !$0.acknowledged }.count
        if warn > 0 { r.append("\(warn) Warnung(en) nicht bestätigt") }
        if reviewConfirmedRevision != revision { r.append("Prüfung der aktuellen Revision nicht bestätigt") }
        if currentExport == nil { r.append("Kein validierter Export der aktuellen Revision") }
        return r
    }

    public var displayStatus: DisplayStatus {
        switch stage {
        case .queued: return .waiting
        case .processing: return .processing
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .review: break
        }
        switch transfer {
        case .inProgress: return .transferring
        case .verified(let rev, _, _, _) where rev == revision && isApprovedForTransfer: return .transferred
        default: break
        }
        if isApprovedForTransfer { return .approved }
        let unresolved = findings.contains { $0.decision == .proposed } || warnings.contains { !$0.acknowledged }
        if unresolved || reviewConfirmedRevision != revision || currentExport == nil { return .needsReview }
        return .readyForApproval
    }

    // MARK: Mutations that affect content → invalidate approval

    private mutating func contentChanged() {
        revision += 1
        approval = nil
        reviewConfirmedRevision = nil
    }

    public mutating func setDecision(_ d: FindingDecision, for findingID: UUID) throws {
        guard !isBusy else { throw JobError.busy }
        guard let i = findings.firstIndex(where: { $0.id == findingID }), findings[i].decision != d else { return }
        findings[i].decision = d
        contentChanged()
    }

    public mutating func addManualFinding(pageIndex: Int, rect: PageRect, category: IdentifierCategory = .other) throws {
        guard !isBusy else { throw JobError.busy }
        findings.append(Finding(documentID: id, pageIndex: pageIndex, rects: [rect], text: "", category: category,
                                origin: .manual, decision: .accepted))
        contentChanged()
    }

    public mutating func acknowledgeWarning(_ warningID: UUID) {
        guard let i = warnings.firstIndex(where: { $0.id == warningID }) else { return }
        warnings[i].acknowledged = true
    }

    public mutating func confirmReview() throws {
        guard !isBusy else { throw JobError.busy }
        reviewConfirmedRevision = revision
    }

    public mutating func approve(now: Date = Date()) throws {
        let blockers = approvalBlockers
        guard blockers.isEmpty, let e = currentExport else {
            throw JobError.approvalPreconditions(blockers.joined(separator: ", "))
        }
        approval = ApprovalRecord(revision: revision, exportSHA256: e.sha256, date: now)
    }

    public mutating func revokeApproval() { approval = nil }

    /// Called on app launch: anything that was running is marked interrupted, never complete.
    public mutating func recoverAfterRestart() {
        if case .processing(let p) = stage { stage = .failed("Unterbrochen während: \(p.rawValue). Bitte wiederholen.") }
        if case .inProgress(let rev) = transfer {
            transfer = .failed(revision: rev, message: "Übertragung unterbrochen; Empfang nicht bestätigt.")
        }
    }

    /// Reset for a retry; keeps manual findings and user decisions on non-manual findings are dropped.
    public mutating func resetForRetry() {
        findings.removeAll { $0.origin != .manual }
        warnings = []
        export = nil
        transfer = nil
        stage = .queued
        contentChanged()
    }
}
