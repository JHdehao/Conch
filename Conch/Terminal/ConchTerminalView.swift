#if os(iOS)
import SwiftTerm
import UIKit

/// SwiftTerm turns a finger drag into a left-button drag whenever the remote app asks for
/// mouse events, so with tmux `mouse on` every swipe starts a copy-mode selection. Here a
/// vertical swipe scrolls instead; selecting text stays on long-press. Tapping a URL opens
/// it in the built-in browser.
///
/// Scrolling back through tmux: the history lives on the remote machine, so the first swipe
/// fetches it (`historySource`, one round trip) into `HistoryTerminalView`, a read-only
/// terminal laid over this one, and from then on scrolling is local, smooth and with
/// momentum. Back at the bottom (or on typing) the overlay goes and the live terminal,
/// which kept running underneath, shows again. When the program in the pane scrolls itself
/// (vim, full-screen TUIs) or there's no tmux to ask, the swipe sends wheel events.
final class ConchTerminalView: TerminalView {
    /// Finger travel, in rows, per wheel notch. `Host.tmuxCommand` makes tmux copy mode scroll
    /// one line per notch for Conch, so the text follows the finger row by row (vim scrolls 3).
    private static let rowsPerNotch: CGFloat = 1

    /// Fetches the last given number of lines of tmux history; nil means use wheel events.
    var historySource: ((Int) async -> TmuxHistory?)?
    /// What `TerminalContainer` last applied, so the overlay looks the same.
    var appearance: TerminalAppearance?

