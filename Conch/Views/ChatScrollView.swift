import SwiftUI

/// A chat transcript's scroll view, shared by the assistant and AI coding.
/// - Opens at the latest message at once, instead of sliding down a long history.
/// - Follows new messages only while you're at the bottom; scroll up to read and it
///   stays put (a dot on the ↓ button says something new arrived).
/// - Faint jump buttons appear when they'd help: ↓ whenever you're away from the end,
///   ↑ for a moment while you scroll back far from the start. Long jumps fade out,
///   land, and fade back in rather than dragging through everything in between.
struct ChatScrollView<Tail: Equatable, Identity: Equatable, Content: View>: View {
    /// Changes when the transcript grows or its last row changes (streaming text too).
    let tail: Tail
    /// Changes when a different conversation is shown (or its history finishes loading).
    let identity: Identity
    /// True while a turn is in progress. Sending starts one, which brings the view back
    /// to the bottom to follow the reply, wherever it had been scrolled.
    let busy: Bool
    @ViewBuilder var content: Content

    @State private var position = ScrollPosition()
    @State private var metrics = Metrics()
    /// Whether new content should keep the view at the bottom. Only the user's own
    /// scrolling changes it, so content growing never unsticks it.
    @State private var following = true
    @State private var unseen = false
    @State private var showingTop = false
    @State private var userScrolling = false
    @State private var hideTop: Task<Void, Never>?
    /// A veil in the canvas color over the list during a long jump. The list itself
    /// stays visible underneath: a transparent lazy stack skips building the rows at
    /// the new spot and stays blank until the next scroll.
    @State private var veiled = false
    @CurrentTheme private var theme

    private static var topID: String { "chat-scroll-top" }
    private static var bottomID: String { "chat-scroll-bottom" }

