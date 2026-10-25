"""Tests for scripts/coa-lab-relay. Run: python3 -m unittest discover -s scripts/tests -p 'test_*.py'"""
import base64
import importlib.machinery
import importlib.util
import json
import re
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from xml.sax.saxutils import escape, unescape

SCRIPT = Path(__file__).resolve().parent.parent / "coa-lab-relay"
loader = importlib.machinery.SourceFileLoader("coa_lab_relay", str(SCRIPT))
spec = importlib.util.spec_from_loader("coa_lab_relay", loader)
relay = importlib.util.module_from_spec(spec)
loader.exec_module(relay)

RESULT = ('<?xml version="1.0" encoding="UTF-8"?><SOAP-ENV:Envelope '
          'xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:AC"><SOAP-ENV:Body>'
          '<ns1:executeCommandResponse><result>{}</result></ns1:executeCommandResponse></SOAP-ENV:Body>'
          '</SOAP-ENV:Envelope>')
FAULT = ('<?xml version="1.0" encoding="UTF-8"?><SOAP-ENV:Envelope '
         'xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/"><SOAP-ENV:Body><SOAP-ENV:Fault>'
         '<faultcode>SOAP-ENV:Client</faultcode><faultstring>{}</faultstring><detail>{}</detail>'
         '</SOAP-ENV:Fault></SOAP-ENV:Body></SOAP-ENV:Envelope>')


class FakeSoap:
    def __init__(self):
        self.commands, self.auth, self.replies = [], [], []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"])).decode()
                outer.commands.append(unescape(re.search(r"<command>(.*)</command>", body).group(1)))
                outer.auth.append(self.headers.get("Authorization"))
                kind, text = outer.replies.pop(0) if outer.replies else ("result", "unknown")
                payload = (RESULT.format(escape(text)) if kind == "result"
                           else FAULT.format(escape(text), escape(text))).encode()
                self.send_response(200 if kind == "result" else 500)
                self.send_header("Content-Type", "text/xml")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class RelayTest(unittest.TestCase):
    def setUp(self):
        self.soap = FakeSoap()
        self.tmp = tempfile.TemporaryDirectory()
        self.password_file = Path(self.tmp.name) / "soap.password"
        self.password_file.write_text("SECRET\n")
        self.descriptor = {
            "instance": "", "slot": 2, "soap_url": self.soap.url, "soap_account": "COALABSOAP",
            "soap_password_file": str(self.password_file), "account": "COALAB1", "character": "Coalabone",
            "deployed_commit": "abc", "preflight": "pass",
        }

    def tearDown(self):
        self.soap.close()
        self.tmp.cleanup()

    def test_send_then_poll_until_complete(self):
        answer = {"req": "x", "result": {"tooltip": [{"left": "Fel Fireball"}]}}
        encoded = base64.b64encode(json.dumps(answer).encode()).decode()
        self.soap.replies = [("result", "sent x"), ("result", "pending 0/0"), ("result", "pending 1/2"),
                             ("result", f"complete {encoded}")]
        result = relay.probe(self.descriptor, "spell 501281", timeout=5, poll=0.01)
        self.assertEqual(result["result"], answer["result"])
        self.assertIsInstance(result["elapsed_ms"], int)
        self.assertEqual(len(self.soap.commands), 4)
        send = self.soap.commands[0]
        self.assertRegex(send, r"^\.labprobe send Coalabone r[0-9a-f]{12} spell 501281$")
        req = send.split()[3]
        self.assertEqual(self.soap.commands[1:], [f".labprobe result Coalabone {req}"] * 3)

    def test_probe_raises_on_soap_fault_without_polling(self):
        self.soap.replies = [("fault", "There is no such command")]
        with self.assertRaisesRegex(relay.SoapFault, "There is no such command"):
            relay.probe(self.descriptor, "ping", timeout=5, poll=0.01)
        self.assertEqual(len(self.soap.commands), 1)

    def test_probe_timeout_names_character_and_status(self):
        self.soap.replies = [("result", "sent x")] + [("result", "pending 1/3")] * 200
        with self.assertRaises(TimeoutError) as caught:
            relay.probe(self.descriptor, "ping", timeout=0.2, poll=0.01)
        message = str(caught.exception)
        self.assertIn("Coalabone", message)
        self.assertRegex(message, r"r[0-9a-f]{12}")
        self.assertIn("pending 1/3", message)

    def test_basic_auth_header_sent(self):
        self.soap.replies = [("result", "Server info")]
        self.assertEqual(relay.soap_execute(self.soap.url, "COALABSOAP", "SECRET", ".server info"), "Server info")
        expected = "Basic " + base64.b64encode(b"COALABSOAP:SECRET").decode()
        self.assertEqual(self.soap.auth, [expected])

    def test_command_text_is_xml_escaped(self):
        self.soap.replies = [("result", "ok")]
        relay.soap_execute(self.soap.url, "A", "B", ".labprobe send X r1 frame <&>")
        self.assertEqual(self.soap.commands, [".labprobe send X r1 frame <&>"])

    def test_descriptor_requires_every_key(self):
        path = Path(self.tmp.name) / "lab.json"
        path.write_text(json.dumps(self.descriptor))
        self.assertEqual(relay.load_descriptor(path)["character"], "Coalabone")
        for key in relay.DESCRIPTOR_KEYS:
            partial = dict(self.descriptor)
            del partial[key]
            path.write_text(json.dumps(partial))
            with self.assertRaisesRegex(ValueError, key):
                relay.load_descriptor(path)


if __name__ == "__main__":
    unittest.main()