    private lazy var wheelPan = UIPanGestureRecognizer(target: self, action: #selector(wheelPanned))
    private var wheelTravel: CGFloat = 0
    /// Cell the wheel events point at: where the finger last was.
    private var wheelCell = (col: 0, row: 0)

    private enum PanMode { case pending, fetching, wheel, history }
    private var panMode = PanMode.pending
    /// Travel while the history is on its way, applied once it's known where it goes.
    private var heldTravel: CGFloat = 0
    /// The fling the finger left while the history was still on its way.
    private var heldVelocity: CGFloat?

    private var history: HistoryTerminalView?
    private var historyRequested = 0
    private var historyAvailable = 0
    private var loadingMore = false
    private var fetch: Task<Void, Never>?

    /// After the finger lifts, the scroll keeps going and slows like a scroll view's.
    private var flingLink: CADisplayLink?
    private var flingVelocity: CGFloat = 0
    private var flingTime: CFTimeInterval = 0
    private lazy var linkTap = UITapGestureRecognizer(target: self, action: #selector(linkTapped))
    private var tappedLink: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wheelPan.isEnabled = false
        addGestureRecognizer(wheelPan)
        // SwiftTerm only follows plain URLs after a pointer hover, which a finger never
        // makes; its own single tap (click / menu) waits for this one to fail.
        addGestureRecognizer(linkTap)
        for case let tap as UITapGestureRecognizer in gestureRecognizers ?? []
        where tap !== linkTap && tap.numberOfTapsRequired == 1 {
            tap.require(toFail: linkTap)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Replaces SwiftTerm's drag-to-mouse pan; taps still click through to the app.
    override func mouseModeChanged(source: Terminal) {
        let reporting = source.mouseMode != .off
        DispatchQueue.main.async { [self] in
            wheelPan.isEnabled = reporting
            isScrollEnabled = !reporting
            if !reporting { stopFling() }
        }
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === linkTap else { return super.gestureRecognizerShouldBegin(gesture) }
        tappedLink = link(at: gesture.location(in: self))
        return tappedLink != nil
    }

    @objc private func linkTapped() {
        guard let url = tappedLink else { return }
        NotificationCenter.default.post(name: .conchOpenLink, object: url)
    }

    /// The URL under `point` (view coordinates, so scrollback included), if any.
    private func link(at point: CGPoint) -> URL? {
        let terminal = getTerminal()
        let font = self.font as CTFont
        // Same cell size SwiftTerm computes (AppleTerminalView.computeFontDimensions).
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let lineHeight = ceil((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * lineSpacing)
        let cellHeight = ceil(lineHeight * scale) / scale
        guard cellHeight > 0, terminal.cols > 0, contentSize.width > 0 else { return nil }
        let col = Int(point.x / (contentSize.width / CGFloat(terminal.cols)))
        let row = Int(point.y / cellHeight)
        guard (0..<terminal.cols).contains(col), row >= 0,
              let text = terminal.link(at: .buffer(Position(col: col, row: row)), mode: .explicitAndImplicit)
        else { return nil }
        return URL.webLink(text)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopFling()
            dismissHistory()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Rotation, keyboard, split view: the snapshot no longer fits.
        if let history, history.frame != frame { dismissHistory() }
    }

    // MARK: Swipes

    @objc private func wheelPanned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopFling()
            wheelTravel = 0
            heldTravel = 0
            heldVelocity = nil
            panMode = .pending
        case .changed:
            let terminal = getTerminal()
            let rowHeight = bounds.height / CGFloat(max(terminal.rows, 1))
            let point = gesture.location(in: self)
            wheelCell = (min(max(Int(point.x / bounds.width * CGFloat(terminal.cols)), 0), terminal.cols - 1),
                         min(max(Int((point.y - contentOffset.y) / rowHeight), 0), terminal.rows - 1))
            let travel = gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            if panMode == .pending, travel != 0 {
                // Finger down = back through the history. Up from the live screen has nothing
                // to show locally, so it stays a wheel (an app may scroll down with it).
                if travel > 0, historySource != nil {
                    panMode = .fetching
                    requestHistory(lines: TmuxHistory.firstFetch)
                } else {
                    panMode = .wheel
                }
            }
            move(by: travel)
        case .ended, .cancelled:
            let velocity = gesture.state == .ended ? gesture.velocity(in: self).y : 0
            if panMode == .fetching { heldVelocity = velocity } else { release(velocity: velocity) }
        default:
            break
        }
    }

    private func move(by travel: CGFloat) {
        switch panMode {
        case .pending, .fetching: heldTravel += travel
        case .wheel: scrollWheel(by: travel)
        case .history: scrollHistory(by: travel)
        }
    }

    /// The finger lifted: keep going if it was moving, otherwise settle.
    private func release(velocity: CGFloat) {
        guard abs(velocity) > 200 else {
            if panMode == .history { dismissHistoryIfAtBottom() }
            return
        }
        // Wheel events are capped so a hard flick doesn't flood a slow link with redraws.
        let cap: CGFloat = panMode == .wheel ? 4000 : 8000
        flingVelocity = min(max(velocity, -cap), cap)
        flingTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(flingStep))
        link.add(to: .main, forMode: .common)
        flingLink = link
    }

    @objc private func flingStep(_ link: CADisplayLink) {
        let elapsed = CGFloat(link.timestamp - flingTime)
        flingTime = link.timestamp
        move(by: flingVelocity * elapsed)
        flingVelocity *= pow(UIScrollView.DecelerationRate.normal.rawValue, elapsed * 1000)
        if abs(flingVelocity) < 40 {
            stopFling()
            if panMode == .history { dismissHistoryIfAtBottom() }
        }
    }

    private func stopFling() {
        flingLink?.invalidate()
        flingLink = nil
    }

    /// Turns finger travel (points, down positive) into wheel notches.
    private func scrollWheel(by travel: CGFloat) {
        let terminal = getTerminal()
        let step = bounds.height / CGFloat(max(terminal.rows, 1)) * Self.rowsPerNotch
        guard step > 0, terminal.mouseMode != .off else { return }
        wheelTravel += travel
        // Finger down = content follows it = older lines = wheel up (button 4).
        while abs(wheelTravel) >= step {
            let up = wheelTravel > 0
            wheelTravel -= up ? step : -step
            let flags = terminal.encodeButton(button: up ? 4 : 5, release: false,
                                              shift: false, meta: false, control: false)
            terminal.sendEvent(buttonFlags: flags, x: wheelCell.col, y: wheelCell.row)
        }
    }

    // MARK: Local history

    private func requestHistory(lines: Int) {
        guard let source = historySource else { return }
        historyRequested = lines
        fetch = Task { [weak self] in
            let result = await source(lines)
            guard !Task.isCancelled, let self else { return }
            if self.history == nil { self.historyArrived(result) } else { self.moreArrived(result) }
        }
    }

    /// The first fetch is back: show it and hand over what the finger did meanwhile.
    private func historyArrived(_ result: TmuxHistory?) {
        guard panMode == .fetching else { return }
        if let result, let overlay = makeOverlay(result) {
            history = overlay
            historyAvailable = result.available
            panMode = .history
        } else {
            panMode = .wheel
        }
        move(by: heldTravel)
        heldTravel = 0
        if let velocity = heldVelocity {
            heldVelocity = nil
            release(velocity: velocity)
        }
    }

    private func makeOverlay(_ result: TmuxHistory) -> HistoryTerminalView? {
        guard let superview else { return nil }
        let overlay = HistoryTerminalView(frame: frame)
        if let appearance { TerminalContainer.apply(appearance, to: overlay, translucent: false) }
        superview.insertSubview(overlay, aboveSubview: self)
        overlay.layoutIfNeeded()
        fill(overlay, with: result)
        overlay.onScroll = { [weak self] in self?.historyScrolled() }
        // A tap goes back to the live terminal and its keyboard.
        overlay.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(historyTapped)))
        return overlay
    }

    private func fill(_ overlay: HistoryTerminalView, with result: TmuxHistory) {
        let terminal = overlay.getTerminal()
        terminal.resetToInitialState()
        // Wrapped lines take more than one row each.
        terminal.changeScrollback(result.lineCount * 3 + 500)
        overlay.feed(text: result.text)
        overlay.layoutIfNeeded()
        overlay.contentOffset.y = overlay.bottomOffset
    }

    /// Finger or fling on the live view moves the overlay (later touches land on it directly).
    private func scrollHistory(by travel: CGFloat) {
        guard let history else { return }
        history.contentOffset.y = min(max(history.contentOffset.y - travel, 0), history.bottomOffset)
    }

    private func historyScrolled() {
        guard let history else { return }
        // Near the top with more on the machine: fetch a bigger piece.
        if history.contentOffset.y < history.bounds.height * 2, !loadingMore,
           historyRequested < min(historyAvailable, TmuxHistory.maxFetch) {
            loadingMore = true
            requestHistory(lines: min(historyRequested * 4, TmuxHistory.maxFetch))
        }
        // The overlay's own scrolling (touches after the first swipe) ends at the bottom.
        if !history.isTracking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.dismissHistoryIfAtBottom() }
        }
    }

    /// A bigger piece is back: swap it in at the same distance from the bottom.
    private func moreArrived(_ result: TmuxHistory?) {
        loadingMore = false
        guard let history, let result else { return }
        let fromBottom = history.bottomOffset - history.contentOffset.y
        historyAvailable = result.available
        fill(history, with: result)
        history.contentOffset.y = max(history.bottomOffset - fromBottom, 0)
    }

    private func dismissHistoryIfAtBottom() {
        guard let history, flingLink == nil, wheelPan.state != .changed,
              !history.isTracking, !history.isDecelerating,
              history.contentOffset.y >= history.bottomOffset - 2 else { return }
        dismissHistory()
    }

    @objc private func historyTapped() {
        dismissHistory()
    }

    /// Back to the live terminal.
    func dismissHistory() {
        fetch?.cancel()
        fetch = nil
        loadingMore = false
        history?.removeFromSuperview()
        history = nil
        if panMode == .history || panMode == .fetching { panMode = .pending }
    }
}

/// The overlay that shows fetched tmux history: a plain terminal that only scrolls.
final class HistoryTerminalView: TerminalView {
    var onScroll: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentInsetAdjustmentBehavior = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The keyboard stays with the live terminal underneath.
    override var canBecomeFirstResponder: Bool { false }

    override var contentOffset: CGPoint {
        didSet { onScroll?() }
    }

    var bottomOffset: CGFloat {
        max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
    }
}
#endif
