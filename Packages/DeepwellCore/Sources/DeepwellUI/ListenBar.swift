import SwiftUI
import DeepwellNarration

/// The bottom of the reader while listening: the "Jump to current" pill (when the reader has scrolled away from the
/// spoken word) above the `ListenBar`. Shared by the Mac and the phone (ticket 17).
public struct ListenOverlay: View {
    let player: NarrationPlayer
    @Binding var following: Bool

    public init(player: NarrationPlayer, following: Binding<Bool>) {
        self.player = player
        _following = following
    }

    public var body: some View {
        VStack(spacing: 8) {
            if !following {
                Button { following = true } label: { Label("Jump to current", systemImage: "arrow.down.to.line") }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(Ayu.accent)
            }
            ListenBar(player: player)
        }
        .padding(12)
    }
}

/// Bottom bar while listening: play/pause, sentence back and forward, speed, progress, and generation or error state.
public struct ListenBar: View {
    let player: NarrationPlayer

    public init(player: NarrationPlayer) { self.player = player }

    public var body: some View {
        HStack(spacing: Self.spacing) {
            Button { player.previousSentence() } label: { Image(systemName: "backward.end.fill") }
                .help("Previous sentence")
                .accessibilityLabel("Previous sentence")
            Button { player.toggle() } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help(player.state == .playing ? "Pause" : "Play")
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
            Button { player.nextSentence() } label: { Image(systemName: "forward.end.fill") }
                .help("Next sentence")
                .accessibilityLabel("Next sentence")

            ProgressView(value: player.progress).frame(minWidth: Self.progressWidth)

            if let error = player.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Ayu.red).lineLimit(1).truncationMode(.tail)
                    .help(error)
                    #if os(iOS)
                    .labelStyle(.iconOnly)
                    #endif
                Button("Retry") { player.retry() }
            } else if player.state == .loading || player.state == .waiting {
                ProgressView().controlSize(.small)
                Text(player.state == .waiting ? "Generating…" : "Loading…").foregroundStyle(.secondary)
                    #if os(iOS)
                    .lineLimit(1).fixedSize()
                    #endif
            } else if player.isGenerating {
                Image(systemName: "waveform").foregroundStyle(.secondary).help("Generating audio ahead")
            }

            Menu {
                ForEach(NarrationPlayer.speeds, id: \.self) { s in
                    Button { player.rate = s } label: {
                        if s == player.rate { Label(Self.speed(s), systemImage: "checkmark") } else { Text(Self.speed(s)) }
                    }
                }
            } label: { Text(Self.speed(player.rate)).monospacedDigit() }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
            .help("Playback speed")

            Button { player.stop() } label: { Image(systemName: "xmark") }
                .help("Stop listening")
                .accessibilityLabel("Stop listening")
        }
        .buttonStyle(.borderless)
        .font(Self.font)
        .padding(.horizontal, 14).padding(.vertical, Self.verticalPadding)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    // Seam: bigger touch targets on the phone.
    #if os(iOS)
    private static let spacing: CGFloat = 16
    private static let font = Font.body
    private static let verticalPadding: CGFloat = 12
    private static let progressWidth: CGFloat = 50
    #else
    private static let spacing: CGFloat = 14
    private static let font = Font.callout
    private static let verticalPadding: CGFloat = 8
    private static let progressWidth: CGFloat = 80
    #endif

    public static func speed(_ s: Float) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s)
    }
}