    struct Metrics: Equatable {
        var fromTop: CGFloat = 0
        /// Negative while the list is pulled past its end.
        var fromBottom: CGFloat = 0
        var viewport: CGFloat = 1
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Anchors at both ends: jumping to a view lands exactly, where jumping to an
                // offset would trust the estimated heights of rows never laid out.
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topID)
                    content
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
            }
            .overlay {
                theme.chrome.canvasColor
                    .opacity(veiled ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .scrollPosition($position)
            // Start at the end. Growth keeps the offset (the default), so text arriving
            // while you read further up doesn't move what you're reading.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let visible = geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                return Metrics(fromTop: offset,
                               fromBottom: geometry.contentSize.height - offset - visible,
                               viewport: max(visible, 1))
            } action: { old, new in
                metrics = new
                // The keyboard (or the composer growing) changed the height: keep the
                // bottom where it was, so the input bar pushes the messages up instead of
                // covering the last ones. The default keeps the top, as for growth.
                let change = old.viewport - new.viewport
                if old.viewport > 1, abs(change) > 1, !userScrolling {
                    if following {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    } else {
                        position.scrollTo(y: max(new.fromTop + change, 0))
                    }
                }
                if new.fromBottom < 24 { unseen = false }
                // Heading back up through a long history: offer the way to the start.
                if userScrolling, new.fromTop < old.fromTop - 1, new.fromTop > new.viewport * 2 { reveal() }
            }
            .onScrollPhaseChange { old, phase in
                userScrolling = phase == .interacting || phase == .decelerating
                // Whether to follow is decided where the user's scrolling stops. Not after
                // our own animated scroll to the bottom: a streaming reply grows past it
                // during the animation, which would read as "scrolled away" and stop following.
                if phase == .idle, old == .interacting || old == .decelerating {
                    following = metrics.fromBottom < 60
                }
            }
            .onChange(of: busy) {
                guard busy else { return }
                following = true
                unseen = false
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: tail) {
                if following {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                } else {
                    unseen = true
                }
            }
            .onChange(of: identity) {
                following = true
                unseen = false
                Task { await land(.bottom, proxy) }
            }
            // Coming back to a conversation that's already loaded: `identity` doesn't
            // change, but the new list at its initial bottom offset is the same lazy stack
            // that stays blank until scrolled, so land (with its nudge) here too.
            .task {
                await land(.bottom, proxy)
                // Pushed onto a navigation stack, the list is laid out during the slide-in
                // and a nudge made then can be lost with it (long Claude transcripts most
                // often): one more once the transition has settled.
                try? await Task.sleep(for: .milliseconds(450))
                if following, !userScrolling { await nudge(.bottom, proxy) }
            }
            .overlay(alignment: .bottomTrailing) { jumpButtons(proxy) }
            .animation(.snappy(duration: 0.25), value: showsBottom)
            .animation(.snappy(duration: 0.25), value: showingTop)
        }
    }

    private var showsBottom: Bool { !following && metrics.fromBottom > metrics.viewport * 0.6 }

    /// Two fixed slots, ↑ above ↓, so one appearing never moves the other under a finger.
    private func jumpButtons(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 10) {
            JumpButton(symbol: "chevron.up", dot: false, help: String(localized: "回到最前面")) { jump(to: .top, proxy) }
                .visible(showingTop && metrics.fromTop > metrics.viewport)
            JumpButton(symbol: "chevron.down", dot: unseen, help: String(localized: "回到最新")) { jump(to: .bottom, proxy) }
                .visible(showsBottom)
        }
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }

    /// ↑ shows while scrolling back up, far from the start, and fades a few seconds
    /// after the scrolling stops.
    private func reveal() {
        showingTop = true
        hideTop?.cancel()
        hideTop = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            showingTop = false
        }
    }

    private func jump(to edge: Edge, _ proxy: ScrollViewProxy) {
        let distance = edge == .top ? metrics.fromTop : metrics.fromBottom
        following = edge == .bottom
        if edge == .bottom { unseen = false }
        if edge == .top { showingTop = false }
        // Near: a real scroll. Far: fade, land, fade in — scrolling past hundreds of
        // rows would build every one of them on the way and take a while to settle.
        guard distance > metrics.viewport * 2.5 else {
            withAnimation(.smooth(duration: 0.35)) {
                proxy.scrollTo(edge == .top ? Self.topID : Self.bottomID, anchor: edge == .top ? .top : .bottom)
            }
            return
        }
        Task {
            withAnimation(.easeIn(duration: 0.1)) { veiled = true }
            try? await Task.sleep(for: .milliseconds(100))
            await land(edge, proxy)
            withAnimation(.easeOut(duration: 0.22)) { veiled = false }
        }
    }

    /// Puts the list exactly at one end. Rows near the landing spot get their real
    /// heights only once laid out, so check and go again until it holds.
    private func land(_ edge: Edge, _ proxy: ScrollViewProxy) async {
        // A list that just appeared hasn't reported its geometry yet; nudging from the
        // placeholder metrics would jump to the top instead.
        for _ in 0..<15 where metrics.viewport <= 1 {
            try? await Task.sleep(for: .milliseconds(30))
        }
        for _ in 0..<5 {
            proxy.scrollTo(edge == .top ? Self.topID : Self.bottomID, anchor: edge == .top ? .top : .bottom)
            try? await Task.sleep(for: .milliseconds(40))
            let off = edge == .top ? metrics.fromTop : metrics.fromBottom
            if abs(off) < 2 { break }
        }
        await nudge(edge, proxy)
    }

    /// After a long programmatic jump the lazy stack keeps the rows where its height
    /// estimates put them, and shows nothing until the next scroll. A one-point
    /// nudge and back is that scroll.
    private func nudge(_ edge: Edge, _ proxy: ScrollViewProxy) async {
        guard metrics.viewport > 1 else { return }
        position.scrollTo(y: max(metrics.fromTop + (edge == .top ? 1 : -1), 0))
        try? await Task.sleep(for: .milliseconds(30))
        proxy.scrollTo(edge == .top ? Self.topID : Self.bottomID, anchor: edge == .top ? .top : .bottom)
    }
}

private extension View {
    /// Shown or hidden in place, keeping its slot.
    func visible(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.6)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

/// A small, quiet round button over the transcript.
private struct JumpButton: View {
    let symbol: String
    let dot: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .modifier(GlassCapsule())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .overlay(alignment: .topTrailing) {
            if dot {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 9, height: 9)
                    .offset(x: 1, y: -1)
            }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

