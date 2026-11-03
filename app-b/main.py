import os
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

POD = os.getenv("POD", "unknown")
NODE = os.getenv("NODE", "unknown")
PORT = int(os.getenv("PORT", "8080"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        message = "Hello from app-b"
        print(f"[{time}] {message} | pod={POD} | node={NODE}", flush=True)
        body = message.encode()
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

print(f"[app-b] pod={POD} node={NODE} start: listening on {PORT}", flush=True)
HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()