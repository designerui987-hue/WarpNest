import SwiftUI
import WarpNestCore
import AppKit

struct BottlesView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingCreateBottleSheet = false
    @State private var newBottleName = ""
    @State private var selectedRuntimeID: RuntimeID?
    @State private var syncBackend: SyncBackend = .esync
    @State private var graphicsBackend: GraphicsBackend = .automatic
    @State private var is64Bit: Bool = true
    @State private var createError: String?
    @State private var isCreating = false
    @State private var showsAdvancedOptions = false

    private var availableRuntimes: [RuntimeDescriptor] {
        viewModel.registeredRuntimes.filter {
            $0.isVerified && (!$0.isSimulation || viewModel.appSettings.developerModeEnabled)
        }.sorted {
            if $0.isSimulation != $1.isSimulation { return !$0.isSimulation }
            return $0.rootPath < $1.rootPath
        }
    }

    private func beginCreation() {
        newBottleName = ""
        selectedRuntimeID = availableRuntimes.first?.id
        graphicsBackend = .automatic
        syncBackend = viewModel.appSettings.defaultSyncBackend
        is64Bit = true
        showsAdvancedOptions = false
        createError = nil
        showingCreateBottleSheet = true
    }

    // Backup & Restore state
    @State private var showingRestoreSheet = false
    @State private var restoreArchiveURL: URL?
    @State private var restoreBottleName = ""
    @State private var restoreRuntimeID: RuntimeID?
    @State private var restoreError: String?
    @State private var isBackingUp = false
    @State private var isRestoring = false

    // Deletion confirmation state
    @State private var bottleToDelete: Bottle?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Windows Environments")
                    .font(.title2)
                    .bold()

                Spacer()

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.zip]
                    panel.message = "Select a WarpNest bottle backup archive (.zip)"
                    if panel.runModal() == .OK, let url = panel.url {
                        restoreArchiveURL = url
                        restoreBottleName = url.deletingPathExtension().lastPathComponent
                        restoreRuntimeID = viewModel.registeredRuntimes.first(where: { $0.isVerified })?.id ?? viewModel.registeredRuntimes.first?.id
                        restoreError = nil
                        showingRestoreSheet = true
                    }
                } label: {
                    Label("Restore Bottle...", systemImage: "arrow.clockwise.icloud")
                }
                .disabled(isRestoring)

                Button {
                    beginCreation()
                } label: {
                    Label("New Environment", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(availableRuntimes.isEmpty)
            }
            .padding()

            Divider()

            if viewModel.bottles.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Set up a Windows environment")
                        .font(.title2.bold())
                    Text("An environment holds the Windows files and settings for your games and apps.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)

                    if availableRuntimes.isEmpty {
                        Button("Set Up Wine in Settings") { viewModel.selectedTab = .settings }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Create Environment", action: beginCreation)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.bottles) { bottle in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(bottle.name)
                                .font(.headline)
                            if bottle.runtimeID.rawValue == "test-simulation" {
                                Text("SIMULATED")
                                    .font(.caption2)
                                    .bold()
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundColor(.orange)
                                    .cornerRadius(4)
                            }
                            Spacer()
                            Text(bottle.configuration.syncBackend.rawValue)
                                .font(.caption)
                                .padding(4)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(4)
                        }

                        Text(bottle.directoryPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)

                        HStack {
                            Text("Created: \(bottle.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()

                            Button {
                                let panel = NSSavePanel()
                                panel.canCreateDirectories = true
                                panel.nameFieldStringValue = "\(bottle.name).zip"
                                panel.allowedContentTypes = [.zip]
                                panel.message = "Choose destination for bottle backup archive"
                                if panel.runModal() == .OK, let dest = panel.url {
                                    isBackingUp = true
                                    Task {
                                        do {
                                            try await viewModel.backupBottle(id: bottle.id, to: dest)
                                        } catch {
                                            viewModel.showError("Backup failed: \(error.localizedDescription)")
                                        }
                                        isBackingUp = false
                                    }
                                }
                            } label: {
                                Label("Backup...", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isBackingUp)

                            Button("Delete", role: .destructive) {
                                bottleToDelete = bottle
                                showingDeleteConfirmation = true
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .confirmationDialog(
            "Delete Bottle?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible,
            presenting: bottleToDelete
        ) { bottle in
            Button("Delete '\(bottle.name)'", role: .destructive) {
                Task {
                    do {
                        try await viewModel.bottleService.deleteBottle(id: bottle.id)
                        await viewModel.reloadData()
                    } catch {
                        viewModel.showError("Cannot delete bottle: \(error.localizedDescription)")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { bottle in
            Text("Are you sure you want to delete '\(bottle.name)'? This permanently deletes the Windows prefix, installed games, and all local game saves. This action cannot be undone.")
        }
        .sheet(isPresented: $showingRestoreSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Restore Bottle from Backup")
                    .font(.headline)

                if let archive = restoreArchiveURL {
                    Text("Archive: \(archive.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                TextField("Restored Bottle Name", text: $restoreBottleName)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Target Runtime")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Runtime", selection: $restoreRuntimeID) {
                        ForEach(viewModel.registeredRuntimes) { r in
                            Text("\(r.name) (\(r.version))\(r.isSimulation ? " [SIMULATED]" : (r.isVerified ? "" : " [UNVERIFIED]"))")
                                .tag(r.id as RuntimeID?)
                        }
                    }
                }

                if let err = restoreError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        showingRestoreSheet = false
                    }
                    Button("Restore") {
                        guard let archiveURL = restoreArchiveURL else { return }
                        let targetID = restoreRuntimeID ?? viewModel.registeredRuntimes.first?.id
                        guard let runtimeID = targetID else {
                            restoreError = "Please select a runtime."
                            return
                        }

                        isRestoring = true
                        Task {
                            do {
                                _ = try await viewModel.restoreBottle(
                                    from: archiveURL,
                                    name: restoreBottleName.isEmpty ? "Restored Bottle" : restoreBottleName,
                                    runtimeID: runtimeID
                                )
                                showingRestoreSheet = false
                                restoreError = nil
                            } catch {
                                restoreError = error.localizedDescription
                            }
                            isRestoring = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRestoring || viewModel.registeredRuntimes.isEmpty)
                }
            }
            .padding()
            .frame(width: 440)
        }
        .sheet(isPresented: $showingCreateBottleSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Windows Environment")
                    .font(.title2.bold())

                TextField("Environment name (for example, Steam Games)", text: $newBottleName)
                    .textFieldStyle(.roundedBorder)

                Picker("Wine runtime", selection: $selectedRuntimeID) {
                    ForEach(availableRuntimes) { runtime in
                        Text(runtime.isSimulation ? "Simulated runtime (testing only)" : "\(runtime.name) · \(runtime.version)")
                            .tag(runtime.id as RuntimeID?)
                    }
                }

                DisclosureGroup("Advanced options", isExpanded: $showsAdvancedOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Synchronization", selection: $syncBackend) {
                            ForEach(SyncBackend.allCases, id: \.self) { backend in
                                Text(backend.rawValue).tag(backend)
                            }
                        }
                        Picker("Graphics", selection: $graphicsBackend) {
                            ForEach(GraphicsBackend.allCases.filter { $0.isSupported }, id: \.self) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        Toggle("64-bit environment", isOn: $is64Bit)
                    }
                    .padding(.top, 8)
                }

                if let createError {
                    Text(createError).foregroundStyle(.red)
                }

                HStack {
                    if isCreating {
                        ProgressView().controlSize(.small)
                        Text("Preparing Windows files…")
                    }
                    Spacer()
                    Button("Cancel") { showingCreateBottleSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") {
                        guard !isCreating, let runtimeID = selectedRuntimeID,
                              availableRuntimes.contains(where: { $0.id == runtimeID }) else { return }
                        let config = BottleConfiguration(
                            win64: is64Bit, graphicsBackend: graphicsBackend, syncBackend: syncBackend,
                            highResolutionMode: viewModel.appSettings.defaultHighResolutionMode
                        )
                        let name = newBottleName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let firstEnvironment = viewModel.bottles.isEmpty
                        isCreating = true
                        createError = nil
                        Task {
                            defer { isCreating = false }
                            do {
                                try await viewModel.createBottle(name: name, runtimeID: runtimeID, configuration: config)
                                showingCreateBottleSheet = false
                                if firstEnvironment { viewModel.selectedTab = .library }
                            } catch {
                                createError = error.localizedDescription
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newBottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedRuntimeID == nil)
                }
            }
            .disabled(isCreating)
            .interactiveDismissDisabled(isCreating)
            .padding(24)
            .frame(width: 460)
        }
    }
}
