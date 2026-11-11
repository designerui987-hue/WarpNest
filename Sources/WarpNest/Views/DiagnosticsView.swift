import SwiftUI
import WarpNestCore

struct DiagnosticsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingCopiedAlert = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("System Diagnostics & Logs")
                    .font(.title2)
                    .bold()

                Spacer()

                Button {
                    let text = viewModel.diagnosticsService.exportDiagnosticReport()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    showingCopiedAlert = true
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
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
                    }

                    GroupBox("Recent Execution Logs") {
                        if viewModel.liveLogs.isEmpty {
                            Text("No recent log activity. Launch a game or initialize a bottle to view live supervisor output.")
                                .foregroundColor(.secondary)
                                .padding(8)
                        } else {
                            ScrollView {
                                Text(viewModel.liveLogs.joined(separator: "\n"))
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
    }
}
