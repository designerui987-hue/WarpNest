import SwiftUI
import WarpNestCore

struct BottlesView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingCreateBottleSheet = false
    @State private var newBottleName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wine Bottles")
                    .font(.title2)
                    .bold()

                Spacer()

                Button {
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
                    Button("Create First Bottle") {
                        showingCreateBottleSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.bottles) { bottle in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(bottle.name)
                                .font(.headline)
                            Spacer()
                            Text(bottle.configuration.graphicsBackend.displayName)
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
                                    try? await viewModel.bottleService.deleteBottle(id: bottle.id)
                                    await viewModel.reloadData()
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

                HStack {
                    Spacer()
                    Button("Cancel") {
                        showingCreateBottleSheet = false
                    }
                    Button("Create") {
                        Task {
                            try? await viewModel.createBottle(name: newBottleName.isEmpty ? "New Bottle" : newBottleName)
                            showingCreateBottleSheet = false
                            newBottleName = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 400)
        }
    }
}
