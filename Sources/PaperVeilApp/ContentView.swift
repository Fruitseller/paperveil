import PaperVeilCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.jobs) { job in
                    QueueRow(job: job).tag(job.id)
                        .contextMenu {
                            Button("Abbrechen") { model.cancel(job.id) }.disabled(!job.isBusy)
                            Button("Wiederholen") { model.retry(job.id) }.disabled(job.isBusy)
                            Divider()
                            Button("Aus Liste entfernen und Arbeitsdaten löschen", role: .destructive) { model.remove(job.id) }
                        }
                }
            }
            .overlay {
                if model.jobs.isEmpty {
                    ContentUnavailableView("PDFs hierher ziehen", systemImage: "doc.badge.plus",
                                           description: Text("Originale werden nie verändert. Exporte sind separate Kopien."))
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .toolbar {
                Button("PDFs hinzufügen", systemImage: "plus") { importing = true }
            }
        } detail: {
            if let id = model.selection, let job = model.job(id) {
                ReviewView(job: job)
            } else {
                ContentUnavailableView("Kein Dokument ausgewählt", systemImage: "doc.text.magnifyingglass")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls.filter(\.isFileURL)); return true
        } isTargeted: { dropTargeted = $0 }
        .border(dropTargeted ? Color.accentColor : .clear, width: 3)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { model.add(urls: urls) }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: { Text(model.lastError ?? "") }
    }
}

struct StatusBadge: View {
    let job: Job
    var body: some View {
        let s = job.displayStatus
        Text(s.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color(s).opacity(0.18), in: .capsule)
            .foregroundStyle(color(s))
    }
    func color(_ s: DisplayStatus) -> Color {
        switch s {
        case .waiting, .cancelled: .secondary
        case .processing, .transferring: .blue
        case .needsReview: .orange
        case .readyForApproval: .teal
        case .approved: .indigo
        case .transferred: .green
        case .failed: .red
        }
    }
}

struct QueueRow: View {
    let job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.id.rawValue).font(.body.monospaced())
                Spacer()
                StatusBadge(job: job)
            }
            Group {
                switch job.stage {
                case .processing(let p): Label(PhaseText.text(p), systemImage: "gearshape.2")
                case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                default:
                    if case .failed(_, let m) = job.transfer {
                        Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else {
                        Text("Rev. \(job.revision) · \(job.pageCount) Seite(n)")
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

enum PhaseText {
    static func text(_ p: ProcessingPhase) -> String {
        switch p {
        case .validatingInput: "Eingabe prüfen"
        case .extractingText: "Text extrahieren"
        case .ocr: "OCR"
        case .rules: "Sperrliste & Regeln"
        case .llm: "Lokales LLM"
        case .exporting: "Export erzeugen"
        case .validatingExport: "Export prüfen"
        }
    }

    static func category(_ c: IdentifierCategory) -> String {
        switch c {
        case .name: "Name"
        case .address: "Anschrift"
        case .birthDate: "Geburtsdatum"
        case .phone: "Telefon"
        case .email: "E-Mail"
        case .insuranceNumber: "Versicherungsnr."
        case .patientID: "Patienten-/Fall-ID"
        case .other: "Sonstiges"
        case .image: "Bildbereich"
        }
    }

    static func origin(_ o: FindingOrigin) -> String {
        switch o {
        case .blocklist: "Sperrliste"
        case .rule: "Regel"
        case .llm: "LLM"
        case .manual: "Manuell"
        }
    }
}
