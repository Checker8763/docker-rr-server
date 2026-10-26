#!/usr/bin/env python3
"""Tests for webui_init.py against a fake manager. Run: python3 -m unittest discover -s scripts -p 'test_*.py'"""
import json
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import webui_init  # noqa: E402


class FakeManager(BaseHTTPRequestHandler):
    """Answers like the manager: 403 until registered, then the server list. Records every POST."""
    registered = False
    servers = []
    posts = []  # (path, body)

    def do_GET(self):
        if not self.registered:
            return self.answer(403, {"Message": "Not registered!"})
        self.answer(200, self.servers)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.posts.append((self.path, body))
        if self.path == "/dedi/register":
            FakeManager.registered = True
            return self.answer(200, {"Ip": "203.0.113.1", "Quota": 5})
        self.answer(200, {})

    def answer(self, status, data):
        raw = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *args):
        pass


def server(server_id, running):
    return {"GameSetting": {"Id": server_id, "Name": f"server {server_id}"}, "ProcessState": {"Running": running}}


class WebUiInitTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        manager = ThreadingHTTPServer(("127.0.0.1", 0), FakeManager)
        threading.Thread(target=manager.serve_forever, daemon=True).start()
        cls.manager_url = f"http://127.0.0.1:{manager.server_port}"

    def setUp(self):
        FakeManager.registered = True
        FakeManager.servers = [server(1, running=False), server(2, running=True)]
        FakeManager.posts = []
        self.enterContext(mock.patch("webui_init.BASE", self.manager_url))
        self.enterContext(mock.patch("webui_init.TIMEOUT", 1))  # seconds until it gives up
        self.enterContext(mock.patch("webui_init.PHRASE", ""))
        self.enterContext(mock.patch("webui_init.AUTOSTART", False))
        self.enterContext(mock.patch("webui_init.log"))
        self.enterContext(mock.patch("webui_init.time.sleep"))

    def test_autostart_starts_only_stopped_servers(self):
        with mock.patch("webui_init.AUTOSTART", True):
            self.assertEqual(webui_init.main(), 0)
        self.assertEqual(FakeManager.posts, [("/dedi/start", {"ProcessId": 1})])

    def test_without_autostart_nothing_is_started(self):
        self.assertEqual(webui_init.main(), 0)
        self.assertEqual(FakeManager.posts, [])

    def test_registers_once_with_the_phrase(self):
        FakeManager.registered = False
        with mock.patch("webui_init.PHRASE", "my phrase"):
            self.assertEqual(webui_init.main(), 0)
        self.assertEqual(FakeManager.posts, [("/dedi/register", {"Secret": "my phrase"})])

    def test_gives_up_when_not_registered_and_no_phrase(self):
        FakeManager.registered = False
        self.assertEqual(webui_init.main(), 1)
        self.assertEqual(FakeManager.posts, [])

    def test_gives_up_when_the_manager_does_not_answer(self):
        with mock.patch("webui_init.BASE", "http://127.0.0.1:9"):  # nothing listens there
            self.assertEqual(webui_init.main(), 1)


if __name__ == "__main__":
    unittest.main()
