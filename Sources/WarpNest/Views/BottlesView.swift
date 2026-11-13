import SwiftUI
import WarpNestCore
import AppKit

struct BottlesView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingCreateBottleSheet = false
    @State private var newBottleName = ""
    @State private var selectedRuntimeID: RuntimeID?
    @State private var syncBackend: SyncBackend = .esync
    @State private var is64Bit: Bool = true
    @State private var createError: String?

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
                Text("Wine Bottles")
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
                    createError = nil
                    syncBackend = viewModel.appSettings.defaultSyncBackend
                    showingCreateBottleSheet = true
                } label: {
                    Label("New Bottle", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if viewModel.bottles.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Bottles Found")
                        .font(.title2)
                        .bold()
                    Text("Bottles are isolated Windows environments that hold your games, registry, and dependencies.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)

                    if viewModel.registeredRuntimes.isEmpty {
                        Text("No verified compatibility runtimes found. Please import a Wine runtime or enable Developer Mode in Settings.")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button("Create First Bottle") {
                        createError = nil
                        syncBackend = viewModel.appSettings.defaultSyncBackend
                        showingCreateBottleSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.registeredRuntimes.isEmpty)
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
                Text("Create New Bottle")
                    .font(.headline)

                TextField("Bottle Name (e.g. Steam Games)", text: $newBottleName)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Compatibility Runtime")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if viewModel.registeredRuntimes.isEmpty {
                        Text("No verified runtimes registered. Install Wine or enable Developer Mode.")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else {
                        Picker("Runtime", selection: $selectedRuntimeID) {
                            Text("Select runtime...").tag(nil as RuntimeID?)
                            ForEach(viewModel.registeredRuntimes) { r in
                                Text("\(r.name) (\(r.version))\(r.isSimulation ? " [SIMULATED]" : (r.isVerified ? "" : " [UNVERIFIED]"))")
                                    .tag(r.id as RuntimeID?)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Threading Synchronization")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Sync Backend", selection: $syncBackend) {
                        ForEach(SyncBackend.allCases, id: \.self) { backend in
                            Text(backend.rawValue).tag(backend)
                        }
                    }
                }

                Toggle("64-bit Architecture (WoW64)", isOn: $is64Bit)

                if let err = createError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        showingCreateBottleSheet = false
                    }
                    Button("Create") {
                        let targetRuntimeID = selectedRuntimeID ?? viewModel.registeredRuntimes.first?.id
                        guard let runtimeID = targetRuntimeID else {
                            createError = "Please select a verified runtime."
                            return
                        }

                        let config = BottleConfiguration(
                            win64: is64Bit,
                            graphicsBackend: .automatic,
                            syncBackend: syncBackend,
                            highResolutionMode: viewModel.appSettings.defaultHighResolutionMode
                        )

                        Task {
                            do {
                                try await viewModel.createBottle(
                                    name: newBottleName.isEmpty ? "New Bottle" : newBottleName,
                                    runtimeID: runtimeID,
                                    configuration: config
                                )
                                showingCreateBottleSheet = false
                                newBottleName = ""
                                createError = nil
                            } catch {
                                createError = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.registeredRuntimes.isEmpty)
                }
            }
            .padding()
            .frame(width: 440)
        }
    }
}
