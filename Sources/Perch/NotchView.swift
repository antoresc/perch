import PerchCore
import SwiftUI

/// Fixed sizes shared by the views and the window, so the panel is always exactly as big as its content.
enum NotchLayout {
    static let wing: CGFloat = 46
    static let rowHeight: CGFloat = 40
    static let approvalHeight: CGFloat = 176
    static let footerHeight: CGFloat = 30
    static let bottomPadding: CGFloat = 6
    static let maxRows = 8

    static let questionTextHeight: CGFloat = 40
    static let optionHeight: CGFloat = 34
    static let cardFooterHeight: CGFloat = 32

    static func band(_ m: NotchMetrics) -> CGFloat { max(m.barHeight, 28) }

    static func cardHeight(_ a: PendingApproval) -> CGFloat {
        guard a.isQuestion else { return approvalHeight }
        let body = a.questions.reduce(CGFloat(0)) {
            $0 + questionTextHeight + CGFloat($1.options.count) * optionHeight
        }
        return 20 + 20 + body + cardFooterHeight + 8
    }
    static func expandedWidth(_ m: NotchMetrics) -> CGFloat { max(440, m.notchWidth + 220) }

    static func collapsedSize(_ model: AppModel) -> CGSize {
        let m = model.metrics
        if model.sessions.isEmpty {
            // On a notch this sits invisibly over the notch so hovering it still opens the panel.
            return m.hasNotch ? CGSize(width: m.notchWidth, height: m.barHeight) : .zero
        }
        return CGSize(width: m.notchWidth + 2 * wing, height: m.barHeight)
    }

    static func expandedSize(_ model: AppModel) -> CGSize {
        let rows = max(1, min(model.sessions.count, maxRows))
        let height = band(model.metrics)
            + model.approvals.reduce(CGFloat(0)) { $0 + cardHeight($1) }
            + CGFloat(rows) * rowHeight
            + footerHeight + bottomPadding
        return CGSize(width: expandedWidth(model.metrics), height: height)
    }
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .needsApproval, .needsYou: return Color(red: 1.0, green: 0.62, blue: 0.18)
        case .working, .runningTool: return Color(red: 0.38, green: 0.68, blue: 1.0)
        case .compacting: return Color(red: 0.72, green: 0.55, blue: 1.0)
        case .finished: return Color(red: 0.36, green: 0.85, blue: 0.52)
        case .idle: return Color.white.opacity(0.35)
        }
    }
}

extension Session {
    var statusText: String {
        switch status {
        case .idle: return "Idle"
        case .working: return "Working…"
        case .runningTool(let tool):
            if let detail, !detail.isEmpty { return "\(tool): \(detail)" }
            return tool
        case .needsApproval: return "Needs you"
        case .needsYou: return "Waiting for you in Claude"
        case .compacting: return "Compacting…"
        case .finished: return "Finished, your turn"
        }
    }
}

struct NotchRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let expanded = model.expanded
        let open = NotchLayout.expandedSize(model)
        let closed = NotchLayout.collapsedSize(model)
        let size = expanded ? open : closed
        let radius: CGFloat = expanded ? 20 : 10
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
                                           bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous)
        // The black shape grows and shrinks with a spring inside a window that is already big
        // enough. The content is laid out at its final size and revealed by the shape, so text
        // never squeezes or reflows mid-animation.
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            if expanded {
                ExpandedView(model: model)
                    .frame(width: open.width, height: open.height, alignment: .top)
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.05)))
            } else {
                CollapsedView(model: model)
                    .frame(width: closed.width, height: closed.height, alignment: .top)
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

private struct CollapsedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sessions = model.sessions
        if sessions.isEmpty {
            Color.clear
        } else {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(sessions.prefix(4)) { s in
                        Circle().fill(s.status.color).frame(width: 6, height: 6)
                    }
                }
                .frame(width: NotchLayout.wing)
                Color.clear.frame(width: model.metrics.notchWidth)
                badge(sessions).frame(width: NotchLayout.wing)
            }
            .frame(height: model.metrics.barHeight)
        }
    }

    @ViewBuilder
    private func badge(_ sessions: [Session]) -> some View {
        let waiting = sessions.filter { $0.status.needsAttention }.count
        let busy = sessions.filter { $0.status.isBusy }.count
        if waiting > 0 {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SessionStatus.needsYou.color)
        } else if busy > 0 {
            Text("\(busy)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(SessionStatus.working.color)
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }
}

