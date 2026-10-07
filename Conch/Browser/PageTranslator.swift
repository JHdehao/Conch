import Foundation
import NaturalLanguage
import Translation
import WebKit

/// Whole-page translation with Apple's on-device models (the ones Safari uses).
/// After each load it checks the page for foreign text; any page with more than a stray word
/// of it (an English interface around Chinese content counts) is translated automatically,
/// unless that's switched off or the site was set to show the original.
///
/// Text is swapped in place, including button labels, placeholders and <select> options.
/// Only text on or near the screen is translated, more as the page scrolls or adds text;
/// paragraphs already in the reader's language are left alone.
///
/// A `TranslationSession` only exists inside SwiftUI's `.translationTask`, so the view
/// hands it to `run(_:)`, which keeps going until the page moves on or translation is turned off.
@MainActor
@Observable
final class PageTranslator {
    static let autoKey = "browser.autoTranslate"
    private static let originalHostsKey = "browser.translate.originalHosts"
    static let messageName = "conchTranslate"

    /// The page's language, when it isn't the reader's and Apple can translate it.
    private(set) var source: Locale.Language?
    /// Non-nil while translation is on; `.translationTask` runs whenever it changes.
    private(set) var configuration: TranslationSession.Configuration?
    /// The first pass over the page is still running.
    private(set) var isPreparing = false
    var isOn: Bool { configuration != nil }

    @ObservationIgnored weak var webView: WKWebView?
    /// Turned on by hand in this tab, so later pages here are translated too.
    @ObservationIgnored private var keepOn = false
    @ObservationIgnored private var dirty = false
    /// Something came back translated since translation was turned on, so the model is there.
    @ObservationIgnored private var translatedAny = false
    /// Bumped on every navigation and every switch, so stale loops and loads give up.
    @ObservationIgnored private var generation = 0
    /// Languages whose download was turned down; not asked again until relaunch.
    private static var declined: Set<String> = []

    static var target: Locale.Language {
        let preferred = Locale.Language(identifier: Locale.preferredLanguages.first ?? "zh-Hans")
        return Locale.Language(languageCode: preferred.languageCode, script: preferred.script, region: nil)
    }

    // MARK: Page lifecycle

    func pageCommitted() {
        generation += 1
        source = nil
        configuration = nil
        isPreparing = false
        dirty = false
    }

    /// After a load, or when a single-page app moves to another address.
    func pageLoaded(host: String?) async {
        let current = generation
        // Already translating: the page observer picks up whatever the app renders next.
        guard !isOn else { return }
        var sample: [String: Any] = [:]
        // Script-built pages may still be thin when the load finishes.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1.2)) }
            guard current == generation else { return }
            guard let next = try? await script("sample", [12000]) as? [String: Any] else { return }
            // Back from the page cache still translated: start over from the original.
            if next["active"] as? Bool == true { _ = try? await script("restore"); continue }
            sample = next
            if (next["text"] as? String ?? "").count >= 200 { break }
        }
        var detected = Self.foreignLanguage(in: sample["text"] as? String ?? "")
        if let language = detected, await LanguageAvailability().status(from: language, to: Self.target) == .unsupported {
            detected = nil
        }
        guard current == generation, !isOn else { return }
        source = detected
        guard let detected else { return }

