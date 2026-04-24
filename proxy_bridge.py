#!/usr/bin/env python3

import os
import selectors
import socket
import threading


LISTEN_HOST = os.environ.get("PROXY_BRIDGE_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("PROXY_BRIDGE_LISTEN_PORT", "17890"))
TARGET_HOST = os.environ.get("PROXY_BRIDGE_TARGET_HOST", "127.0.0.1")
TARGET_PORT = int(os.environ.get("PROXY_BRIDGE_TARGET_PORT", "7890"))


def pump(client, upstream):
    selector = selectors.DefaultSelector()
    selector.register(client, selectors.EVENT_READ, upstream)
    selector.register(upstream, selectors.EVENT_READ, client)
    sockets = {client, upstream}
    try:
        while True:
            for key, _ in selector.select():
                source = key.fileobj
                target = key.data
                try:
                    data = source.recv(65536)
                except OSError:
                    return
                if not data:
                    return
                view = memoryview(data)
                while view:
                    sent = target.send(view)
                    view = view[sent:]
    finally:
        for sock in sockets:
            try:
                sock.close()
            except OSError:
                pass
        selector.close()


def handle(client_sock, client_addr):
    upstream = socket.create_connection((TARGET_HOST, TARGET_PORT))
    try:
        pump(client_sock, upstream)
    finally:
        try:
            print(f"closed proxy bridge client {client_addr[0]}:{client_addr[1]}", flush=True)
        except Exception:
            pass


def main():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((LISTEN_HOST, LISTEN_PORT))
        server.listen(128)
        print(
            f"proxy bridge listening on {LISTEN_HOST}:{LISTEN_PORT} -> {TARGET_HOST}:{TARGET_PORT}",
            flush=True,
        )
        while True:
            client, addr = server.accept()
            thread = threading.Thread(target=handle, args=(client, addr), daemon=True)
            thread.start()


if __name__ == "__main__":
    main()
