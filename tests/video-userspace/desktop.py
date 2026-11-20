"""Serve only generated test clips on the isolated guest's loopback."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import subprocess
import time
from gi.repository import Gio


class Player(SimpleHTTPRequestHandler):
    result = None

    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        if self.path != "/result" or not 0 < (size := int(self.headers["Content-Length"])) <= 2000:
            self.send_error(400)
            return
        Player.result = json.loads(self.rfile.read(size))
        self.send_response(204)
        self.end_headers()


def main():
    assert os.getuid() == 1000
    for mime in ("video/mp4", "video/webm"):
        app = Gio.AppInfo.get_default_for_type(mime, False)
        print(f"FILE_HANDLER mime={mime} default={app.get_id() if app else 'none'}", flush=True)
    with ThreadingHTTPServer(("127.0.0.1", 0), Player) as server:
        server.timeout = .5
        url = f"http://127.0.0.1:{server.server_port}/player.html"
        with subprocess.Popen(["chromium", "--user-data-dir=/run/video-user/chromium", "--no-first-run",
                               "--disable-background-networking", "--kiosk", url], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL) as browser:
            try:
                deadline = time.monotonic() + 115
                while not Player.result and time.monotonic() < deadline and browser.poll() is None:
                    server.handle_request()
                assert Player.result, "Chromium did not return a playback result"
                print("CHROMIUM_PLAYBACK", json.dumps(Player.result, sort_keys=True), flush=True)
                assert set(Player.result) == {"vp9.webm", "h264.mp4", "hevc.mp4"}
                for name in ("vp9.webm", "h264.mp4"):
                    entry = Player.result[name]
                    assert entry["decoded"] and entry["ended"], name
                    assert {colour for _, colour in entry["samples"]} == {"01", "12", "20"}
                assert Player.result["hevc.mp4"] == {"decoded": False, "error": "media-4"}
            finally:
                browser.terminate()


if __name__ == "__main__":
    main()
