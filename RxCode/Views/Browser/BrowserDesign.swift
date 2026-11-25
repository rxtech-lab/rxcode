import AppKit
import RxCodeCore
import WebKit

extension WorkspaceBrowserTab {
    /// This isolated content world only accepts data arguments. Page code has no native message handler.
    func inspectPage(_ operation: String, selector: String = "", text: String = "", point: CGPoint = .zero) async throws -> JSONValue {
        let json: String
        if let chromeController {
            json = try await chromeController.evaluateIsolatedScript(
                body: Self.inspectionScript,
                arguments: [
                    "operation": .string(operation),
                    "selector": .string(selector),
                    "newText": .string(text),
                    "x": .number(point.x),
                    "y": .number(point.y),
                ]
            )
        } else {
            let value = try await webView.callAsyncJavaScript(Self.inspectionScript, arguments: [
                "operation": operation, "selector": selector, "newText": text, "x": point.x, "y": point.y
            ], in: nil, contentWorld: .defaultClient)
            guard let string = value as? String else { throw IDEToolError.handlerFailed("The page did not return an element.") }
            json = string
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func designSelection(at point: CGPoint, size: CGSize) async throws -> DesignSelection {
        let value = try await inspectDesignPoint("pick", at: point, size: size)
        return DesignSelection(title: value["label"]?.stringValue ?? value["tag"]?.stringValue ?? "HTML element",
                               context: "Browser tab \(id.uuidString)\nPage \(address?.absoluteString ?? "")\n\(value)",
                               image: try? await takeSnapshot(), point: point,
                               rect: Self.designRect(value["bounds"], size: size))
    }

    func designHoverBounds(at point: CGPoint, size: CGSize) async -> CGRect? {
        let bounds = try? await inspectDesignPoint("bounds", at: point, size: size)
        return Self.designRect(bounds, size: size)
    }

    private func inspectDesignPoint(_ operation: String, at point: CGPoint, size: CGSize) async throws -> JSONValue {
        guard size.width > 0, size.height > 0 else { throw IDEToolError.handlerFailed("The page has no visible content.") }
        return try await inspectPage(operation, point: CGPoint(x: point.x / size.width, y: point.y / size.height))
    }

    private static func designRect(_ bounds: JSONValue?, size: CGSize) -> CGRect? {
        guard let x = bounds?["x"]?.numberValue, let y = bounds?["y"]?.numberValue,
              let width = bounds?["width"]?.numberValue, let height = bounds?["height"]?.numberValue,
              width > 0, height > 0 else { return nil }
        return CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }

    private static let inspectionScript = #"""
    const path = el => {
      const parts = [];
      const root = el.getRootNode();
      while (el && el.nodeType === 1) {
        if (el.id && root.querySelectorAll('#' + CSS.escape(el.id)).length === 1) {
          parts.unshift('#' + CSS.escape(el.id)); break;
        }
        const siblings = el.parentNode ? Array.from(el.parentNode.children).filter(s => s.localName === el.localName) : [el];
        parts.unshift(CSS.escape(el.localName) + (siblings.length > 1 ? ':nth-of-type(' + (siblings.indexOf(el)+1) + ')' : ''));
        el = el.parentElement;
      }
      return parts.join(' > ');
    };
    const viewport = {w: window.innerWidth, h: window.innerHeight};
    const boundsOnly = operation === 'bounds';
    let root = document, el, prefix = [], dx = 0, dy = 0;
    if (operation === 'pick' || boundsOnly) {
      let px = x * viewport.w, py = y * viewport.h;
      for (let depth = 0; depth < 12; depth++) {
        el = root.elementFromPoint(px, py);
        if (!el) throw Error('No element at this position.');
        if (el.shadowRoot) {
          const inner = el.shadowRoot.elementFromPoint(px, py);
          if (inner && inner !== el) {
            if (!boundsOnly) prefix.push(path(el), 'shadow');
            root = el.shadowRoot;
            continue;
          }
        }
        if (el.localName === 'iframe' && el.contentDocument) {
          const r = el.getBoundingClientRect(), left = r.x + el.clientLeft, top = r.y + el.clientTop;
          dx += left; dy += top; px -= left; py -= top;
          if (!boundsOnly) prefix.push(path(el), 'frame');
          root = el.contentDocument;
          continue;
        }
        break;
      }
    } else if (operation === 'elements') {
      const items = Array.from(document.querySelectorAll('a[href],button,input:not([type=hidden]),textarea,select,[role],[contenteditable=true]'))
        .filter(e => e.getClientRects().length).slice(0,150).map(e => ({selector:path(e), tag:e.localName,
          label:(e.getAttribute('aria-label') || e.innerText || e.placeholder || e.title || '').trim().slice(0,120)}));
      return JSON.stringify(items);
    } else {
      const parts = selector.startsWith('[') ? (() => {try {const p=JSON.parse(selector); return Array.isArray(p) ? p : [selector];} catch {return [selector];}})() : [selector];
      for (let i = 0; i < parts.length; i += 2) {
        el = root.querySelector(parts[i]);
        if (!el) throw Error('Element no longer exists. Inspect the page again.');
        if (i + 1 < parts.length) root = parts[i+1] === 'shadow' ? el.shadowRoot : el.contentDocument;
        if (!root) throw Error('This element belongs to an inaccessible frame.');
      }
      if (operation === 'click') { el.click(); return JSON.stringify({clicked:selector}); }
      if (operation === 'type') {
        if (!(el.matches('input:not([type=password]):not([type=file]),textarea') || el.isContentEditable)) throw Error('Select an editable text field.');
        el.focus();
        if (el.isContentEditable) el.textContent = newText;
        else {const proto = el.localName === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(proto,'value').set.call(el,newText);}
        el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));
        return JSON.stringify({updated:selector});
      }
    }
    const r = el.getBoundingClientRect();
    const bounds = {x:(r.x+dx)/viewport.w, y:(r.y+dy)/viewport.h, width:r.width/viewport.w, height:r.height/viewport.h};
    if (boundsOnly) return JSON.stringify(bounds);
    const name = (el.getAttribute('aria-label') || el.innerText || el.placeholder || el.title || '').trim().slice(0,160);
    return JSON.stringify({selector:prefix.length ? JSON.stringify([...prefix,path(el)]) : path(el), tag:el.localName,
      role:el.getAttribute('role'), label:name || el.localName, bounds});
    """#
}