private struct ExpandedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sessions = Array(model.sessions.prefix(NotchLayout.maxRows))
        VStack(spacing: 0) {
            HStack {
                Text("Perch").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(sessions.isEmpty ? "" : "\(model.sessions.count) session\(model.sessions.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // Same menu as the bird icon, for when the menu bar is too full to show it.
                Button {
                    model.openMenu?()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Perch menu")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: NotchLayout.band(model.metrics))

            ForEach(model.approvals) { approval in
                if approval.isQuestion {
                    QuestionCard(approval: approval,
                                 onAnswer: { model.answerQuestion(approval.id, answers: $0) },
                                 onLater: { model.answer(approval.id, .later) })
                } else {
                    ApprovalCard(approval: approval) { decision in
                        model.answer(approval.id, decision)
                    }
                }
            }

            if sessions.isEmpty {
                Text("No Claude sessions running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: NotchLayout.rowHeight)
            } else {
                ForEach(sessions) { session in
                    SessionRow(session: session, title: model.title(for: session),
                               tokens: model.tokens(for: session),
                               canOpen: model.canOpen(session),
                               open: { model.open(session) },
                               remove: { model.remove(session) })
                }
            }

            HStack(spacing: 0) {
                Text("Last 5h ").foregroundStyle(.secondary)
                Text(TokenFormat.short(model.usage.last5h.fresh))
                Text("   Today ").foregroundStyle(.secondary)
                Text(TokenFormat.short(model.usage.today.fresh))
                Text(" tokens").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .padding(.horizontal, 16)
            .frame(height: NotchLayout.footerHeight)
        }
        .foregroundStyle(.white)
    }
}

private struct SessionRow: View {
    let session: Session
    let title: String
    let tokens: Int?
    let canOpen: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    private var highlighted: Bool { session.status.needsAttention || session.status == .finished }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Circle().fill(session.status.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    // Status first, then the folder, so two conversations in one folder stay distinguishable.
                    (Text(session.statusText)
                        .foregroundStyle(highlighted ? AnyShapeStyle(session.status.color) : AnyShapeStyle(.secondary))
                        + Text(title == session.projectName ? "" : "  ·  \(session.projectName)")
                        .foregroundStyle(.tertiary))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let tokens {
                    Text(TokenFormat.short(tokens))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // Keeps room for the remove button, which sits on top of the row.
                Color.clear.frame(width: 18, height: 18)
            }
            .padding(.horizontal, 10)
            .frame(height: NotchLayout.rowHeight - 2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovered && canOpen ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(hovered ? 0.85 : 0.25))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(hovered ? 0.16 : 0)))
                    .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .help("Remove from Perch")
        }
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
        .frame(height: NotchLayout.rowHeight)
        .help(canOpen ? "Open this conversation in Claude" : "Started outside the Claude app; can't be opened from here")
    }
}

private struct ApprovalCard: View {
    let approval: PendingApproval
    let onDecision: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(approval.project) wants to use \(approval.tool)")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            // The whole command is scrollable, so nothing is approved unseen.
            ScrollView(.vertical) {
                Text(approval.summary.isEmpty ? "(no details)" : approval.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 70)
            Text(approval.summary.hasSuffix("…")
                ? "Too long to show in full. Review it in Claude before allowing."
                : "Scroll to read the whole request.")
                .font(.system(size: 10))
                .foregroundStyle(approval.summary.hasSuffix("…")
                    ? AnyShapeStyle(SessionStatus.needsYou.color) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
            HStack(spacing: 8) {
                Button("Later") { onDecision(.later) }
                    .buttonStyle(PillButton(fill: .clear, text: Color.white.opacity(0.6)))
                Spacer()
                Button("Deny") { onDecision(.deny) }
                    .buttonStyle(PillButton(fill: Color.white.opacity(0.14), text: .white))
                Button("Allow") { onDecision(.allow) }
                    .buttonStyle(PillButton(fill: .white, text: .black))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
        .padding(.horizontal, 10)
        .frame(height: NotchLayout.approvalHeight)
    }
}

private struct PillButton: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// Claude's question with its choices. One single-choice question is answered by one click;
/// several questions or multiple-choice ones need Send.
private struct QuestionCard: View {
    let approval: PendingApproval
    let onAnswer: ([String: String]) -> Void
    let onLater: () -> Void
    @State private var picked: [Int: [String]] = [:]

    private var oneClick: Bool { approval.questions.count == 1 && !approval.questions[0].multiSelect }
    private var complete: Bool {
        approval.questions.indices.allSatisfy { !(picked[$0] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(approval.project) asks")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SessionStatus.needsYou.color)
                .lineLimit(1)
                .frame(height: 20, alignment: .top)
            ForEach(Array(approval.questions.enumerated()), id: \.offset) { index, question in
                Text(question.text)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: NotchLayout.questionTextHeight,
                           maxHeight: NotchLayout.questionTextHeight, alignment: .leading)
                ForEach(question.options, id: \.label) { option in
                    OptionRow(option: option, selected: (picked[index] ?? []).contains(option.label)) {
                        choose(option.label, for: index, multi: question.multiSelect)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Answer in Claude") { onLater() }
                    .buttonStyle(PillButton(fill: .clear, text: Color.white.opacity(0.6)))
                Spacer()
                if !oneClick {
                    Button("Send") { send() }
                        .buttonStyle(PillButton(fill: .white, text: .black))
                        .opacity(complete ? 1 : 0.35)
                        .disabled(!complete)
                }
            }
            .frame(height: NotchLayout.cardFooterHeight, alignment: .bottom)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
        .padding(.horizontal, 10)
        .frame(height: NotchLayout.cardHeight(approval))
    }

    private func choose(_ label: String, for index: Int, multi: Bool) {
        if multi {
            var current = picked[index] ?? []
            if let i = current.firstIndex(of: label) { current.remove(at: i) } else { current.append(label) }
            picked[index] = current
        } else {
            picked[index] = [label]
            if oneClick { send() }
        }
    }

    private func send() {
        var answers: [String: String] = [:]
        for (index, question) in approval.questions.enumerated() {
            // Keep the order the choices are listed in, whatever order they were clicked.
            let chosen = question.options.map(\.label).filter { (picked[index] ?? []).contains($0) }
            answers[question.text] = chosen.joined(separator: ", ")
        }
        onAnswer(answers)
    }
}

private struct OptionRow: View {
    let option: Question.Option
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(option.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(option.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: NotchLayout.optionHeight - 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.22 : (hovered ? 0.14 : 0.07))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .frame(height: NotchLayout.optionHeight)
        .help(option.detail)
    }
}
