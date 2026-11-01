import PaperVeilCore
import SwiftUI

struct ReviewView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var highlighted: UUID?
    @State private var marking = false

    private var exportURL: URL? {
        guard let e = job.export else { return nil }
        return model.paths.workDir(for: job.id).appendingPathComponent(e.fileName)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                paneHeader("Original (nur Ansicht)", detail: marking ? "Bereich aufziehen, um ihn zu schwärzen" : nil)
                OriginalPDFView(url: URL(fileURLWithPath: job.originalPath), findings: job.findings, highlighted: highlighted,
                                markingEnabled: marking && !job.isBusy) { page, rect in
                    model.addManual(pageIndex: page, rect: rect, in: job.id)
                }
            }
            .frame(minWidth: 260, idealWidth: 420)
            VStack(spacing: 0) {
                paneHeader("Bereinigte Vorschau", detail: exportCaption)
                if exportURL != nil {
                    ExportPDFView(url: exportURL)
                } else {
                    ContentUnavailableView("Noch kein Export", systemImage: "doc")
                }
            }
            .frame(minWidth: 260, idealWidth: 420)
            inspector.frame(minWidth: 340, idealWidth: 380, maxWidth: 480)
        }
        .toolbar {
            Toggle(isOn: $marking) { Label("Bereich markieren", systemImage: "rectangle.dashed") }
                .disabled(job.isBusy)
        }
        .navigationTitle(job.id.rawValue)
    }

    private var exportCaption: String? {
        guard let e = job.export else { return nil }
        if e.revision != job.revision { return "Veraltet (Rev. \(e.revision)); aktuelle Rev. \(job.revision)" }
        return e.validated ? "Rev. \(e.revision) · validiert" : "Rev. \(e.revision) · Validierung fehlgeschlagen"
    }

    private func paneHeader(_ title: String, detail: String?) -> some View {
        HStack {
            Text(title).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(8).background(.bar)
    }

    @ViewBuilder private var inspector: some View {
        List {
            Section {
                HStack { StatusBadge(job: job); Spacer(); Text("Rev. \(job.revision)").foregroundStyle(.secondary) }
                Text("PaperVeil schlägt Schwärzungen vor, garantiert aber keine Anonymität. Bitte jede Seite selbst prüfen.")
                    .font(.caption).foregroundStyle(.secondary)
                actions
            }

            if !job.warnings.isEmpty {
                Section("Warnungen (blockieren die Freigabe bis zur Bestätigung)") {
                    ForEach(job.warnings) { w in
                        HStack(alignment: .top) {
                            Image(systemName: w.acknowledged ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                .foregroundStyle(w.acknowledged ? .green : .orange)
                            VStack(alignment: .leading) {
                                Text(w.message).font(.callout)
                                if let p = w.pageIndex { Text("Seite \(p + 1)").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if !w.acknowledged {
                                Button("Geprüft") { model.acknowledge(w.id, in: job.id) }.disabled(job.isBusy)
                            }
                        }
                    }
                }
            }

            Section("Fundstellen (\(job.findings.filter(\.isRedacted).count) geschwärzt)") {
                ForEach(job.findings) { f in
                    FindingRow(finding: f, busy: job.isBusy) { d in
                        model.setDecision(d, finding: f.id, in: job.id)
                    }
                    .contentShape(.rect)
                    .onTapGesture { highlighted = f.id }
                    .listRowBackground(highlighted == f.id ? Color.accentColor.opacity(0.15) : nil)
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        let blockers = job.approvalBlockers
        VStack(alignment: .leading, spacing: 6) {
            if job.isBusy {
                Button("Abbrechen", role: .destructive) { model.cancel(job.id) }
            }
            switch job.stage {
            case .failed, .cancelled:
                Button("Wiederholen") { model.retry(job.id) }
            case .review:
                Button("Prüfung bestätigen & Export erzeugen") { model.confirmAndExport(job.id) }
                    .disabled(job.isBusy || job.findings.contains { $0.decision == .proposed })
                if job.isApprovedForTransfer {
                    Button("Freigabe zurückziehen") { model.revokeApproval(job.id) }
                    Button("An Empfänger übertragen") { model.transfer(job.id) }.disabled(job.isBusy)
                } else {
                    Button("Diese Revision zur Übertragung freigeben") { model.approve(job.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!blockers.isEmpty)
                }
                if !blockers.isEmpty {
                    Text("Freigabe gesperrt: " + blockers.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                transferInfo
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var transferInfo: some View {
        switch job.transfer {
        case .verified(let rev, let path, let sha, _):
            Text("Übertragen und vom Empfänger per SHA-256 bestätigt (Rev. \(rev)): \(path)\n\(sha)")
                .font(.caption.monospaced()).textSelection(.enabled)
        case .failed(let rev, let msg):
            Text("Übertragung Rev. \(rev) fehlgeschlagen: \(msg)").font(.caption).foregroundStyle(.red)
        case .inProgress: ProgressView("Übertragung läuft…")
        case nil: EmptyView()
        }
    }
}

struct FindingRow: View {
    let finding: Finding
    let busy: Bool
    let decide: @MainActor @Sendable (FindingDecision) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.text.isEmpty ? "Markierter Bereich" : finding.text)
                    .lineLimit(2).strikethrough(finding.decision == .rejected)
                Text("\(PhaseText.category(finding.category)) · \(PhaseText.origin(finding.origin)) · S. \(finding.pageIndex + 1)")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = finding.note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("", selection: Binding(get: { finding.decision }, set: decide)) {
                Text("?").accessibilityLabel("Ungeprüft").tag(FindingDecision.proposed)
                Image(systemName: "eye.slash").accessibilityLabel("Schwärzen").tag(FindingDecision.accepted)
                Image(systemName: "eye").accessibilityLabel("Nicht schwärzen").tag(FindingDecision.rejected)
            }
            .pickerStyle(.segmented).fixedSize().disabled(busy)
            .accessibilityLabel("Entscheidung")
            .help("? = ungeprüft · durchgestrichenes Auge = schwärzen · Auge = nicht schwärzen")
        }
    }
}
