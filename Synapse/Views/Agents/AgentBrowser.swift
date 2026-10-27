import Observation
import SwiftUI
import SynapseKit
import UIKit
import WebKit

/// Something the agent did on the page, shown over the screen.
struct BrowserMark: Identifiable, Equatable {
    var id: Int { number }
    var number: Int
    var kind: String
    var text: String
    var rect: CGRect
}

/// The agent's last pointer action, drawn as a ring over the element it touched.
struct BrowserPointer: Identifiable, Equatable {
    var id = UUID()
    var rect: CGRect
    var label: String
}

/// One line in the Computer view's action log.
struct BrowserAction: Identifiable, Equatable {
    var id = UUID()
    var time = Date()
    var title: String
}

/// The built-in browser agents drive (the `browser` tool): one WebKit web view for the app, a page map the model
/// reads (numbered links, buttons and fields with their text), and the marks the Computer screen draws so the user
/// sees what the agent clicks and types. Everything runs on the iPhone.
@MainActor
@Observable
final class AgentBrowser: NSObject {
    static let shared = AgentBrowser()

    private(set) var title = ""
    private(set) var url: URL?
    private(set) var loading = false
    private(set) var marks: [BrowserMark] = []
    private(set) var pointer: BrowserPointer?
    private(set) var toast: String?
    private(set) var actions: [BrowserAction] = []
    /// The agent currently using it, and in which chat.
    private(set) var driver: String?
    private(set) var conversationID: UUID?
    /// The page has been opened at least once.
    private(set) var hasPage = false
    /// Numbered badges over the elements (the user can hide them).
    var showMarks = true
    /// Downscaled JPEG of the screen after the last action, for vision models (nil when not wanted).
    private(set) var screenshot: String?
    var wantsScreenshots = false

    @ObservationIgnored private(set) lazy var webView: WKWebView = makeWebView()
    @ObservationIgnored private var alerts: [String] = []
    @ObservationIgnored private var mapped = false

    private override init() {
        super.init()
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.allowsInlineMediaPlayback = true
        config.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        return wv
    }

    // MARK: - Actions

    /// Run one `browser` tool call and describe the page afterwards.
    func perform(_ call: AgentToolCall, agent: String, conversation: UUID, limit: Int) async throws -> String {
        driver = agent
        conversationID = conversation
        let action = (call.attributes["action"] ?? (call.input.isEmpty ? "read" : "open")).lowercased()
        let input = call.input.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = ""
        switch action {
        case "open", "goto", "navigate", "search":
            let url = Self.url(for: input)
            log("Opened \(url.host() ?? url.absoluteString)")
            hasPage = true
            toast = nil
            pointer = nil
            webView.load(URLRequest(url: url))
            await settle(seconds: 12)
        case "click", "tap", "press":
            try await ensureMap()
            let result: Any?
            if let n = Int(input) {
                result = try await js("__synapse.click(\(n))")
            } else if input.isEmpty {
                throw AgentToolError("Say which element to click: its number from the page map, or its text.")
            } else {
                result = try await js("__synapse.clickText(\(Self.quote(input)))")
            }
            let r = result as? [String: Any] ?? [:]
            if let error = r["error"] as? String { throw AgentToolError(error) }
            let label = r["text"] as? String ?? input
            pointer = BrowserPointer(rect: Self.rect(r["rect"]), label: "Tap")
            log("Tapped \(label.isEmpty ? "[\(input)]" : "“\(label)”")")
            await settle(seconds: 6)
        case "type", "fill", "enter":
            try await ensureMap()
            let n = Int(call.attributes["target"] ?? call.attributes["element"] ?? call.attributes["into"] ?? "") ?? 0
            let submit = ["true", "yes", "1"].contains((call.attributes["submit"] ?? call.attributes["enter"] ?? "").lowercased())
            guard !input.isEmpty else { throw AgentToolError("Give the text to type as the input.") }
            let r = try await js("__synapse.type(\(n), \(Self.quote(input)), \(submit))") as? [String: Any] ?? [:]
            if let error = r["error"] as? String { throw AgentToolError(error) }
            pointer = BrowserPointer(rect: Self.rect(r["rect"]), label: "Type")
            toast = "Typed “\(input.prefix(60))”" + (submit ? " ⏎" : "")
            log("Typed “\(input.prefix(60))”" + (submit ? " and pressed Enter" : "") + (n > 0 ? " into [\(n)]" : ""))
            await settle(seconds: submit ? 8 : 1)
        case "key", "keypress":
            let key = Self.keyName(input)
            _ = try await js("__synapse.key(\(Self.quote(key)))")
            toast = "Pressed \(key)"
            log("Pressed \(key)")
            await settle(seconds: key == "Enter" ? 8 : 1)
        case "scroll":
            try await ensureMap()
            let how = input.isEmpty ? "down" : input.lowercased()
            let r = try await js("__synapse.scroll(\(Self.quote(how)))") as? [String: Any] ?? [:]
            if let error = r["error"] as? String { throw AgentToolError(error) }
            log("Scrolled \(how)")
            await settle(seconds: 1)
        case "back":
            if webView.canGoBack { webView.goBack(); log("Went back") } else { note = "There is no page to go back to.\n" }
            await settle(seconds: 8)
        case "forward":
            if webView.canGoForward { webView.goForward(); log("Went forward") }
            await settle(seconds: 8)
        case "reload", "refresh":
            webView.reload()
            log("Reloaded")
            await settle(seconds: 12)
        case "wait", "sleep":
            let secs = min(10, max(1, Double(input) ?? 2))
            log("Waited \(Int(secs)) s")
            try await Task.sleep(for: .seconds(secs))
            await settle(seconds: 2)
        case "read", "text", "find", "look", "screenshot", "map":
            guard hasPage else { throw AgentToolError("No page is open yet. Use action=\"open\" with a URL or search words first.") }
            if !input.isEmpty, action != "screenshot" {
                let r = try await js("__synapse.find(\(Self.quote(input)))") as? [String: Any] ?? [:]
                let hits = r["hits"] as? [String] ?? []
                log("Looked for “\(input.prefix(40))”")
                note = hits.isEmpty ? "“\(input)” is not on this page.\n" : "Found “\(input)”:\n" + hits.map { "… \($0) …" }.joined(separator: "\n") + "\n\n"
            } else if action == "read" && input.isEmpty {
                let text = try await js("__synapse.allText(\(max(2_000, limit)))") as? String ?? ""
                log("Read the page")
                return try await describe(limit: limit, fullText: text)
            }
        default:
            throw AgentToolError("Unknown browser action \"\(action)\". Use open, click, type, key, scroll, read, back or wait.")
        }
        return note + (try await describe(limit: limit))
    }

