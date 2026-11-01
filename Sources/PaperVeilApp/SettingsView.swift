import PaperVeilCore
import PaperVeilDetection
import PaperVeilTransfer
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Lokales LLM", systemImage: "cpu") { LLMSettingsView() }
            Tab("Sperrliste", systemImage: "list.bullet.rectangle") { BlocklistSettingsView() }
            Tab("Übertragung", systemImage: "arrow.up.doc") { TransferSettingsView() }
            Tab("Daten", systemImage: "externaldrive") { DataSettingsView() }
        }
        .padding()
    }
}

struct LLMSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var models: [String] = []
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("LLM-Prüfung für neue Dokumente verwenden", isOn: $model.settings.llmEnabled)
            TextField("Endpunkt (nur Loopback)", text: $model.settings.llmEndpoint)
            HStack {
                Button(checking ? "Prüfe…" : "Verbindung prüfen") { Task { await refresh() } }.disabled(checking)
                if let error {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                } else if !models.isEmpty {
                    Label("Erreichbar · \(models.count) Modell(e)", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }
            Picker("Modell (vom Server gemeldet)", selection: $model.settings.llmModel) {
                Text("– keins –").tag(String?.none)
                ForEach(models, id: \.self) { Text($0).tag(String?.some($0)) }
                if let m = model.settings.llmModel, !models.contains(m) { Text("\(m) (nicht gemeldet)").tag(String?.some(m)) }
            }
            Stepper("Timeout pro Seite: \(Int(model.settings.llmTimeoutSeconds)) s",
                    value: $model.settings.llmTimeoutSeconds, in: 30...900, step: 30)
            Text("Dokumenttext geht ausschließlich an diesen lokalen Server. Kein Cloud-Fallback, keine Telemetrie. "
                 + "Fällt das LLM aus, erscheint eine Warnung, die die Freigabe sperrt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        checking = true
        let r = await model.engine.llmStatus(endpoint: model.settings.llmEndpoint)
        models = r.models; error = r.error; checking = false
    }
}

struct BlocklistSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var list = Blocklist()
    @State private var value = ""
    @State private var category: IdentifierCategory = .name
    @State private var variants = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Persönliche Sperrliste: wird nur lokal gespeichert und nie übertragen. Varianten wie Groß/Klein, "
                 + "Umlaut-Umschreibung, „Nachname, Vorname“ und Trennzeichen in Nummern werden automatisch erkannt.")
                .font(.caption).foregroundStyle(.secondary)
            Table(list.entries) {
                TableColumn("Wert", value: \.value)
                TableColumn("Kategorie") { Text(PhaseText.category($0.category)) }
                TableColumn("Weitere Varianten") { Text($0.variants.joined(separator: ", ")) }
                TableColumn("") { e in
                    Button("Entfernen", role: .destructive) { list.entries.removeAll { $0 == e }; save() }
                }.width(80)
            }
            HStack {
                TextField("Wert", text: $value)
                Picker("", selection: $category) {
                    ForEach(IdentifierCategory.allCases, id: \.self) { Text(PhaseText.category($0)).tag($0) }
                }.frame(width: 160)
                TextField("Varianten (kommagetrennt)", text: $variants)
                Button("Hinzufügen") {
                    let v = variants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    list.entries.append(.init(value: value.trimmingCharacters(in: .whitespaces), category: category, variants: v))
                    value = ""; variants = ""; save()
                }.disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { list = model.engine.loadBlocklist() }
    }

    private func save() {
        do { try model.engine.saveBlocklist(list) } catch { model.lastError = AppModel.describe(error) }
    }
}

extension Blocklist.Entry: Identifiable {
    public var id: String { value + "|" + category.rawValue + "|" + variants.joined(separator: "|") }
}

struct DataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        Form {
            LabeledContent("Ablageort") {
                Text(model.paths.root.path).textSelection(.enabled).font(.caption.monospaced())
            }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.root]) }
            Stepper("Export-Auflösung: \(Int(model.settings.exportDPI)) dpi", value: Bindable(model).settings.exportDPI,
                    in: 150...600, step: 50)
            Button("Alle lokalen PaperVeil-Daten löschen…", role: .destructive) { confirm = true }
            Text("Löscht Warteschlange, Fundstellen, Exporte, Sperrliste, Einstellungen, bestätigte Hostschlüssel und "
                 + "Schlüsselbund-Einträge von PaperVeil. Originaldateien werden nicht angetastet. Kopien in Backups "
                 + "(Time Machine, Snapshots) bleiben möglich; eine sichere physische Löschung wird nicht versprochen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Wirklich alle lokalen PaperVeil-Daten löschen?", isPresented: $confirm) {
            Button("Löschen", role: .destructive) { model.deleteAllLocalData() }
        }
    }
}

struct TransferSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var port = 22
    @State private var user = ""
    @State private var identity = ""
    @State private var fetched: HostKey?
    @State private var pinned: [String] = []
    @State private var message: String?

    var body: some View {
        Form {
            Text("Übertragen werden nur freigegebene, bereinigte Exporte per SSH an ein Empfangsskript "
                 + "(receiver/paperveil-receive) als forced command. Keine Standardziele; private Hostnamen gehören nicht ins Repository.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Host", text: $host)
            TextField("Port", value: $port, format: .number.grouping(.never))
            TextField("Benutzer", text: $user)
            TextField("SSH-Schlüsseldatei (optional, z. B. ~/.ssh/paperveil_ed25519)", text: $identity)
            HStack {
                Button("Speichern") {
                    model.settings.transfer = host.isEmpty ? nil : TransferConfiguration(
                        host: host, port: port, user: user,
                        identityFilePath: identity.isEmpty ? nil : (identity as NSString).expandingTildeInPath)
                    message = "Gespeichert."
                }
                Button("Hostschlüssel abrufen") { Task { await fetch() } }.disabled(host.isEmpty)
            }
            if let fetched {
                VStack(alignment: .leading) {
                    Text("Abgerufener Schlüssel (\(fetched.keyType)):")
                    Text(fetched.fingerprint).font(.body.monospaced()).textSelection(.enabled)
                    Text("Vergleiche den Fingerabdruck über einen unabhängigen Kanal mit dem Server "
                         + "(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub). Nur bei Übereinstimmung bestätigen.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Fingerabdruck stimmt – Schlüssel festlegen") { pin(fetched) }
                }
            }
            LabeledContent("Festgelegte Hostschlüssel", value: "\(pinned.count)")
            Button("Festgelegte Hostschlüssel entfernen", role: .destructive) {
                try? model.engine.knownHosts.clear(); reload()
            }
            if let message { Text(message).font(.caption) }
        }
        .onAppear {
            if let t = model.settings.transfer {
                host = t.host; port = t.port; user = t.user; identity = t.identityFilePath ?? ""
            }
            reload()
        }
    }

    private func reload() { pinned = (try? model.engine.knownHosts.pinnedLines()) ?? [] }

    private func fetch() async {
        do { fetched = try await model.engine.knownHosts.fetchHostKey(host: host, port: port); message = nil }
        catch { message = AppModel.describe(error) }
    }

    private func pin(_ key: HostKey) {
        do { try model.engine.knownHosts.pin(key, confirmedFingerprint: key.fingerprint); fetched = nil; reload(); message = "Hostschlüssel festgelegt." }
        catch { message = AppModel.describe(error) }
    }
}
