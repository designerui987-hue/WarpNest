import SwiftUI
import WarpNestCore

struct BottlesView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingCreateBottleSheet = false
    @State private var newBottleName = ""
    @State private var selectedRuntimeID: RuntimeID?
    @State private var syncBackend: SyncBackend = .esync
    @State private var is64Bit: Bool = true
    @State private var createError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wine Bottles")
                    .font(.title2)
                    .bold()

                Spacer()

                Button {
                    createError = nil
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

                            Button("Delete", role: .destructive) {
                                Task {
                                    do {
                                        try await viewModel.bottleService.deleteBottle(id: bottle.id)
                                        await viewModel.reloadData()
                                    } catch {
                                        viewModel.showError("Cannot delete bottle: \(error.localizedDescription)")
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
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
                                Text("\(r.name) (\(r.version))\(r.isSimulation ? " [SIMULATED]" : "")")
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
