"""Observe a local Chromium input element's composition and committed DOM value."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path

root = Path(os.environ["CHINESE_INPUT_TEST_DIR"])
page = """<!doctype html>
<meta charset="utf-8"><title>Y700 input fixture</title>
<main><input id="entry" aria-label="Y700 text entry" style="width: 400px">
<button id="ready">Ready</button></main>
<script>
const entry = document.getElementById('entry');
let preedit = '';
let committed = '';
let composing = false;
let reports = Promise.resolve();
function report() {
    const bounds = (id) => {
        const {x, y, width, height} = document.getElementById(id).getBoundingClientRect();
        return [x, y, width, height];
    };
    const json = JSON.stringify({
        preedit, committed, scale: devicePixelRatio,
        active: document.activeElement.id,
        viewport: [innerWidth, innerHeight],
        entry: bounds('entry'), ready: bounds('ready'),
    });
    reports = reports.then(() => fetch('/state', {method: 'POST', body: json}));
}
entry.addEventListener('compositionstart', () => {
    composing = true;
    committed = entry.value;
    report();
});
entry.addEventListener('compositionupdate', (event) => {
    preedit = event.data;
    report();
});
entry.addEventListener('compositionend', () => {
    composing = false;
    preedit = '';
    committed = entry.value;
    report();
});
entry.addEventListener('input', (event) => {
    if (!composing && !event.isComposing) {
        committed = entry.value;
        report();
    }
});
document.getElementById('ready').focus();
document.addEventListener('focusin', report);
addEventListener('resize', report);
report();
</script>
""".encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if self.path != "/state" or not 0 < length <= 1024:
            self.send_error(400)
            return
        data = json.loads(self.rfile.read(length))
        scratch = root / "browser.tmp"
        scratch.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        scratch.replace(root / "browser.json")
        self.send_response(204)
        self.end_headers()


server = HTTPServer(("127.0.0.1", 8938), Handler)
(root / "browser-server").touch()
server.serve_forever()
