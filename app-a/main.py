import os
import time
import urllib

URL = os.getenv("SERVER_URL", "http://localhost:8080")
INTERVAL = int(os.getenv("INTERVAL", 5))
POD = os.getenv("POD", "unknown")
NODE = os.getenv("NODE", "unknown")

print(f"[app-a] pod={POD} node={NODE} start: target={URL} interval={INTERVAL}s", flush=True)
while True:
    try:
        with urllib.request.urlopen(URL, timeout=3) as response:
            print(f"[app-a] pod={POD} node={NODE} -> app-b: {response.read().decode()}", flush=True)
    except Exception as e:
        print(f"[app-a] pod={POD} node={NODE} -> app-b: ERROR ({e})", flush=True)
    time.sleep(INTERVAL)