        let auto = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
        let wantsOriginal = host.map { Self.originalHosts.contains($0) } ?? false
        if keepOn || (auto && !wantsOriginal && !Self.declined.contains(detected.minimalIdentifier)) {
            turnOn()
        }
    }

    /// The translate button: translate this page, or put the original back.
    func toggle(host: String?) {
        if isOn {
            turnOff()
            keepOn = false
            if let host { Self.originalHosts.insert(host) }
        } else {
            keepOn = true
            if let host { Self.originalHosts.remove(host) }
            if let source { Self.declined.remove(source.minimalIdentifier) }
            turnOn()
        }
    }

    /// The page changed its text or scrolled; picked up by the running loop.
    func contentChanged() {
        if isOn { dirty = true }
    }

    // MARK: Translating

    private func turnOn() {
        guard let source else { return }
        generation += 1
        configuration = TranslationSession.Configuration(source: source, target: Self.target)
    }

    private func turnOff() {
        generation += 1
        configuration = nil
        isPreparing = false
        Task { _ = try? await script("restore") }
    }

    /// Called by `.translationTask`: translates what's on screen, then whatever comes into
    /// view or gets added, until translation is turned off or the page moves on. Stops early
    /// when the view goes away and resumes from where it was when it comes back.
    func run(_ session: TranslationSession) async {
        let current = generation
        guard isOn, (try? await script("start")) != nil else { return }
        dirty = true
        isPreparing = true
        translatedAny = false
        defer { if current == generation { isPreparing = false } }
        while current == generation, !Task.isCancelled, webView != nil {
            if dirty {
                dirty = false
                do {
                    try await translatePending(session, current)
                } catch {
                    _ = try? await script("unpend")
                    guard current == generation, !Task.isCancelled else { return }
                    // The language download was turned down, or the model can't be used.
                    if let source { Self.declined.insert(source.minimalIdentifier) }
                    keepOn = false
                    turnOff()
                    return
                }
                isPreparing = false
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func translatePending(_ session: TranslationSession, _ current: Int) async throws {
        while current == generation, !Task.isCancelled {
            // Each collect walks the page from the top, so take plenty at once and apply
            // them in small chunks: the top of the screen shows up translated early.
            let batch = (try await script("collect", [240]) as? [[Any]]) ?? []
            guard !batch.isEmpty else { return }
            var skipped: [Int] = []
            let requests = batch.compactMap { item -> TranslationSession.Request? in
                guard item.count == 2, let id = item[0] as? NSNumber, let text = item[1] as? String else { return nil }
                if Self.isReaders(text) { skipped.append(id.intValue); return nil }
                return TranslationSession.Request(sourceText: text, clientIdentifier: id.stringValue)
            }
            if !skipped.isEmpty { _ = try await script("skip", [skipped]) }
            for start in stride(from: 0, to: requests.count, by: 40) {
                let chunk = Array(requests[start..<min(start + 40, requests.count)])
                var pairs: [[Any]] = []
                do {
                    let responses = try await session.translations(from: chunk)
                    pairs = responses.compactMap { response in
                        response.clientIdentifier.flatMap(Int.init).map { [$0, response.targetText] }
                    }
                } catch {
                    guard current == generation, !Task.isCancelled else { return }
                    // Nothing came back yet and the model isn't on the device: not a bad paragraph.
                    if !translatedAny { guard await modelInstalled() else { throw error } }
                    // One odd paragraph shouldn't stop the page: go one by one and leave out the failures.
                    var failed: [Int] = []
                    for request in chunk {
                        let id = Int(request.clientIdentifier ?? "") ?? 0
                        if let response = try? await session.translate(request.sourceText) {
                            pairs.append([id, response.targetText])
                        } else {
                            failed.append(id)
                        }
                    }
                    guard current == generation, !Task.isCancelled else { return }
                    if !failed.isEmpty { _ = try await script("skip", [failed]) }
                }
                guard current == generation else { return }
                if !pairs.isEmpty { translatedAny = true }
                _ = try await script("apply", [pairs])
            }
        }
    }

    private func modelInstalled() async -> Bool {
        guard let source else { return false }
        return await LanguageAvailability().status(from: source, to: Self.target) == .installed
    }

    // MARK: Languages

    /// Same language to the reader; Traditional and Simplified Chinese count as different.
    static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode && (a.script == nil || b.script == nil || a.script == b.script)
    }

    /// The foreign language with the most text on the page, if there's more than a stray word
    /// or two of it (a brand name alone doesn't switch translation on). Each line counts by
    /// its UTF-8 length. Paragraphs in the reader's language are skipped later, so a Chinese
    /// page with an English interface gets just the interface translated.
    static func foreignLanguage(in text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        var weights: [NLLanguage: Int] = [:]
        for line in text.split(separator: "\n") {
            recognizer.reset()
            recognizer.processString(String(line))
            if let language = recognizer.dominantLanguage, language != .undetermined {
                weights[language, default: 0] += line.utf8.count
            }
        }
        // Short interface words often come out as some other language, so the threshold counts
        // all foreign text together; the biggest language is what it's translated from.
        var foreign = 0
        var best: (language: Locale.Language, weight: Int)?
        for (key, weight) in weights {
            let language = Locale.Language(identifier: key.rawValue)
            guard !same(language, target) else { continue }
            foreign += weight
            if weight > best?.weight ?? 0 { best = (language, weight) }
        }
        guard let best, foreign >= 40 else { return nil }
        return best.language
    }

    /// Already in the reader's language (a Chinese menu on an English page): left alone.
    private static func isReaders(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.7 else { return false }
        return same(Locale.Language(identifier: best.key.rawValue), target)
    }

    // MARK: Plumbing

    private static var originalHosts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: originalHostsKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: originalHostsKey) }
    }

    /// Calls a helper of `TranslateScript` in Conch's own JavaScript world.
    private func script(_ function: String, _ arguments: [Any] = []) async throws -> Any? {
        guard let webView else { throw CancellationError() }
        let body = TranslateScript.source + "\nreturn window.__conchTr[fn](...args) ?? 0;"
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript(body, arguments: ["fn": function, "args": arguments], in: nil, in: BrowserPage.world) { result in
                continuation.resume(with: result.map { $0 as Any? })
            }
        }
    }
}

