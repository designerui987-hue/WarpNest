import SwiftUI
import WarpNestCore

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingImportPanel = false

    var body: some View {
        Form {
            Section("Compatibility Runtimes") {
                if viewModel.registeredRuntimes.isEmpty {
                    Text("Wine runs compatible Windows games and apps on your Mac. If Wine is already installed, choose its app or installation folder below.")
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
                                } else if r.isVerified {
                                    Text("Verified")
                                        .font(.caption2)
                                        .padding(3)
                                        .background(Color.green.opacity(0.2))
                                        .foregroundColor(.green)
                                        .cornerRadius(4)
                                } else {
                                    Text("Unverified")
                                        .font(.caption2)
                                        .padding(3)
                                        .background(Color.red.opacity(0.2))
                                        .foregroundColor(.red)
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

                if viewModel.registeredRuntimes.allSatisfy({ !$0.isVerified || $0.isSimulation }) {
                    Link("Get Wine for macOS", destination: URL(string: "https://gitlab.winehq.org/wine/wine/-/wikis/MacOS")!)
                }
                Button("Choose Wine Installation…") {
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
                            await viewModel.updateSimulationRuntime()
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
                Text("Stored configuration preference. Effective High-DPI rendering requires Wine Mac driver RetinaMode support in the prefix.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
