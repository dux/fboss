import SwiftUI
import AppKit

/// Hammerfile preview doubles as a task runner: tasks come from `hammer h:json`, and clicking
/// one runs it in the Hammerfile's own directory with output streamed in below the list.
struct HammerfilePreviewView: View {
    let url: URL

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var runner = HammerTaskRunner()
    @State private var groups: [HammerTaskGroup] = []
    @State private var usedFallback = false
    @State private var isLoading = true

    private static let outputBottom = "hammer-output-bottom"

    private var directory: URL { url.deletingLastPathComponent() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PreviewHeader(title: "Hammerfile", icon: "hammer.fill", color: .orange)

                Spacer()

                FontSizeControls(settings: settings)
            }
            Divider()

            if isLoading {
                statusRow("Loading tasks...")
            } else if groups.isEmpty {
                statusRow("No tasks found")
            } else {
                taskList
            }

            if runner.hasRun {
                Divider()
                outputSection
            }
        }
        .task(id: url) { await load() }
        .onDisappear { runner.stop() }
    }

    // MARK: - Task list

    private var taskList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if usedFallback {
                    Text("hammer not found -- tasks read from the file")
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }

                ForEach(groups) { group in
                    if !group.namespace.isEmpty {
                        Text(group.namespace)
                            .textStyle(.title)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }

                    ForEach(group.tasks) { task in
                        HammerTaskRow(
                            task: task,
                            isRunning: runner.runningTask == task.path,
                            isDisabled: runner.isRunning
                        ) {
                            runner.run(task, in: directory)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: runner.hasRun ? 240 : .infinity)
    }

    private func statusRow(_ text: String) -> some View {
        VStack {
            Text(text)
                .textStyle(.small)
                .foregroundColor(.secondary)
                .padding(16)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Output

    private var outputSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("hammer \(runner.currentTask ?? "")")
                    .textStyle(.small, mono: true)
                    .foregroundColor(.secondary)

                if runner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }

                Spacer()

                if let code = runner.exitCode {
                    Text("exit: \(code)")
                        .textStyle(.small, mono: true)
                        .foregroundColor(code == 0 ? .green : .red)
                }

                if runner.isRunning {
                    Button(action: { runner.stop() }) {
                        Text("Stop")
                            .textStyle(.small)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Text(runner.output)
                            .textStyle(.small, mono: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)

                        Color.clear
                            .frame(height: 1)
                            .id(Self.outputBottom)
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: runner.output) { _ in
                    proxy.scrollTo(Self.outputBottom, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        runner.reset()
        isLoading = true

        let fileURL = url
        let result = await Task.detached(priority: .userInitiated) {
            HammerTaskLoader.load(hammerfile: fileURL)
        }.value

        groups = result.groups
        usedFallback = result.usedFallback
        isLoading = false
    }
}

// MARK: - Row

private struct HammerTaskRow: View {
    let task: HammerTask
    let isRunning: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "play.fill")
                            .textStyle(.small)
                            .foregroundColor(isHovered ? .accentColor : .secondary)
                    }
                }
                .frame(width: 16)

                Text(task.name)
                    .textStyle(.buttons, mono: true)
                    .foregroundColor(.primary)

                if !task.desc.isEmpty {
                    Text(task.desc)
                        .textStyle(.small)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .rowHighlight(isHovered: isHovered && !isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isRunning ? 0.5 : 1)
        .onHover { isHovered = $0 }
        .padding(.horizontal, 6)
    }
}
