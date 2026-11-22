"""最小 HTTP tracker，只用来造 tracker 状态。只依赖标准库。

路径（announce 和 scrape 都支持）：
  /ok/announce      正常返回，空 peer 列表
  /unreg/announce   返回 failure reason: Unregistered torrent
  /warn/announce    正常返回，同时带 warning message
  /err500/announce  HTTP 500
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def bencode(v) -> bytes:
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, str):
        v = v.encode()
    if isinstance(v, bytes):
        return b"%d:%s" % (len(v), v)
    if isinstance(v, list):
        return b"l" + b"".join(bencode(x) for x in v) + b"e"
    if isinstance(v, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, x) for k, x in v.items())
        return b"d" + b"".join(bencode(k) + bencode(x) for k, x in items) + b"e"
    raise TypeError(type(v))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        mode, _, action = path.strip("/").partition("/")
        if mode == "err500":
            self.send_error(500)
            return
        if action == "scrape":
            body = bencode({"files": {}})
        elif mode == "unreg":
            body = bencode({"failure reason": "Unregistered torrent"})
        elif mode == "warn":
            body = bencode({"interval": 1800, "peers": b"", "warning message": "Rate limited"})
        elif mode == "ok":
            body = bencode({"interval": 1800, "complete": 1, "incomplete": 0, "peers": b""})
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("tracker:", self.address_string(), fmt % args, flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 6969), Handler).serve_forever()
