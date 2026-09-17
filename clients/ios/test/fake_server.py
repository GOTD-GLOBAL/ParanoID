#!/usr/bin/env python3
"""A pinned-TLS fake of the self-service v2 edge, for the iOS transport checks.

``clients/ios/test_realtime_transport.py`` drives ``RealtimeTransport`` against
this server. It is deliberately **not** an ``http.server``: every rule the
transport has to survive is a socket rule, and only a hand-written HTTP/1.1
loop can actually break a connection where it has to be broken.

What it really does, rather than pretends to do:

* serves TLS with the throw-away identity ``scripts/create-test-tls.py``
  issues, so the client's nine pinned checks run for real (ALPN is pinned to
  ``http/1.1``; nothing here speaks HTTP/2);
* keeps connections alive, and **closes an idle one after eight seconds**
  (``docs/protocol/realtime-v1.md:150-151``), recording that it did;
* **breaks a connection in the middle of a request** with ``SO_LINGER 0`` — a
  TCP reset with no ``close_notify``, which is what a dropped long poll and a
  killed pooled socket look like on the wire;
* counts what arrived: requests per path and per operation, bytes of every
  request body, how many ``Authorization`` headers each request carried, how
  many requests shared one connection, and the largest number of requests that
  were ever in flight at the same time.

It never records a request or response **body**, only sizes: bodies on this
path carry credentials and ciphertext in the real client.

Routes, all under the two prefixes the transport allows
(``RealtimeTransport.java:26``):

===========================  ==================================================
``GET /health``              the v2 health document, with ``realtime``
``/v2/echo``                 200 ``{"ok":true,...}``, GET or POST
``/v2/sink``                 200, and the path an oversized POST must never
                             reach
``GET /v2/redirect``         302 to ``/v2/echo?op=redirect_followed``, which a
                             client that follows redirects would then request
``GET /v2/huge``             200 with a ``bytes`` (default 3 MiB) body
``GET /v2/sleep``            holds ``seconds`` and then answers 200
``GET /v2/slow``             holds ``seconds``; used to fill the two slots
``GET /v2/events?…``         long poll: holds ``hold`` seconds, or resets the
                             connection once when ``flaky=1``
``/v2/error``                ``status`` with a JSON body of exactly ``bytes``
``POST /v2/flaky``           resets the connection on the first attempt of an
                             ``op``, answers 200 afterwards
``POST /v2/broken``          resets the connection on every attempt
===========================  ==================================================

Nothing here contacts a network: the listener is loopback only.
"""
import argparse
import json
import socket
import ssl
import struct
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

# The health document of a v2 server with the long-poll extension
# (`docs/protocol/realtime-v1.md:159-161`).
HEALTH = {'status': 'ok', 'protocol': 'paranoid-self-service-v2',
          'realtime': 'signed-long-poll-v1'}
# How long one connection may stay idle before this server closes it
# (`docs/protocol/realtime-v1.md:150-151`).
IDLE_TIMEOUT = 8.0
# Reading the rest of one request, once its first line has arrived.
REQUEST_TIMEOUT = 8.0
# Refuse to buffer more than this from one request body; the transport's own
# ceiling is 65536 bytes (`RealtimeTransport.java:41`).
BODY_CEILING = 4 * 1024 * 1024
STATUS_TEXT = {200: 'OK', 302: 'Found', 400: 'Bad Request', 404: 'Not Found',
               405: 'Method Not Allowed', 413: 'Payload Too Large',
               429: 'Too Many Requests', 500: 'Internal Server Error'}


class Reset(Exception):
    """Raised by a route that wants the connection reset, not answered."""


