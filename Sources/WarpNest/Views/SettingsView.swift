import SwiftUI
import WarpNestCore

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var defaultSyncBackend: SyncBackend = .esync
    @State private var highResolutionEnabled = true

    var body: some View {
        Form {
            Section("Compatibility Runtime") {
                LabeledContent("Active Runtime Engine") {
                    Text("WarpNest Standard Runtime System")
                        .foregroundColor(.secondary)
                }
                LabeledContent("Wine Translation Mode") {
                    Text("WoW64 (32-bit & 64-bit on Apple Silicon)")
                        .foregroundColor(.secondary)
                }
            }

            Section("Performance & Rendering Defaults") {
                Picker("Default Thread Synchronization", selection: $defaultSyncBackend) {
                    ForEach(SyncBackend.allCases, id: \.self) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }
                Toggle("Enable High-DPI (Retina) scaling by default", isOn: $highResolutionEnabled)
            }

            Section("Storage & Paths") {
                LabeledContent("App Support Directory") {
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