/// Forwards the page's "text changed / scrolled" pings; holds the translator weakly so the
/// web view's content controller doesn't keep it alive.
final class TranslateMessageHandler: NSObject, WKScriptMessageHandler {
    weak var translator: PageTranslator?

    init(_ translator: PageTranslator) {
        self.translator = translator
    }

    @MainActor
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        translator?.contentChanged()
    }
}

/// The page-side half: finds text worth translating near the screen (skipping code, typed
/// input and anything marked `translate="no"`, looking inside open shadow roots), swaps
/// translations in, and puts the original back.
enum TranslateScript {
    static let source = #"""
    (() => {
    if (window.__conchTr) return;
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','CODE','PRE','KBD','SAMP','VAR','TEXTAREA','INPUT',
      'SVG','MATH','CANVAS','IFRAME','OBJECT']);
    // Formatting that doesn't change what text means; a block holding only these is
    // translated as one sentence (losing the formatting) instead of in fragments.
    const INLINE = new Set(['B','STRONG','I','EM','SPAN','SMALL','SUB','SUP','U','S','MARK','ABBR','CITE','Q','FONT',
      'DFN','TIME','BDI','BDO','WBR','BR','DEL','INS']);
    // Input types whose value is a button label.
    const BUTTON = new Set(['submit','button','reset']);
    const LETTER = /\p{L}/u;
    const T = window.__conchTr = { next: 1, units: new Map(), state: new WeakMap(), done: new Set(),
      roots: new WeakSet(), observer: null, timer: 0 };

    const tag = n => n.tagName.toUpperCase();
    const optOut = el => el.getAttribute('translate') === 'no' || el.classList.contains('notranslate');
    const clean = s => s.replace(/\s+/g, ' ').trim();
    const worthy = s => s.length >= 2 && LETTER.test(s);

    const ping = () => {
      if (T.timer) return;
      T.timer = setTimeout(() => {
        T.timer = 0;
        window.webkit?.messageHandlers?.conchTranslate?.postMessage('changed');
      }, 600);
    };
    const watch = root => {
      if (!T.observer || T.roots.has(root)) return;
      T.roots.add(root);
      T.observer.observe(root, { childList: true, subtree: true, characterData: true });
    };

