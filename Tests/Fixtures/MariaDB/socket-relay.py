"""Expose the test container's TCP port as a private Unix socket on the Mac."""

import os
import select
import socket
import socketserver
import signal
from pathlib import Path


class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        with socket.create_connection(("127.0.0.1", 33461), timeout=5) as server:
            server.settimeout(None)
            peers = {self.request: server, server: self.request}
            while peers:
                readable, _, _ = select.select(list(peers), [], [])
                for source in readable:
                    data = source.recv(65536)
                    if data:
                        peers[source].sendall(data)
                    else:
                        peers.pop(source).shutdown(socket.SHUT_WR)


if __name__ == "__main__":
    os.umask(0o077)
    directory = Path(__file__).resolve().parents[3] / ".build" / "SocketFixture"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = directory / "db.sock"
    # Handle Ctrl-C and termination without leaving an unusable socket behind.
    def stop(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    with socketserver.ThreadingUnixStreamServer(str(path), Relay) as listener:
        try:
            listener.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            path.unlink(missing_ok=True)
