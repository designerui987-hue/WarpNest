import SwiftUI
import WarpNestCore

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingImportPanel = false

    var body: some View {
        Form {
            Section("Compatibility Runtimes") {
                if viewModel.registeredRuntimes.isEmpty {
                    Text("No verified compatibility runtimes found. Import a Wine runtime layout to get started.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.registeredRuntimes) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(r.name)
                                    .bold()
                                Spacer()
                                if r.isSimulation {
                                    Text("Simulation Mode")
                                        .font(.caption2)
                                        .padding(3)
                                        .background(Color.orange.opacity(0.2))
                                        .foregroundColor(.orange)
                                        .cornerRadius(4)
                                } else {
                                    Text("Verified")
                                        .font(.caption2)
                                        .padding(3)
                                        .background(Color.green.opacity(0.2))
                                        .foregroundColor(.green)
                                        .cornerRadius(4)
                                }
                            }
                            Text(r.version)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(r.rootPath)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Button("Import Wine Runtime...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.message = "Select Wine installation root or Wine .app bundle"
                    if panel.runModal() == .OK, let url = panel.url {
                        Task {
                            try? await viewModel.importRuntime(from: url)
                        }
                    }
                }
            }

            Section("Development & Testing Mode") {
                Toggle("Enable Developer / Simulated Mode", isOn: $viewModel.appSettings.developerModeEnabled)
                    .onChange(of: viewModel.appSettings.developerModeEnabled) { _, _ in
                        Task {
                            await viewModel.saveSettings()
                            await viewModel.initializeApp()
                        }
                    }
                Text("When enabled, adds a mock simulation runtime for testing UI workflows without external Wine dependencies. Simulated runtimes are never presented as real Wine engines.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Performance & Rendering Defaults") {
                Picker("Default Thread Synchronization", selection: $viewModel.appSettings.defaultSyncBackend) {
                    ForEach(SyncBackend.allCases, id: \.self) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }
                .onChange(of: viewModel.appSettings.defaultSyncBackend) { _, _ in
                    Task { await viewModel.saveSettings() }
                }

                Toggle("Enable High-DPI (Retina) scaling by default", isOn: $viewModel.appSettings.defaultHighResolutionMode)
                    .onChange(of: viewModel.appSettings.defaultHighResolutionMode) { _, _ in
                        Task { await viewModel.saveSettings() }
                    }
            }

            Section("Storage & Paths") {
                LabeledContent("Application Support") {
                    Text(MetadataStore.defaultAppSupportDirectory.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
