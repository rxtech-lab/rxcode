import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    let content: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.underPageBackgroundColor = .clear
        webView.loadHTMLString(Self.buildHTML(content: content), baseURL: nil)
        context.coordinator.lastHash = content.hashValue
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let hash = content.hashValue
        guard context.coordinator.lastHash != hash else { return }
        context.coordinator.lastHash = hash
        webView.loadHTMLString(Self.buildHTML(content: content), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHash: Int = 0
    }

    private static func buildHTML(content: String) -> String {
        let jsonString: String
        if let data = try? JSONEncoder().encode(content),
           let s = String(data: data, encoding: .utf8) {
            jsonString = s
        } else {
            jsonString = "\"\""
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(Self.cssScaffold)</style>
        </head>
        <body>
        <div id="root"></div>
        <script>const __RXCODE_MD__ = \(jsonString);</script>
        <script>\(Self.jsParser)</script>
        </body>
        </html>
        """
    }

    // Theme colors selected via CSS media query so a single HTML build covers
    // both appearances and live-updates if the user switches system mode.
    private static let cssScaffold: String = """
    :root {
        --bg:#FFFFFF; --text:#1A1A1A; --text2:#666666;
        --codeBg:#F5F2EF; --border:#E8E3DC; --link:#D97757;
        --quoteBg:#FDF6F0; --evenRow:#FAFAF8;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --bg:#1E1E1E; --text:#E8E3DC; --text2:#A09880;
            --codeBg:#2A2A2A; --border:#3A3A3A; --link:#D97757;
            --quoteBg:#2A2520; --evenRow:#242424;
        }
    }
    * { box-sizing:border-box; margin:0; padding:0; }
    html,body { background:var(--bg); }
    body {
        font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;
        font-size:14px; line-height:1.7; color:var(--text);
        padding:24px 28px;
    }
    h1,h2,h3,h4,h5,h6 { color:var(--text); margin:1.4em 0 .5em; line-height:1.3; font-weight:600; }
    h1 { font-size:1.75em; padding-bottom:.3em; border-bottom:1px solid var(--border); }
    h2 { font-size:1.4em;  padding-bottom:.2em; border-bottom:1px solid var(--border); }
    h3 { font-size:1.15em; } h4 { font-size:1em; }
    p  { margin:.7em 0; }
    a  { color:var(--link); text-decoration:none; }
    a:hover { text-decoration:underline; }
    strong { font-weight:600; } em { font-style:italic; }
    del { text-decoration:line-through; color:var(--text2); }
    code {
        font-family:"SF Mono",Menlo,Monaco,Consolas,monospace;
        font-size:.875em; background:var(--codeBg);
        padding:.15em .4em; border-radius:4px; color:var(--text);
    }
    pre {
        background:var(--codeBg); border:1px solid var(--border);
        border-radius:8px; padding:16px; overflow-x:auto; margin:1em 0;
    }
    pre code { background:none; padding:0; font-size:.85em; line-height:1.6; }
    blockquote {
        border-left:3px solid var(--link); background:var(--quoteBg);
        margin:1em 0; padding:10px 16px; border-radius:0 6px 6px 0; color:var(--text2);
    }
    blockquote p { margin:0; }
    ul,ol { padding-left:1.5em; margin:.7em 0; }
    li { margin:.25em 0; }
    table { width:100%; border-collapse:collapse; margin:1em 0; font-size:.9em; }
    th,td { border:1px solid var(--border); padding:8px 12px; text-align:left; }
    th { background:var(--codeBg); font-weight:600; }
    tr:nth-child(even) td { background:var(--evenRow); }
    img { max-width:100%; border-radius:6px; margin:.5em 0; }
    hr { border:none; border-top:1px solid var(--border); margin:1.5em 0; }
    .task-item { list-style:none; margin-left:-1.2em; }
    .task-item input { margin-right:6px; }
    """

    private static let jsParser: String = #"""
    (function() {
        function escHTML(s) {
            return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        }

        function parseBlocks(md) {
            const lines = md.split('\n');
            const out = [];
            let i = 0;
            while (i < lines.length) {
                const line = lines[i];
                const fence = line.match(/^```(\w*)\s*$/);
                if (fence) {
                    const lang = fence[1];
                    i++;
                    const buf = [];
                    while (i < lines.length && !/^```\s*$/.test(lines[i])) { buf.push(lines[i]); i++; }
                    i++;
                    out.push('<pre><code' + (lang ? ' class="lang-' + lang + '"' : '') + '>' + escHTML(buf.join('\n')) + '</code></pre>');
                    continue;
                }
                if (/^[-*_]{3,}\s*$/.test(line)) { out.push('<hr>'); i++; continue; }
                const h = line.match(/^(#{1,6})\s+(.+?)\s*#*\s*$/);
                if (h) {
                    const lvl = h[1].length;
                    out.push('<h' + lvl + '>' + inline(h[2]) + '</h' + lvl + '>');
                    i++; continue;
                }
                if (/^>\s?/.test(line)) {
                    const buf = [];
                    while (i < lines.length && /^>\s?/.test(lines[i])) {
                        buf.push(lines[i].replace(/^>\s?/, ''));
                        i++;
                    }
                    out.push('<blockquote>' + parseBlocks(buf.join('\n')) + '</blockquote>');
                    continue;
                }
                if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
                    const ordered = /^\s*\d+\.\s+/.test(line);
                    const buf = [];
                    while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) { buf.push(lines[i]); i++; }
                    out.push(renderList(buf, ordered));
                    continue;
                }
                if (/^\|.+\|\s*$/.test(line) && i + 1 < lines.length && /^\|[\s:\-|]+\|\s*$/.test(lines[i + 1])) {
                    const tableLines = [];
                    while (i < lines.length && /^\|.+\|\s*$/.test(lines[i])) { tableLines.push(lines[i]); i++; }
                    out.push(renderTable(tableLines));
                    continue;
                }
                if (/^\s*$/.test(line)) { i++; continue; }
                const pbuf = [];
                while (
                    i < lines.length &&
                    !/^\s*$/.test(lines[i]) &&
                    !/^(```|#{1,6}\s|>\s?|\s*([-*+]|\d+\.)\s|[-*_]{3,}\s*$)/.test(lines[i]) &&
                    !(/^\|.+\|\s*$/.test(lines[i]) && i + 1 < lines.length && /^\|[\s:\-|]+\|\s*$/.test(lines[i + 1]))
                ) {
                    pbuf.push(lines[i]); i++;
                }
                if (pbuf.length) out.push('<p>' + inline(pbuf.join(' ')) + '</p>');
            }
            return out.join('\n');
        }

        function renderList(buf, ordered) {
            const items = buf.map(l => l.replace(/^\s*(?:[-*+]|\d+\.)\s+/, ''));
            const tag = ordered ? 'ol' : 'ul';
            const lis = items.map(it => {
                const tx = it.match(/^\[([ xX])\]\s+(.*)$/);
                if (tx) {
                    const checked = tx[1].toLowerCase() === 'x' ? ' checked' : '';
                    return '<li class="task-item"><input type="checkbox" disabled' + checked + '> ' + inline(tx[2]) + '</li>';
                }
                return '<li>' + inline(it) + '</li>';
            }).join('');
            return '<' + tag + '>' + lis + '</' + tag + '>';
        }

        function renderTable(rows) {
            if (rows.length < 2) return '';
            const header = rows[0].split('|').slice(1, -1).map(c => c.trim());
            const body = rows.slice(2);
            let out = '<table><thead><tr>';
            header.forEach(h => { out += '<th>' + inline(h) + '</th>'; });
            out += '</tr></thead><tbody>';
            body.forEach(r => {
                const cells = r.split('|').slice(1, -1).map(c => c.trim());
                out += '<tr>';
                cells.forEach(c => { out += '<td>' + inline(c) + '</td>'; });
                out += '</tr>';
            });
            return out + '</tbody></table>';
        }

        function inline(s) {
            const codes = [];
            s = s.replace(/`([^`]+)`/g, (_, c) => {
                codes.push('<code>' + escHTML(c) + '</code>');
                return '\u0000I' + (codes.length - 1) + '\u0000';
            });
            s = escHTML(s);
            s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, '<img src="$2" alt="$1">');
            s = s.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, '<a href="$2">$1</a>');
            s = s.replace(/\*\*\*([^*]+)\*\*\*/g, '<strong><em>$1</em></strong>');
            s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
            s = s.replace(/__([^_]+)__/g, '<strong>$1</strong>');
            s = s.replace(/(^|[^\*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
            s = s.replace(/(^|[^_])_([^_\n]+)_/g, '$1<em>$2</em>');
            s = s.replace(/~~([^~]+)~~/g, '<del>$1</del>');
            codes.forEach((c, i) => { s = s.split('\u0000I' + i + '\u0000').join(c); });
            return s;
        }

        document.getElementById('root').innerHTML = parseBlocks(__RXCODE_MD__);
    })();
    """#
}
