import SwiftUI
import WarpNestCore

struct DiagnosticsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var liveLogs: [String] = []

    private struct LogSelection: Equatable {
        let id: GameID?
        let state: SessionState
    }

    var body: some View {
        let gameID = viewModel.selectedGameID
        let selection = LogSelection(id: gameID, state: gameID.flatMap { viewModel.activeSessionStates[$0] } ?? .stopped)
        VStack(spacing: 0) {
            HStack {
                Text("System Diagnostics & Logs")
                    .font(.title2)
                    .bold()

                Spacer()

                Button {
                    guard let snapshot = viewModel.diagnostics else { return }
                    let text = viewModel.diagnosticsService.exportDiagnosticReport(snapshot)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.diagnostics == nil)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let diag = viewModel.diagnostics {
                        GroupBox("System Environment") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("macOS Version:")
                                        .bold()
                                    Spacer()
                                    Text(diag.osVersion)
                                }
                                Divider()
                                HStack {
                                    Text("Architecture:")
                                        .bold()
                                    Spacer()
                                    Text(diag.architecture)
                                }
                                Divider()
                                HStack {
                                    Text("Rosetta 2 Translation:")
                                        .bold()
                                    Spacer()
                                    Text(diag.rosettaActive ? "Active & Verified" : "Inactive / Not Required")
                                        .foregroundColor(diag.rosettaActive ? .green : .secondary)
                                }
                                Divider()
                                HStack {
                                    Text("Physical Memory:")
                                        .bold()
                                    Spacer()
                                    Text(String(format: "%.1f GB", diag.physicalMemoryGB))
                                }
                                Divider()
                                HStack {
                                    Text("Free Storage Space:")
                                        .bold()
                                    Spacer()
                                    Text(String(format: "%.1f GB", diag.freeDiskSpaceGB))
                                }
                            }
                            .padding(8)
                        }
                    } else {
                        ProgressView("Checking your Mac…")
                    }

                    GroupBox("Recent Execution Logs") {
                        if liveLogs.isEmpty {
                            Text("Launch a game or app to see its recent activity here.")
                                .foregroundColor(.secondary)
                                .padding(8)
                        } else {
                            ScrollView {
                                Text(liveLogs.joined(separator: "\n"))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 240)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }
                .padding()
            }
        }
        .task { await viewModel.refreshDiagnostics() }
        .task(id: selection) {
            guard let id = selection.id else {
                liveLogs = []
                return
            }
            let buffer = await viewModel.libraryService.getLogBuffer(for: id)
            while !Task.isCancelled {
                let lines = buffer.getAllLines()
                if liveLogs != lines { liveLogs = lines }
                // Inactive sessions need only their final snapshot.
                guard selection.state != .stopped && selection.state != .failed else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}
