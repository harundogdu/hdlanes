import AppKit
import HDCore
import SwiftUI

/// Changes tab: changed files against the session's base, the selected file's diff, review notes and PR.
struct ChangesView: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model
    @State private var selectedPath: String?

    var body: some View {
        let diff = model.diffs[sessionID]
        VStack(spacing: 0) {
            header(diff)
            Divider()
            content(diff)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ChangesFooter(sessionID: sessionID)
        }
        .onAppear { keepSelectionValid(diff?.files ?? []) }
        .onChange(of: diff?.files.map(\.path) ?? []) { keepSelectionValid(diff?.files ?? []) }
    }

    // MARK: Header

    private func header(_ diff: SessionDiff?) -> some View {
        HStack(spacing: 6) {
            if let diff, diff.hasLoaded, diff.isRepository {
                Text(verbatim: [L.filesCount(diff.files.count), diff.baseDescription].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            if diff?.isRefreshing == true {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 4)
            if let diff, diff.hasLoaded {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(updatedText(diff.updatedAt, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Button {
                Task { await model.refreshDiff(sessionID) }
            } label: {
                Label(L.refresh, systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(diff?.isRefreshing == true)
            .help(L.refreshChangesHelp)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func updatedText(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 10 ? L.updatedJustNow : L.updatedAgo(L.relative(date, now: now))
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ diff: SessionDiff?) -> some View {
        if let diff, diff.hasLoaded {
            if !diff.isRepository {
                CompactEmptyState(title: L.notRepositoryTitle, symbol: "folder.badge.questionmark",
                                  detail: L.notRepositoryDetail)
            } else if let error = diff.error, diff.files.isEmpty {
                CompactEmptyState(title: L.changesErrorTitle, symbol: "exclamationmark.triangle", detail: error,
                                  actionTitle: L.tryAgain) { Task { await model.refreshDiff(sessionID) } }
            } else if diff.files.isEmpty {
                CompactEmptyState(title: L.noChangesTitle, symbol: "checkmark.circle", detail: L.noChangesDetail,
                                  actionTitle: L.refresh) { Task { await model.refreshDiff(sessionID) } }
            } else {
                VStack(spacing: 0) {
                    if let error = diff.error {
                        InlineErrorBar(message: error)
                    }
                    VSplitView {
                        fileList(diff)
                            .frame(minHeight: 70, idealHeight: 170)
                        detail(diff)
                            .frame(minHeight: 120, maxHeight: .infinity)
                    }
                }
            }
        } else {
            ProgressView(L.loadingChanges)
                .controlSize(.small)
        }
    }

    private func fileList(_ diff: SessionDiff) -> some View {
        List(selection: $selectedPath) {
            ForEach(diff.files) { file in
                ChangedFileRow(file: file)
            }
            if diff.skippedUntracked > 0 {
                Text(L.untrackedSkipped(diff.skippedUntracked))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            if diff.isTruncated {
                Text(L.diffTruncated)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 20)
    }

    @ViewBuilder
    private func detail(_ diff: SessionDiff) -> some View {
        if let path = selectedPath, let file = diff.files.first(where: { $0.path == path }) {
            DiffView(sessionID: sessionID, file: file)
                .id(file.path)
        } else {
            Text(L.selectFile)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func keepSelectionValid(_ files: [DiffFile]) {
        if let selectedPath, files.contains(where: { $0.path == selectedPath }) { return }
        selectedPath = files.first?.path
    }
}

/// One file in the Changes list: status letter, name with its folder dimmed, line counts.
struct ChangedFileRow: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: L.statusLetter(file.status))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.color(for: file.status))
                .frame(width: 12)
                .help(L.statusName(file.status))
            (Text(verbatim: file.directory).foregroundStyle(.secondary) + Text(verbatim: file.fileName))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.head)
                .help(file.oldPath.map { "\(L.renamedFrom($0))\n\(file.path)" } ?? file.path)
            Spacer(minLength: 4)
            if file.additions > 0 {
                Text(verbatim: "+\(file.additions)").foregroundStyle(.green)
            }
            if file.deletions > 0 {
                Text(verbatim: "\u{2212}\(file.deletions)").foregroundStyle(.red)
            }
        }
        .font(.system(size: 11).monospacedDigit())
    }

    static func color(for status: DiffFileStatus) -> Color {
        switch status {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .modified, .renamed: return .orange
        case .binary: return .secondary
        }
    }
}

struct InlineErrorBar: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(verbatim: message)
                .font(.system(size: 11))
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.red.opacity(0.08))
    }
}

/// Notes count, "Send to Claude/Codex" and "Create PR…".
struct ChangesFooter: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model
    @State private var prInfo: PullRequestInfo?
    @State private var isPRSheetPresented = false

    var body: some View {
        let notes = model.reviewNotes[sessionID] ?? []
        let sendProblem = model.reviewNotesSendProblem(sessionID)
        HStack(spacing: 8) {
            Text(L.notesCount(notes.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(L.sendNotes(to: model.session(sessionID)?.provider ?? .shell)) {
                model.sendReviewNotes(sessionID)
            }
            .disabled(sendProblem != nil)
            .help(sendProblem ?? L.sendNotesHelp)
            CrossCheckControl(sessionID: sessionID)
            Spacer(minLength: 4)
            if let url = model.diffs[sessionID]?.pullRequestURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(L.openPullRequest, systemImage: "arrow.up.right.square").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(L.openPullRequest)
            }
            Button(L.createPRButton) { isPRSheetPresented = true }
                .disabled(prInfo == nil || prInfo?.problem != nil)
                .help(prInfo.map { $0.problem.map(L.describe) ?? L.createPRHelp } ?? L.prChecking)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Re-checked when the live branch changes (the diff refresh records it on the session).
        .task(id: "\(sessionID)|\(model.session(sessionID)?.branch ?? "")") {
            prInfo = await model.pullRequestInfo(sessionID: sessionID)
        }
        .sheet(isPresented: $isPRSheetPresented, onDismiss: {
            Task { prInfo = await model.pullRequestInfo(sessionID: sessionID) }
        }) {
            PullRequestSheet(sessionID: sessionID)
                .environment(model)
        }
    }
}

/// "Check with…" menu of Claude accounts and the last run's state.
struct CrossCheckControl: View {
    let sessionID: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        let accounts = model.crossCheckAccounts(for: sessionID)
        let own = model.session(sessionID)?.accountID
        let state = model.crossChecks[sessionID]
        let running: Bool = { if case .running = state { return true } else { return false } }()
        Menu(L.crossCheckButton) {
            ForEach(accounts) { account in
                Button(L.crossCheckWith(account.label, own: account.id == own)) {
                    Task { await model.runCrossCheck(sessionID: sessionID, accountID: account.id) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(accounts.isEmpty || running)
        .help(accounts.isEmpty ? L.crossCheckNoAccount : L.crossCheckHelp)
        switch state {
        case .running(let label):
            ProgressView().controlSize(.mini)
            Text(L.crossCheckRunning(label)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        case .done(let label, let n):
            Text(L.crossCheckDone(label, n)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1).help(message)
        case nil:
            EmptyView()
        }
    }
}
