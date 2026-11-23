import SwiftUI
import UniformTypeIdentifiers

/// 设置里的「备份」一节：导出、导入配置（逻辑在 ConfigBackup）。mac 的通用设置和 iOS 的设置页共用。
/// 提示都在这一节自己弹：iOS 的设置是弹出的面板，根视图的提示会被它挡住。
struct BackupSection: View {
    let model: AppModel
    @State private var showExportOptions = false
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    /// 加密的文件，等用户输口令
    @State private var encrypted: Data?
    @State private var askPassphrase = false
    @State private var passphrase = ""
    @State private var wrongPassphrase = false
    @State private var pending: PendingImport?
    @State private var message: String?

    var body: some View {
        Section {
            #if os(macOS)
            HStack { exportButton; importButton; Spacer() }
            #else
            exportButton
            importButton
            #endif
        } header: {
            Text("Backup")
        } footer: {
            Text("Exports servers, sites and the “Likely Unregistered” keywords, for moving them to another Mac or iPhone, for example through iCloud Drive. Importing adds and updates; nothing already here is removed.")
                .footnoteStyle()
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
        // 调试：TC_DEBUG_BACKUP=export 打开导出选项（截图用）
        .onAppear { if ProcessInfo.processInfo.environment["TC_DEBUG_BACKUP"] == "export" { showExportOptions = true } }
    }

    private var exportButton: some View {
        Button("Export Settings…") { showExportOptions = true }
                .sheet(isPresented: $showExportOptions, onDismiss: { if document != nil { exporting = true } }) {
                    ExportOptionsSheet(content: model.backupContent) { document = BackupDocument(data: $0) }
                }
                .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: Self.filename) { result in
                    document = nil
                    switch result {
                    case .success: message = L("Settings exported.")
                    case .failure(let error): if !Self.cancelled(error) { message = error.localizedDescription }
                    }
                }
    }

    private var importButton: some View {
        Button("Import Settings…") { importing = true }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    switch result {
                    case .success(let url): load(url)
                    case .failure(let error): if !Self.cancelled(error) { message = error.localizedDescription }
                    }
                }
                .alert("Enter Password", isPresented: $askPassphrase) {
                    SecureField("Password", text: $passphrase)
                    Button("Cancel", role: .cancel) { encrypted = nil; passphrase = "" }
                    Button("Open") {
                        if let data = encrypted { open(data, passphrase: passphrase) }
                        passphrase = ""
                    }
                } message: {
                    Text(wrongPassphrase ? "Wrong password. Try again." : "This file includes passwords and is encrypted. Enter the password set when it was exported.")
                }
                .confirmationDialog("Import Settings?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { p in
                    Button("Import") {
                        model.applyImport(p.content)
                        message = L("Settings imported.")
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { p in
                    Text(p.description)
                }
    }

    private static var filename: String { "Peerdeck \(Date.now.formatted(.iso8601.year().month().day()))" }

    private static func cancelled(_ error: Error) -> Bool { (error as? CocoaError)?.code == .userCancelled }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            open(try Data(contentsOf: url), passphrase: nil)
        } catch {
            message = error.localizedDescription
        }
    }

    private func open(_ data: Data, passphrase: String?) {
        Task {
            do {
                // 派生密钥要几十到几百毫秒，不放在主线程
                let content = try await Task.detached { try ConfigBackup.read(data, passphrase: passphrase) }.value
                encrypted = nil
                wrongPassphrase = false
                let summary = model.importPreview(content)
                if summary.isEmpty {
                    message = L("Nothing to import: everything in this file is already here.")
                } else {
                    pending = PendingImport(content: content, summary: summary)
                }
            } catch ConfigBackup.Failure.needsPassphrase {
                encrypted = data
                wrongPassphrase = false
                askPassphrase = true
            } catch ConfigBackup.Failure.wrongPassphrase {
                encrypted = data
                wrongPassphrase = true
                askPassphrase = true
            } catch {
                encrypted = nil
                message = error.localizedDescription
            }
        }
    }
}

private struct PendingImport {
    let content: ConfigBackup.Content
    let summary: ConfigBackup.Summary

    var description: String {
        let s = summary
        var lines = [
            L("Servers: \(s.addedServers) new, \(s.updatedServers) changed."),
            L("Sites: \(s.addedSites) new, \(s.updatedSites) changed."),
        ]
        if s.addedKeywords > 0 { lines.append(L("Keywords: \(s.addedKeywords) new.")) }
        if !s.includesSecrets {
            lines.append(L("This file has no passwords. Servers already here keep theirs; enter the passwords for new servers in Settings."))
        }
        return lines.joined(separator: "\n")
    }
}

/// 导出选项：要不要带密码；带的话设一个口令加密
private struct ExportOptionsSheet: View {
    let content: ConfigBackup.Content
    let onExport: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var includeSecrets = true
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var error: String?

    private var valid: Bool {
        !includeSecrets || (passphrase.count >= ConfigBackup.minPassphrase && passphrase == confirmation)
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            form
                .navigationTitle("Export Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { exportButton }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 0) {
            Text("Export Settings").font(.headline).padding([.horizontal, .top], 20)
            form.frame(height: includeSecrets ? 250 : 150)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                exportButton.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Toggle("Include passwords", isOn: $includeSecrets)
                if includeSecrets {
                    SecureField("Password", text: $passphrase)
                    SecureField("Confirm Password", text: $confirmation)
                }
            } footer: {
                Group {
                    if includeSecrets {
                        Text("The file is encrypted with this password (at least \(ConfigBackup.minPassphrase) characters). You’ll need it to import the file; it can’t be recovered.")
                    } else {
                        Text("Passwords, API keys, reverse proxy passwords and custom header values are left out. Enter them again after importing.")
                    }
                }
                .footnoteStyle()
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .disabled(working)
    }

    private var exportButton: some View {
        Button("Export") {
            working = true
            let secret = includeSecrets ? passphrase : nil
            let content = content
            Task {
                do {
                    let data = try await Task.detached { try ConfigBackup.export(content, passphrase: secret) }.value
                    onExport(data)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                    working = false
                }
            }
        }
        .disabled(!valid || working)
    }
}

private extension View {
    /// 表单脚注：mac 的分组表单不给脚注套样式，多行时还会靠右，按设置页其他说明文字的样子来；iOS 用系统的
    @ViewBuilder func footnoteStyle() -> some View {
        #if os(macOS)
        font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
        self
        #endif
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
