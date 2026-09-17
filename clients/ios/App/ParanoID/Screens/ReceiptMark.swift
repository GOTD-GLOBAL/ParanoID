import ParanoidKit
import SwiftUI

/// The mark under an own bubble and at the end of a conversation row.
///
/// It draws what `MessagePresentation.Mark` says and nothing else: one stroke
/// for durable server acceptance, two for the peer's authenticated delivery
/// receipt, and a clock while the envelope is still queued. It is deliberately
/// a shape rather than the characters «✓», «✓✓» and «…» the first Android
/// build typed into the bubble: a font glyph changed size with the text, sat on
/// the text baseline instead of the line it belongs to, and could not carry the
/// colour of a state.
///
/// Nothing here invents a state. There is no third stroke and no colour that
/// says "read": REQ-MSG-003 gives this client exactly three states, and the
/// words behind them (``MessagePresentation/delivery(_:)``) stay as the
/// accessibility label so VoiceOver reads the state rather than the drawing.
struct ReceiptMark: View {
    let mark: MessagePresentation.Mark
    /// The height of one stroke; the width follows from it.
    var size: CGFloat = 11

    var body: some View {
        Group {
            switch mark {
            case .queued:
                Image(systemName: "clock")
                    .font(.system(size: size, weight: .medium))
            case .stored:
                Check(double: false)
                    .stroke(style: StrokeStyle(lineWidth: size / 7,
                                               lineCap: .round,
                                               lineJoin: .round))
                    .frame(width: size * 1.2, height: size * 0.85)
            case .delivered:
                Check(double: true)
                    .stroke(style: StrokeStyle(lineWidth: size / 7,
                                               lineCap: .round,
                                               lineJoin: .round))
                    .frame(width: size * 1.7, height: size * 0.85)
            }
        }
        .accessibilityHidden(true)
    }

    /// One or two ticks in the box they are given.
    private struct Check: Shape {
        let double: Bool

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let width = double ? rect.width * 0.62 : rect.width
            tick(&path, in: CGRect(x: rect.minX, y: rect.minY,
                                   width: width, height: rect.height))
            if double {
                tick(&path, in: CGRect(x: rect.maxX - width, y: rect.minY,
                                       width: width, height: rect.height))
            }
            return path
        }

        private func tick(_ path: inout Path, in box: CGRect) {
            path.move(to: CGPoint(x: box.minX, y: box.midY))
            path.addLine(to: CGPoint(x: box.minX + box.width * 0.36, y: box.maxY))
            path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        }
    }
}

/// The sentence two marks are not "read", shown once in the chat.
///
/// The contact sheet has always carried it (`Strings.Details.receiptsBody`),
/// which is three taps away from the conversation it is about. This is the same
/// promise in the place it matters, and it disappears for good on «Понятно»
/// (``ParanoidKit/ReceiptHint``).
struct ReceiptHintCard: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ReceiptMark(mark: .delivered, size: 13)
                    .foregroundStyle(.secondary)
                Text(Strings.Chat.receiptHint)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: dismiss) {
                Text(Strings.Chat.receiptHintAction)
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("receipt-hint-dismiss")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receipt-hint")
    }
}

/// What one finished call left in the conversation.
///
/// It is a line rather than a bubble because it is not a message: nobody wrote
/// it, nothing was encrypted for it and the peer keeps its own account of the
/// same call (``ParanoidKit/CallLog``). A missed call is the one outcome that
/// asks something of the reader, so it is the one that carries an action.
struct CallRowView: View {
    let record: CallRecord
    let callBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(record.kind.isMissed ? Color.red : Color.secondary)
                .accessibilityHidden(true)
            Text(Strings.CallRow.line(kind: record.kind, video: record.video,
                                      seconds: record.durationSeconds))
                .font(.system(size: 13))
                .foregroundStyle(record.kind.isMissed ? Color.red : Color.secondary)
            if record.kind.isMissed {
                Button(action: callBack) {
                    Text(Strings.CallRow.callBack)
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("call-back")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call-row-\(record.id)")
    }

    /// Direction first, because that is what a reader looks for: an arrow out
    /// for a call this device placed, in for one it received, and the missed
    /// arrow for a ring nobody answered.
    private var symbol: String {
        switch record.kind {
        case .outgoing, .cancelled, .unanswered, .rejected, .busy:
            return record.video ? "video" : "phone.arrow.up.right"
        case .incoming:
            return record.video ? "video" : "phone.arrow.down.left"
        case .missed:
            return "phone.arrow.down.left"
        case .declined:
            return "phone.down"
        case .failed:
            return "phone.badge.waveform"
        }
    }
}
