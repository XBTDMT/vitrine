#!/usr/bin/env python3
"""Drive `vitrine mcp` as a client would (X-9, G-22): handshake, the tool list, then every tool on each file given.

Usage: python3 -I app/tools/mcp_probe.py <path to Vitrine.app/Contents/Helpers/vitrine> <file>... [--image <out.png>]

Prints one line per call (tool, seconds, error flag, the answer's first lines) and exits 1 when a call on an existing
file fails. Read-only: the connector never writes, and this script only reads its answers. Use invented files.
roadmap: S-11
"""
import base64
import json
import subprocess
import sys
import time


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 64
    exe, rest = argv[1], argv[2:]
    image_out = None
    if "--image" in rest:
        i = rest.index("--image")
        image_out = rest[i + 1]
        rest = rest[:i] + rest[i + 2:]
    proc = subprocess.Popen([exe, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    counter = [0]

    def call(method, params):
        counter[0] += 1
        proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": counter[0], "method": method, "params": params}) + "\n").encode())
        proc.stdin.flush()
        return json.loads(proc.stdout.readline())

    init = call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mcp_probe", "version": "1"}})
    print("server:", init["result"]["serverInfo"], "protocol", init["result"]["protocolVersion"])
    print("tools:", [t["name"] for t in call("tools/list", {})["result"]["tools"]])
    failures = 0
    for path in rest:
        calls = [("describe_file", {}), ("render", {"limit": 3}), ("scan_secrets", {}), ("token_count", {})]
        if image_out:
            calls.append(("render", {"format": "image"}))
        for tool, extra in calls:
            started = time.time()
            result = call("tools/call", {"name": tool, "arguments": {"path": path, **extra}}).get("result", {})
            seconds = time.time() - started
            failures += bool(result.get("isError"))
            shown = []
            for part in result.get("content", []):
                if part["type"] == "image":
                    if image_out:
                        open(image_out, "wb").write(base64.b64decode(part["data"]))
                    shown.append(f"PNG {len(part['data']) * 3 // 4:,} bytes")
                else:
                    lines = [l for l in part["text"].split("\n") if not l.startswith(("<untrusted", "</untrusted", "The text above"))]
                    shown.append(" ‖ ".join(l[:80] for l in lines[:3]))
            print(f"{path.split('/')[-1][:30]:30} {tool:13} {seconds:5.2f}s error={result.get('isError')} | {' '.join(shown)}")
    proc.stdin.close()
    proc.wait(timeout=10)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