    // Text nodes in document order, open shadow roots included; `field` gets inputs and text areas.
    const walk = (fn, field) => {
      const visit = root => {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, { acceptNode(n) {
          if (n.nodeType === 3) return NodeFilter.FILTER_ACCEPT;
          if (n.isContentEditable || optOut(n)) return NodeFilter.FILTER_REJECT;
          if (SKIP.has(tag(n))) {
            if (field && (tag(n) === 'INPUT' || tag(n) === 'TEXTAREA')) field(n);
            return NodeFilter.FILTER_REJECT;
          }
          return n.shadowRoot ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
        }});
        for (let n; (n = walker.nextNode());) {
          if (n.nodeType === 1) {
            watch(n.shadowRoot);
            if (visit(n.shadowRoot) === false) return false;
          } else if (fn(n) === false) return false;
        }
      };
      if (document.body) visit(document.body);
    };

    // On screen or within a screen or so of it. Not laid out (hidden) counts as far: it's
    // looked at again when the page changes or scrolls. Options of a closed <select> go by the select.
    const box = el => {
      const b = el.getBoundingClientRect();
      return b.width || b.height ? b : null;
    };
    const near = (first, last) => {
      let b;
      if (first.nodeType === 1) b = box(first);
      else {
        const range = document.createRange();
        range.setStartBefore(first);
        range.setEndAfter(last);
        b = box(range);
        const select = !b && first.parentElement?.closest('select');
        if (select) b = box(select);
      }
      return !!b && b.bottom > -innerHeight && b.top < innerHeight * 2.5;
    };

    T.sample = max => {
      let text = '';
      const add = t => { t = clean(t); if (worthy(t)) text += t + '\n'; return text.length < max; };
      walk(n => add(n.data), el => {
        if (el.placeholder) add(el.placeholder);
        if (BUTTON.has(el.type)) add(el.value);
      });
      return { active: !!T.observer, text };
    };

    T.start = () => {
      if (T.observer || !document.body) return true;
      T.observer = new MutationObserver(ping);
      watch(document.body);
      // Text is translated as it comes near the screen, so scrolling anything asks for more.
      document.addEventListener('scroll', ping, { capture: true, passive: true });
      addEventListener('resize', ping, { passive: true });
      return true;
    };

    // The text nodes of the block around `n`, when it holds nothing but text and INLINE tags.
    const sentence = (n, cache) => {
      let root = n.parentElement;
      while (root && root !== document.body && INLINE.has(tag(root))) root = root.parentElement;
      if (!root) return null;
      if (cache.has(root)) return cache.get(root);
      const texts = [];
      const plain = el => [...el.childNodes].every(c => c.nodeType === 3 ? (texts.push(c), true) :
        c.nodeType !== 1 || (INLINE.has(tag(c)) && !optOut(c) && plain(c)));
      const group = plain(root) && texts.length > 1 && texts.every(t => !T.state.has(t)) ? texts : null;
      cache.set(root, group);
      return group;
    };

    // A unit is [text nodes] or { el, attr } for a placeholder or button label.
    // Attribute state lives in T.state under the element, one entry per attribute.
    const attrState = (el, attr) => T.state.get(el)?.[attr];
    T.collect = limit => {
      const out = [], cache = new Map();
      const take = (unit, text) => {
        const id = T.next++;
        T.units.set(id, unit);
        out.push([id, text]);
        return out.length < limit;
      };
      const field = el => {
        if (out.length >= limit) return;
        for (const attr of ['placeholder', ...(BUTTON.has(el.type) ? ['value'] : [])]) {
          const value = el.getAttribute(attr), s = attrState(el, attr);
          if (!value || !worthy(value.trim()) || (s && (s.pending || value === s.tr)) || !near(el)) continue;
          T.state.set(el, { ...T.state.get(el), [attr]: { orig: value, tr: null, pending: true } });
          take({ el, attr }, clean(value));
        }
      };
      walk(n => {
        const s = T.state.get(n);
        if (s && (s.pending || n.data === s.tr)) return;
        let text = n.data.trim();
        if (!worthy(text)) return;
        let members = [n];
        const group = sentence(n, cache);
        if (group?.includes(n)) {
          members = group;
          text = clean(group.map(t => t.data).join(''));
        }
        if (!near(members[0], members[members.length - 1])) return;
        for (const m of members) T.state.set(m, { orig: m.data, tr: null, pending: true });
        return take(members, text);
      }, field);
      T.observer?.takeRecords();
      return out;
    };

    // Puts `tr` in for unit `id`; `tr` null leaves the original as it is.
    const settle = (id, tr) => {
      const unit = T.units.get(id);
      T.units.delete(id);
      if (!unit) return;
      if (!Array.isArray(unit)) {
        const { el, attr } = unit, s = attrState(el, attr);
        if (!s?.pending) return;
        s.pending = false;
        if (el.getAttribute(attr) !== s.orig) { delete T.state.get(el)[attr]; return; }
        s.tr = tr ?? s.orig;
        if (tr === null) return;
        el.setAttribute(attr, tr);
        T.done.add(new WeakRef(el));
        return;
      }
      const states = unit.map(m => T.state.get(m));
      if (!states.every(s => s?.pending)) return;
      // The page rewrote some of it meanwhile; the observer brings it round again.
      if (unit.some((m, i) => m.data !== states[i].orig)) { unit.forEach(m => T.state.delete(m)); return; }
      unit.forEach((m, i) => {
        const s = states[i];
        s.pending = false;
        if (tr === null) { s.tr = s.orig; return; }
        s.tr = i > 0 ? '' : s.orig.match(/^\s*/)[0] + tr + states[states.length - 1].orig.match(/\s*$/)[0];
        m.data = s.tr;
        T.done.add(new WeakRef(m));
      });
    };

    T.apply = pairs => {
      for (const [id, tr] of pairs) settle(id, tr);
      T.observer?.takeRecords();
      return true;
    };

    // Already in the reader's language, or the model couldn't do it: not asked for again.
    T.skip = ids => {
      for (const id of ids) settle(id, null);
      return true;
    };

    T.unpend = () => {
      for (const unit of T.units.values()) {
        if (Array.isArray(unit)) unit.forEach(m => T.state.delete(m));
        else delete T.state.get(unit.el)?.[unit.attr];
      }
      T.units.clear();
      return true;
    };

    T.restore = () => {
      T.observer?.disconnect();
      T.observer = null;
      document.removeEventListener('scroll', ping, { capture: true });
      removeEventListener('resize', ping);
      clearTimeout(T.timer);
      T.timer = 0;
      for (const ref of T.done) {
        const n = ref.deref(), s = n && T.state.get(n);
        if (!s) continue;
        if (n.nodeType === 3) { if (n.data === s.tr) n.data = s.orig; continue; }
        for (const [attr, a] of Object.entries(s)) if (n.getAttribute(attr) === a.tr) n.setAttribute(attr, a.orig);
      }
      T.done.clear();
      T.units.clear();
      T.state = new WeakMap();
      T.roots = new WeakSet();
      return true;
    };
    })();
    """#
}