class Record:
    """Everything the run observed, safe to put into evidence.

    No request or response body is kept here — only counts, sizes and the
    shape of the headers.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.requests = []
        self.connections = []
        self.attempts = {}
        self.in_flight = 0
        self.max_in_flight = 0
        self.in_flight_by_path = {}
        self.max_in_flight_by_path = {}
        self.idle_closes = 0
        self.client_closes = 0
        self.resets = 0
        self.aborted_writes = 0

    # -- requests

    def started(self, entry):
        with self.lock:
            self.requests.append(entry)
            self.in_flight += 1
            self.max_in_flight = max(self.max_in_flight, self.in_flight)
            path = entry['path']
            here = self.in_flight_by_path.get(path, 0) + 1
            self.in_flight_by_path[path] = here
            self.max_in_flight_by_path[path] = max(self.max_in_flight_by_path.get(path, 0), here)
            if entry['op']:
                self.attempts[entry['op']] = self.attempts.get(entry['op'], 0) + 1
                entry['attempt'] = self.attempts[entry['op']]

    def finished(self, entry, outcome):
        with self.lock:
            if entry['outcome'] != 'started':
                return
            self.in_flight -= 1
            self.in_flight_by_path[entry['path']] = self.in_flight_by_path.get(entry['path'], 1) - 1
            entry['outcome'] = outcome
            entry['finished'] = round(time.monotonic() - entry['at'], 3)

    # -- connections

    def connection(self, number):
        state = {'connection': number, 'requests': 0, 'closed_by': 'open'}
        with self.lock:
            self.connections.append(state)
        return state

    def closed(self, state, reason):
        with self.lock:
            state['closed_by'] = reason
            if reason == 'idle':
                self.idle_closes += 1
            elif reason == 'client':
                self.client_closes += 1
            elif reason == 'reset':
                self.resets += 1

    def write_aborted(self):
        with self.lock:
            self.aborted_writes += 1

    # -- reading

    def count(self, path=None, op=None):
        """Requests that reached a route, by path or by operation."""
        with self.lock:
            return sum(1 for entry in self.requests
                       if (path is None or entry['path'] == path)
                       and (op is None or entry['op'] == op))

    def concurrency(self, path):
        """The most requests this route ever had in flight at once."""
        with self.lock:
            return self.max_in_flight_by_path.get(path, 0)

    def bytes_received(self, path):
        with self.lock:
            return sum(entry['body_bytes'] for entry in self.requests
                       if entry['path'] == path)

    def snapshot(self):
        with self.lock:
            return {
                'requests': [dict(entry) for entry in self.requests],
                'connections': [dict(state) for state in self.connections],
                'max_in_flight': self.max_in_flight,
                'max_in_flight_by_path': dict(self.max_in_flight_by_path),
                'idle_closes': self.idle_closes,
                'client_closes': self.client_closes,
                'resets': self.resets,
                'aborted_writes': self.aborted_writes,
            }


class FakeServer:
    """The listener, its TLS context and one thread per connection."""

    def __init__(self, certificate, key, host='127.0.0.1', port=0,
                 idle_timeout=IDLE_TIMEOUT):
        self.host = host
        self.idle_timeout = idle_timeout
        self.record = Record()
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(str(certificate), str(key))
        # No HTTP/2 here: the transport is an HTTP/1.1 client and every socket
        # rule below is written for one request at a time on one connection.
        self.context.set_alpn_protocols(['http/1.1'])
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind((host, port))
        self.listener.listen(16)
        self.port = self.listener.getsockname()[1]
        self.running = False
        self.connections = 0
        self.threads = []
        self.acceptor = None

    @property
    def url(self):
        return f'https://{self.host}:{self.port}'

    def start(self):
        self.running = True
        self.acceptor = threading.Thread(target=self._accept, daemon=True)
        self.acceptor.start()
        return self

    def stop(self):
        self.running = False
        try:
            self.listener.close()
        except OSError:
            pass
        for thread in list(self.threads):
            thread.join(timeout=5)

    # ------------------------------------------------------------ sockets

    def _accept(self):
        while self.running:
            try:
                raw, _ = self.listener.accept()
            except OSError:
                return
            self.connections += 1
            thread = threading.Thread(target=self._serve, args=(raw, self.connections),
                                      daemon=True)
            self.threads.append(thread)
            thread.start()

    @staticmethod
    def _reset(sock):
        """Close with ``SO_LINGER 0``: a TCP reset, no TLS ``close_notify``."""
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                            struct.pack('ii', 1, 0))
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass

    def _serve(self, raw, number):
        state = self.record.connection(number)
        reason = 'error'
        try:
            raw.settimeout(self.idle_timeout)
            try:
                sock = self.context.wrap_socket(raw, server_side=True)
            except (ssl.SSLError, OSError, socket.timeout):
                # A refused pin never gets past here; that is the point.
                self.record.closed(state, 'handshake')
                self._reset(raw)
                return
            try:
                reason = self._converse(sock, state)
            finally:
                if reason == 'reset':
                    self._reset(sock)
                else:
                    try:
                        sock.close()
                    except OSError:
                        pass
        finally:
            if state['closed_by'] == 'open':
                self.record.closed(state, reason)

    def _converse(self, sock, state):
        """Requests on one connection until it is closed, by either side."""
        while self.running:
            sock.settimeout(self.idle_timeout)
            try:
                head = self._read_head(sock)
            except socket.timeout:
                # The rule this fake exists for: an idle socket is closed.
                return 'idle'
            except (ssl.SSLError, OSError):
                return 'lost'
            if head is None:
                return 'client'
            if not head:
                return 'lost'
            sock.settimeout(REQUEST_TIMEOUT)
            try:
                entry = self._read_request(sock, head)
            except (ssl.SSLError, OSError, socket.timeout):
                return 'lost'
            state['requests'] += 1
            entry['connection'] = state['connection']
            try:
                keep_alive = self._dispatch(sock, entry)
            except Reset:
                self.record.finished(entry, 'reset')
                return 'reset'
            except (ssl.SSLError, OSError, socket.timeout):
                return 'lost'
            if not keep_alive:
                return 'served'
        return 'stopped'

    @staticmethod
    def _read_head(sock):
        """The request line and headers, or ``None`` when the client closed."""
        buffer = b''
        while b'\r\n\r\n' not in buffer:
            chunk = sock.recv(4096)
            if not chunk:
                return None if not buffer else b''
            buffer += chunk
            if len(buffer) > 64 * 1024:
                raise OSError('header block too large')
        return buffer

    def _read_request(self, sock, head):
        """Parses one request and reads its body; records what arrived."""
        block, _, rest = head.partition(b'\r\n\r\n')
        lines = block.decode('latin-1').split('\r\n')
        method, _, target = lines[0].partition(' ')
        target = target.rsplit(' ', 1)[0]
        headers = []
        for line in lines[1:]:
            name, _, value = line.partition(':')
            headers.append((name.strip().lower(), value.strip()))
        length = 0
        for name, value in headers:
            if name == 'content-length':
                length = int(value or 0)
        if length > BODY_CEILING:
            raise OSError('request body beyond the ceiling')
        body = rest
        while len(body) < length:
            chunk = sock.recv(min(65536, length - len(body)))
            if not chunk:
                break
            body += chunk
        split = urlsplit(target)
        query = parse_qs(split.query)
        entry = {
            'method': method,
            'path': split.path,
            'query': split.query,
            'op': (query.get('op') or [''])[0],
            'attempt': 1,
            'body_bytes': len(body),
            'authorization_headers': sum(1 for name, _ in headers if name == 'authorization'),
            'accept': next((value for name, value in headers if name == 'accept'), ''),
            'content_type': next((value for name, value in headers if name == 'content-type'), ''),
            'header_names': sorted({name for name, _ in headers}),
            'at': time.monotonic(),
            'outcome': 'started',
            'connection': None,
        }
        entry['query_parameters'] = {key: values[0] for key, values in query.items()}
        self.record.started(entry)
        return entry

    # ------------------------------------------------------------- routes

    def _dispatch(self, sock, entry):
        """Answers one request; returns whether the connection stays open."""
        path, query = entry['path'], entry['query_parameters']
        try:
            if path == '/health' and entry['method'] == 'GET':
                return self._json(sock, entry, 200, HEALTH)
            if path in ('/v2/echo', '/v2/sink'):
                return self._json(sock, entry, 200,
                                  {'ok': True, 'bytes': entry['body_bytes'],
                                   'messages': []})
            if path == '/v2/redirect':
                return self._send(sock, entry, 302, b'{"error":"moved"}',
                                  extra=[('Location', '/v2/echo?op=redirect_followed')])
            if path == '/v2/huge':
                size = int(query.get('bytes', 3 * 1024 * 1024))
                return self._send(sock, entry, 200, self._filler(size))
            if path == '/v2/sleep' or path == '/v2/slow':
                self._hold(float(query.get('seconds', 20)))
                return self._json(sock, entry, 200, {'ok': True, 'messages': []})
            if path == '/v2/events':
                if query.get('flaky') == '1' and entry['attempt'] == 1:
                    # The connection dies in the middle of a long poll.
                    self._hold(float(query.get('before_reset', 0.5)))
                    raise Reset()
                self._hold(float(query.get('hold', 0)))
                return self._json(sock, entry, 200, {'messages': [], 'cursor': 0})
            if path == '/v2/error':
                status = int(query.get('status', 429))
                size = int(query.get('bytes', 5000))
                code = query.get('code', 'waiter_busy')
                return self._send(sock, entry, status, self._error_body(code, size))
            if path == '/v2/flaky':
                if entry['attempt'] == 1:
                    self._hold(float(query.get('before_reset', 0.05)))
                    raise Reset()
                return self._json(sock, entry, 200, {'ok': True, 'messages': []})
            if path == '/v2/broken':
                self._hold(float(query.get('before_reset', 0.05)))
                raise Reset()
            return self._send(sock, entry, 404, self._error_body('not_found', 40))
        except OSError:
            # The socket died while the route was answering; the connection
            # thread ends and the caller reports it as lost.
            self.record.finished(entry, 'lost')
            raise

    @staticmethod
    def _hold(seconds):
        if seconds > 0:
            time.sleep(seconds)

    @staticmethod
    def _filler(size):
        """A JSON object of exactly ``size`` bytes, with no meaning in it."""
        head, tail = b'{"filler":"', b'"}'
        pad = max(0, size - len(head) - len(tail))
        return head + b'a' * pad + tail

    @staticmethod
    def _error_body(code, size):
        """``{"error":"<code>", …}`` padded to exactly ``size`` bytes."""
        head = f'{{"error":"{code}","filler":"'.encode()
        tail = b'"}'
        pad = size - len(head) - len(tail)
        if pad < 0:
            return f'{{"error":"{code}"}}'.encode()
        return head + b'a' * pad + tail

    def _json(self, sock, entry, status, document):
        return self._send(sock, entry, status,
                          json.dumps(document, sort_keys=True).encode())

    def _send(self, sock, entry, status, body, extra=()):
        head = [f'HTTP/1.1 {status} {STATUS_TEXT.get(status, "Unknown")}',
                'Content-Type: application/json',
                f'Content-Length: {len(body)}',
                'Connection: keep-alive']
        head.extend(f'{name}: {value}' for name, value in extra)
        blob = ('\r\n'.join(head) + '\r\n\r\n').encode() + body
        try:
            view = memoryview(blob)
            while view:
                sent = sock.send(view[:65536])
                view = view[sent:]
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError):
            # The client stopped reading: an oversized body was abandoned.
            self.record.write_aborted()
            self.record.finished(entry, f'{status} aborted')
            return False
        self.record.finished(entry, str(status))
        return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--certificate', required=True)
    parser.add_argument('--key', required=True)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--idle-timeout', type=float, default=IDLE_TIMEOUT)
    args = parser.parse_args(argv)
    server = FakeServer(args.certificate, args.key, host=args.host, port=args.port,
                        idle_timeout=args.idle_timeout).start()
    print(server.url, flush=True)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()
        print(json.dumps(server.record.snapshot(), indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
