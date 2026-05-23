#!/usr/bin/env python3
import argparse
import signal
import sys
import threading
import time

import pinggy


def main() -> int:
    parser = argparse.ArgumentParser(description="Start a Pinggy tunnel and keep it alive.")
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()

    stop_event = threading.Event()

    def handle_signal(_signum, _frame):
        stop_event.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    tunnel = pinggy.start_tunnel(forwardto=f"127.0.0.1:{args.port}")
    try:
        for url in tunnel.urls:
            print(url, flush=True)
        while not stop_event.wait(1):
            pass
    finally:
        try:
            tunnel.stop()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