    /// The page as the model sees it: title, URL, the numbered map and the visible text.
    private func describe(limit: Int, fullText: String? = nil) async throws -> String {
        guard hasPage else { return "No page is open." }
        let textLimit = max(1_500, limit - 1_200)
        let map = try await js("__synapse.map(\(limit > 6_000 ? 90 : 45), \(fullText == nil ? textLimit : 0))") as? [String: Any] ?? [:]
        mapped = true
        title = map["title"] as? String ?? webView.title ?? ""
        url = (map["url"] as? String).flatMap(URL.init(string:)) ?? webView.url
        let elements = map["elements"] as? [[String: Any]] ?? []
        marks = elements.map { e in
            BrowserMark(number: e["n"] as? Int ?? 0, kind: e["kind"] as? String ?? "", text: e["text"] as? String ?? "", rect: Self.rect(e["rect"]))
        }
        if wantsScreenshots { await snapshot() }
        var lines = ["Page: \(title.isEmpty ? "(untitled)" : title) — \(url?.absoluteString ?? "")"]
        if let y = map["scrollY"] as? Double, let h = map["height"] as? Double, let v = map["viewport"] as? Double, h > v + 10 {
            lines.append("Scroll: \(Int((y + v) / h * 100))% of the page is above the fold; scroll down for more.")
        }
        if !alerts.isEmpty {
            lines.append("The page showed: " + alerts.joined(separator: " | "))
            alerts = []
        }
        if elements.isEmpty {
            lines.append("No clickable elements are visible (the page may still be loading: wait, or scroll).")
        } else {
            lines.append("Elements you can click or type into:")
            for e in elements {
                var l = "[\(e["n"] ?? 0)] \(e["kind"] ?? "") “\((e["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " "))”"
                if let v = e["value"] as? String, !v.isEmpty { l += " = “\(v)”" }
                if e["checked"] as? Bool == true { l += " (checked)" }
                if let href = e["href"] as? String, let path = Self.shortHref(href) { l += " → \(path)" }
                lines.append(l)
            }
        }
        let text = fullText ?? (map["text"] as? String ?? "")
        if !text.isEmpty { lines.append((fullText == nil ? "Visible text:" : "Page text:") + "\n" + text) }
        return lines.joined(separator: "\n")
    }

    private func ensureMap() async throws {
        guard hasPage else { throw AgentToolError("No page is open yet. Use action=\"open\" with a URL or search words first.") }
        if !mapped { _ = try await js("__synapse.map(90, 0)") }
    }

    /// Wait for navigation that an action may have started, then a moment for scripts to settle.
    private func settle(seconds: Double) async {
        mapped = false
        let deadline = Date().addingTimeInterval(seconds)
        try? await Task.sleep(for: .milliseconds(350))
        while (webView.isLoading || loading) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .milliseconds(webView.isLoading ? 200 : 500))
    }

    private func snapshot() async {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: UIImage? = await withCheckedContinuation { c in
            webView.takeSnapshot(with: config) { image, _ in c.resume(returning: image) }
        }
        guard let image else { return }
        let scale = min(1, 1_024 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        screenshot = resized.jpegData(compressionQuality: 0.7)?.base64EncodedString()
    }

    /// Take the latest screenshot (once) for the next model request.
    func takeScreenshot() -> String? {
        defer { screenshot = nil }
        return screenshot
    }

    /// Run JavaScript on the page. Uses the completion-handler API: the async one traps when a script returns undefined.
    private func js(_ source: String) async throws -> Any? {
        let present = (try? await evaluate("typeof __synapse")) as? String == "object"
        if !present { _ = try? await evaluate(Self.script) }
        do {
            return try await evaluate(source)
        } catch {
            throw AgentToolError("The page didn't respond (\(error.localizedDescription)). Wait a moment or open it again.")
        }
    }

    private func evaluate(_ source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(source) { result, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: result) }
            }
        }
    }

    private func log(_ title: String) {
        actions.append(BrowserAction(title: title))
        if actions.count > 60 { actions.removeFirst(actions.count - 60) }
    }

    /// The user takes over or clears the screen.
    func userNavigate(_ text: String) {
        hasPage = true
        pointer = nil
        toast = nil
        marks = []
        webView.load(URLRequest(url: Self.url(for: text)))
    }

    func clearMarks() {
        marks = []
        pointer = nil
        toast = nil
    }

    // MARK: - Helpers

    nonisolated static func url(for text: String) -> URL {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), let scheme = u.scheme, ["http", "https"].contains(scheme.lowercased()), u.host != nil { return u }
        let looksLikeHost = !t.contains(" ") && t.contains(".") && !t.hasSuffix(".")
        if looksLikeHost, let u = URL(string: "https://" + t), u.host != nil { return u }
        let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? ""
        return URL(string: "https://www.google.com/search?q=\(q)")!
    }

    nonisolated static func keyName(_ s: String) -> String {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "enter", "return", "⏎", "": return "Enter"
        case "esc", "escape": return "Escape"
        case "tab": return "Tab"
        case "backspace", "delete": return "Backspace"
        case "space": return " "
        case "up", "arrowup": return "ArrowUp"
        case "down", "arrowdown": return "ArrowDown"
        default: return s
        }
    }

    nonisolated static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }

    nonisolated static func rect(_ any: Any?) -> CGRect {
        guard let r = any as? [String: Any] else { return .zero }
        return CGRect(x: r["x"] as? Double ?? 0, y: r["y"] as? Double ?? 0, width: r["w"] as? Double ?? 0, height: r["h"] as? Double ?? 0)
    }

    nonisolated static func shortHref(_ href: String) -> String? {
        guard let u = URL(string: href) else { return nil }
        if u.scheme == "javascript" { return nil }
        var s = (u.host() ?? "") + u.path
        if let q = u.query, !q.isEmpty { s += "?" + q.prefix(30) }
        return String(s.prefix(70))
    }

    /// The page-side helper: the map of interactive elements, clicks, typing, keys, scrolling and text.
    nonisolated static let script = #"""
    (function(){
    if (window.__synapse) return;
    var S = window.__synapse = { els: [] };
    var SEL = 'a[href], button, input, select, textarea, summary, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="option"], [role="checkbox"], [role="textbox"], [role="combobox"], [role="searchbox"], [contenteditable="true"], [onclick]';
    function visible(el){
      var r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) return false;
      if (r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) return false;
      var st = getComputedStyle(el);
      if (st.visibility === 'hidden' || st.display === 'none' || st.opacity === '0') return false;
      var cx = Math.min(innerWidth - 1, Math.max(0, r.left + r.width / 2)), cy = Math.min(innerHeight - 1, Math.max(0, r.top + r.height / 2));
      var top = document.elementFromPoint(cx, cy);
      return !!top && (top === el || el.contains(top) || top.contains(el));
    }
    function label(el){
      var t = (el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || '').trim();
      if (t) return t;
      if (el.id) { try { var l = document.querySelector('label[for="' + CSS.escape(el.id) + '"]'); if (l && l.innerText.trim()) return l.innerText.trim(); } catch (e) {} }
      var inner = (el.innerText || '').trim().replace(/\s+/g, ' ');
      if (inner) return inner;
      if (el.tagName === 'INPUT' && el.value && ['submit','button'].indexOf((el.type||'').toLowerCase()) >= 0) return String(el.value);
      var img = el.querySelector('img[alt]'); if (img && img.alt.trim()) return img.alt.trim();
      var svg = el.querySelector('svg title'); if (svg && svg.textContent.trim()) return svg.textContent.trim();
      return '';
    }
    function kind(el){
      var tag = el.tagName.toLowerCase(), role = el.getAttribute('role');
      if (tag === 'a') return 'link';
      if (tag === 'button' || role === 'button') return 'button';
      if (tag === 'input') { var t = (el.type || 'text').toLowerCase(); if (['submit','button','image','reset'].indexOf(t) >= 0) return 'button'; if (t === 'checkbox' || t === 'radio') return t; return 'field(' + t + ')'; }
      if (tag === 'textarea' || el.isContentEditable || role === 'textbox' || role === 'searchbox' || role === 'combobox') return 'field';
      if (tag === 'select') return 'select';
      return role || tag;
    }
    function textNear(limit){
      if (!limit || !document.body) return '';
      var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), out = [], total = 0, range = document.createRange(), last = null;
      while (w.nextNode()) {
        var n = w.currentNode, s = n.nodeValue.replace(/\s+/g, ' ').trim();
        if (!s) continue;
        var p = n.parentElement; if (!p) continue;
        var tag = p.tagName; if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') continue;
        range.selectNodeContents(n);
        var r = range.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) continue;
        if (r.bottom < -innerHeight * 0.3 || r.top > innerHeight * 1.3) continue;
        var block = p.closest('p, li, h1, h2, h3, h4, h5, h6, td, th, div, section, article, blockquote, pre, dd, dt, label, summary, figcaption') || p;
        if (block === last) out[out.length - 1] += ' ' + s; else out.push(s);
        last = block;
        total += s.length + 1;
        if (total > limit) break;
      }
      return out.join('\n').slice(0, limit);
    }
    S.map = function(max, textLimit){
      var out = [], seen = new Set(); S.els = [];
      var all = document.querySelectorAll(SEL);
      for (var i = 0; i < all.length && out.length < max; i++) {
        var el = all[i];
        if (seen.has(el) || !visible(el)) continue;
        // Skip a wrapper whose only content is another interactive element (nested link in a button, etc.).
        var inner = el.querySelector(SEL);
        if (inner && visible(inner) && el.innerText.trim() === inner.innerText.trim() && el.tagName !== 'A') continue;
        seen.add(el);
        var r = el.getBoundingClientRect();
        S.els.push(el);
        var rec = { n: out.length + 1, kind: kind(el), text: label(el).slice(0, 80), rect: { x: r.left, y: r.top, w: r.width, h: r.height } };
        if (el.tagName === 'A' && el.href) rec.href = String(el.href).slice(0, 160);
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') { if (el.value && rec.kind !== 'button') rec.value = String(el.value).slice(0, 60); if (el.checked) rec.checked = true; }
        if (el.tagName === 'SELECT') { var o = el.options[el.selectedIndex]; if (o) rec.value = String(o.text).slice(0, 60); }
        out.push(rec);
      }
      return { title: document.title, url: location.href, scrollY: scrollY, height: document.documentElement.scrollHeight, viewport: innerHeight, elements: out, text: textNear(textLimit) };
    };
    function fire(el){
      var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      var o = { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window };
      try { el.dispatchEvent(new PointerEvent('pointerdown', o)); el.dispatchEvent(new MouseEvent('mousedown', o)); el.dispatchEvent(new PointerEvent('pointerup', o)); el.dispatchEvent(new MouseEvent('mouseup', o)); } catch (e) {}
      try { if (el.focus) el.focus(); } catch (e) {}
      el.click();
      return { rect: { x: r.left, y: r.top, w: r.width, h: r.height }, text: label(el).slice(0, 60) };
    }
    S.click = function(n){
      var el = S.els[n - 1];
      if (!el) return { error: 'There is no element [' + n + '] on the page map. Read the page again and use a number from the map.' };
      el.scrollIntoView({ block: 'center', inline: 'center' });
      return fire(el);
    };
    S.clickText = function(t){
      t = t.toLowerCase();
      var i = S.els.findIndex(function(e){ return label(e).toLowerCase() === t; });
      if (i < 0) i = S.els.findIndex(function(e){ return label(e).toLowerCase().indexOf(t) >= 0; });
      if (i < 0) return { error: 'No visible link or button says "' + t + '". Use an element number from the map, or scroll to find it.' };
      return S.click(i + 1);
    };
    S.type = function(n, text, submit){
      var el = n > 0 ? S.els[n - 1] : document.activeElement;
      if (!el || el === document.body) return { error: n > 0 ? 'There is no element [' + n + '].' : 'No field is focused: add target="number" with a field from the map.' };
      if (!(el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) {
        var inner = el.querySelector('input, textarea, [contenteditable="true"]');
        if (inner) el = inner; else return { error: 'Element [' + n + '] is a ' + kind(el) + ', not a text field.' };
      }
      el.scrollIntoView({ block: 'center' });
      try { el.focus(); } catch (e) {}
      var r = el.getBoundingClientRect();
      if (el.isContentEditable) {
        document.execCommand('selectAll', false, null);
        document.execCommand('insertText', false, text);
      } else {
        var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        var d = Object.getOwnPropertyDescriptor(proto, 'value');
        if (d && d.set) d.set.call(el, text); else el.value = text;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      if (submit) S.key('Enter', el);
      return { rect: { x: r.left, y: r.top, w: r.width, h: r.height } };
    };
    S.key = function(key, el){
      el = el || document.activeElement || document.body;
      var code = key === 'Enter' ? 13 : key === 'Escape' ? 27 : key === 'Tab' ? 9 : key === 'Backspace' ? 8 : key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0;
      var init = { key: key, code: key === ' ' ? 'Space' : key, keyCode: code, which: code, bubbles: true, cancelable: true };
      var ok = el.dispatchEvent(new KeyboardEvent('keydown', init));
      el.dispatchEvent(new KeyboardEvent('keypress', init));
      el.dispatchEvent(new KeyboardEvent('keyup', init));
      if (key === 'Enter' && ok) { var f = el.form || (el.closest && el.closest('form')); if (f) { if (f.requestSubmit) f.requestSubmit(); else f.submit(); } }
      if (key === 'Escape') { try { document.activeElement.blur(); } catch (e) {} }
      return { ok: true };
    };
    S.scroll = function(how){
      if (/^\d+$/.test(how)) { var el = S.els[Number(how) - 1]; if (!el) return { error: 'There is no element [' + how + '].' }; el.scrollIntoView({ block: 'center' }); return { ok: true }; }
      var h = innerHeight * 0.85;
      if (how === 'up') scrollBy(0, -h); else if (how === 'top') scrollTo(0, 0); else if (how === 'bottom') scrollTo(0, document.documentElement.scrollHeight); else scrollBy(0, h);
      return { ok: true };
    };
    S.find = function(q){
      var txt = (document.body && document.body.innerText) || '', lower = txt.toLowerCase(), hits = [], i = 0; q = q.toLowerCase();
      while (hits.length < 5 && (i = lower.indexOf(q, i)) >= 0) { hits.push(txt.slice(Math.max(0, i - 120), i + q.length + 200).replace(/\s+/g, ' ')); i += q.length; }
      return { hits: hits };
    };
    S.allText = function(limit){ return ((document.body && document.body.innerText) || '').replace(/\n{3,}/g, '\n\n').slice(0, limit); };
    })();
    """#
}

extension AgentBrowser: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        marks = []
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        title = webView.title ?? ""
        url = webView.url
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        alerts.append("Couldn't load the page: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { alerts.append("Couldn't load the page: \(error.localizedDescription)") }
    }

    /// Links that want a new window open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    /// Dialogs are answered for the agent and reported in the next page description.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        alerts.append(message)
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        alerts.append("Confirm: \(message) (answered OK)")
        completionHandler(true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        alerts.append("Prompt: \(prompt) (left empty)")
        completionHandler(defaultText)
    }
}

// MARK: - Views

/// The browser's web view inside SwiftUI. One web view serves the whole app, so whichever screen shows it last
/// takes it over.
struct BrowserWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let wv = AgentBrowser.shared.webView
        if wv.superview !== container {
            wv.removeFromSuperview()
            wv.translatesAutoresizingMaskIntoConstraints = true
            wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            wv.frame = container.bounds
            container.addSubview(wv)
        }
    }
}

/// The screen the user watches: the page with the agent's marks (numbered elements, the ring where it tapped, what
/// it typed).
struct BrowserScreen: View {
    @State private var tick = 0

    var body: some View {
        let browser = AgentBrowser.shared
        ZStack(alignment: .topLeading) {
            BrowserWebView().id(tick)
            // The marks never block touches: the user can scroll and tap the page too.
            ZStack(alignment: .topLeading) {
                if browser.showMarks {
                    ForEach(browser.marks) { m in
                        Text("\(m.number)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .offset(x: max(0, m.rect.minX - 2), y: max(0, m.rect.minY - 9))
                    }
                }
                if let p = browser.pointer {
                    PointerRing(rect: p.rect).id(p.id)
                }
                if let toast = browser.toast {
                    Text(toast)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
                if browser.loading {
                    ProgressView().padding(8).background(.ultraThinMaterial, in: Circle()).padding(8)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
            .allowsHitTesting(false)
        }
        .clipped()
        .onAppear { tick += 1 }
    }
}

/// A ring that pops where the agent tapped, then fades.
private struct PointerRing: View {
    let rect: CGRect
    @State private var shown = false

    var body: some View {
        let r = rect.width < 4 ? CGRect(x: rect.midX - 20, y: rect.midY - 20, width: 40, height: 40) : rect.insetBy(dx: -4, dy: -4)
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.red, lineWidth: 3)
            .background(Color.red.opacity(shown ? 0.08 : 0.3), in: RoundedRectangle(cornerRadius: 8))
            .frame(width: max(24, r.width), height: max(24, r.height))
            .scaleEffect(shown ? 1 : 1.25)
            .opacity(shown ? 0.9 : 0.4)
            .offset(x: r.minX, y: r.minY)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.35)) { shown = true } }
    }
}

/// The browser panel in a chat: a small live screen with the page's title; tap it for the full Computer view.
struct BrowserPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let browser = AgentBrowser.shared
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(browser.title.isEmpty ? "Computer" : browser.title).font(.caption.weight(.semibold)).lineLimit(1)
                    if let u = browser.url { Text(u.host() ?? u.absoluteString).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if let last = browser.actions.last { Text(last.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Button { app.agentsPath.append(.computer) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            BrowserScreen().frame(height: 320)
        }
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Computer: the full-size browser screen with the agent's action log, an address bar for the user, and Stop.
struct ComputerView: View {
    @Environment(AgentCenter.self) private var center
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        let browser = AgentBrowser.shared
        let session = browser.conversationID.map { center.session($0) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.webView.canGoBack)
                TextField("Search or enter a website", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($addressFocused)
                    .onSubmit { browser.userNavigate(address); addressFocused = false }
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.disabled(!browser.hasPage)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if browser.hasPage {
                BrowserScreen()
            } else {
                ContentUnavailableView("Nothing open yet", systemImage: "macwindow",
                                       description: Text("Ask the Browser agent to do something on a website, or type an address above. You'll see every tap and keystroke here."))
            }
            VStack(alignment: .leading, spacing: 4) {
                if let session, session.running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(browser.driver ?? "Agent"): \(session.status.isEmpty ? "working…" : session.status)").font(.footnote).lineLimit(1)
                        Spacer()
                        Button(role: .destructive) { if let id = browser.conversationID { center.stop(id) } } label: { Label("Stop", systemImage: "stop.fill") }
                            .font(.footnote.weight(.semibold))
                    }
                }
                ForEach(browser.actions.suffix(4).reversed()) { a in
                    HStack(spacing: 6) {
                        Text(a.time, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        Text(a.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
        .navigationTitle("Computer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: Binding(get: { browser.showMarks }, set: { browser.showMarks = $0 })) { Label("Number the elements", systemImage: "number.square") }
                    Button { browser.clearMarks() } label: { Label("Clear marks", systemImage: "eraser") }
                    if let id = browser.conversationID {
                        NavigationLink(value: Route.agentChat(id)) { Label("Open the chat", systemImage: "bubble.left") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { address = browser.url?.absoluteString ?? "" }
        .onChange(of: browser.url) { _, u in if !addressFocused { address = u?.absoluteString ?? "" } }
    }
}
