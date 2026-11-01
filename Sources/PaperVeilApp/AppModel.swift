import Foundation
import Observation
import PaperVeilCore
import os

/// Non-secret settings, persisted locally as JSON.
struct AppSettings: Codable, Equatable {
    var llmEnabled = false
    var llmEndpoint = "http://127.0.0.1:1234"
    var llmModel: String? = nil
    var llmTimeoutSeconds = 180.0
    var exportDPI = 300.0
    var maxConcurrentJobs = 2
}

@MainActor @Observable
final class AppModel {
    let paths: AppPaths
    private let repo: JobRepository
    let engine: Engine
    private let log = Logger(subsystem: "de.paperveil.app", category: "queue")

    var jobs: [Job] = []
    var selection: DocumentID?
    var settings = AppSettings() { didSet { saveSettings() } }
    var lastError: String?
    private var running: [DocumentID: Task<Void, Never>] = [:]

    init(paths: AppPaths = .default()) {
        self.paths = paths
        self.repo = JobRepository(paths: paths)
        self.engine = Engine(paths: paths)
        if let d = try? Data(contentsOf: paths.settingsFile), let s = try? JSONDecoder().decode(AppSettings.self, from: d) {
            settings = s
        }
        do { jobs = try repo.loadRecovering(); persist() } catch { lastError = "Warteschlange konnte nicht geladen werden: \(error)" }
        pump()
    }

    func job(_ id: DocumentID) -> Job? { jobs.first { $0.id == id } }

    private func update(_ id: DocumentID, _ body: (inout Job) throws -> Void) rethrows {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        try body(&jobs[i])
        persist()
    }

    private func persist() {
        do { try repo.save(jobs) } catch { lastError = "Speichern fehlgeschlagen: \(error)" }
    }

    private func saveSettings() {
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(settings).write(to: paths.settingsFile, options: .atomic)
    }

    // MARK: Intake

    func add(urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            let hash = (try? SHA256Hex.of(fileAt: url)) ?? ""
            var job = Job(originalPath: path, originalSHA256: hash, llmRequested: settings.llmEnabled)
            if hash.isEmpty { job.stage = .failed("Datei nicht lesbar.") }
            jobs.append(job)
            log.info("Dokument \(job.id.rawValue, privacy: .public) hinzugefügt")
        }
        persist()
        pump()
    }

    // MARK: Queue

    /// Starts queued jobs up to the concurrency limit. Processing runs off the main actor.
    func pump() {
        let free = settings.maxConcurrentJobs - running.count
        guard free > 0 else { return }
        for job in jobs.filter({ if case .queued = $0.stage { return running[$0.id] == nil } else { return false } }).prefix(free) {
            start(job)
        }
    }

    private func start(_ job: Job) {
        let id = job.id
        let settings = settings
        let blocklist = (try? engine.loadBlocklistData()) ?? nil
        update(id) { $0.stage = .processing(.validatingInput); $0.llmRequested = settings.llmEnabled }
        let engine = engine
        running[id] = Task { [weak self] in
            let snapshot = self?.job(id) ?? job
            let result = await engine.process(job: snapshot, settings: settings, blocklist: blocklist) { phase in
                Task { @MainActor in self?.update(id) { if case .processing = $0.stage { $0.stage = .processing(phase) } } }
            }
            await MainActor.run {
                guard let self else { return }
                self.running[id] = nil
                self.update(id) { j in
                    switch result {
                    case .success(let out):
                        // Keep manual findings from earlier rounds.
                        j.pageCount = out.pageCount
                        j.findings = j.findings.filter { $0.origin == .manual } + out.findings
                        j.warnings = out.warnings
                        j.export = out.export
                        j.stage = .review
                    case .failure(let e):
                        j.stage = Task.isCancelled || e is CancellationError ? .cancelled : .failed(Self.describe(e))
                    }
                }
                self.pump()
            }
        }
    }

    nonisolated static func describe(_ e: Error) -> String {
        (e as? LocalizedError)?.errorDescription ?? String(describing: e)
    }

    func cancel(_ id: DocumentID) {
        running[id]?.cancel()
        running[id] = nil
        update(id) { j in
            if case .processing = j.stage { j.stage = .cancelled }
            if case .queued = j.stage { j.stage = .cancelled }
        }
        pump()
    }

    func retry(_ id: DocumentID) {
        guard running[id] == nil else { return }
        update(id) { $0.resetForRetry() }
        pump()
    }

    // MARK: Review

    func setDecision(_ d: FindingDecision, finding: UUID, in id: DocumentID) {
        perform { try update(id) { try $0.setDecision(d, for: finding) } }
    }

    func addManual(pageIndex: Int, rect: PageRect, in id: DocumentID) {
        perform { try update(id) { try $0.addManualFinding(pageIndex: pageIndex, rect: rect) } }
    }

    func acknowledge(_ warning: UUID, in id: DocumentID) { update(id) { $0.acknowledgeWarning(warning) } }

    /// Confirms the review and (re)creates + validates the export for the current revision.
    func confirmAndExport(_ id: DocumentID) {
        guard let job = job(id), running[id] == nil else { return }
        let engine = engine, dpi = settings.exportDPI
        update(id) { $0.stage = .processing(.exporting) }
        running[id] = Task { [weak self] in
            let result = await engine.export(job: job, dpi: dpi)
            await MainActor.run {
                guard let self else { return }
                self.running[id] = nil
                self.update(id) { j in
                    j.stage = .review
                    switch result {
                    case .success(let rec):
                        j.export = rec
                        if rec.validated { try? j.confirmReview() } else {
                            j.warnings.append(ProcessingWarning(kind: .exportValidationFailed,
                                                                message: rec.validationMessages.joined(separator: "; ")))
                        }
                    case .failure(let e):
                        j.warnings.append(ProcessingWarning(kind: .exportValidationFailed, message: Self.describe(e)))
                    }
                }
            }
        }
    }

    func approve(_ id: DocumentID) { perform { try update(id) { try $0.approve() } } }
    func revokeApproval(_ id: DocumentID) { update(id) { $0.revokeApproval() } }

    // MARK: Transfer

    func transfer(_ id: DocumentID) {
        guard let job = job(id), running[id] == nil else { return }
        guard job.isApprovedForTransfer else { lastError = JobError.notApproved.description; return }
        let engine = engine
        update(id) { $0.transfer = .inProgress(revision: job.revision) }
        running[id] = Task { [weak self] in
            let result = await engine.transfer(job: job)
            await MainActor.run {
                guard let self else { return }
                self.running[id] = nil
                self.update(id) { j in
                    switch result {
                    case .success(let r):
                        j.transfer = .verified(revision: job.revision, remotePath: r.remoteName, sha256: r.sha256, date: Date())
                    case .failure(let e):
                        j.transfer = .failed(revision: job.revision, message: Self.describe(e))
                    }
                }
            }
        }
    }

    // MARK: Data control

    /// Removes the job and PaperVeil's working copies/exports. The original file is never touched.
    func remove(_ id: DocumentID) {
        cancel(id)
        perform { try repo.deleteWorkData(for: id) }
        jobs.removeAll { $0.id == id }
        if selection == id { selection = nil }
        persist()
    }

    func deleteAllLocalData() {
        for id in running.keys { running[id]?.cancel() }
        running = [:]
        perform { try repo.deleteAll() }
        jobs = []
        selection = nil
        try? engine.deleteSecrets()
    }

    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { lastError = Self.describe(error) }
    }
}
