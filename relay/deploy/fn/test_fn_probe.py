"""Offline security/status regressions for the non-disruptive HTTP/JSON helpers."""
import asyncio
import io
import ssl
import unittest
from http.client import HTTPMessage
from unittest.mock import AsyncMock, Mock, patch
from urllib.error import HTTPError
from urllib.request import Request

import verify


class FnProbeTest(unittest.TestCase):
    def test_tls_requires_public_trust_ip_verification_and_tls13(self):
        self.assertEqual(verify.TLS.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(verify.TLS.check_hostname)
        self.assertEqual(verify.TLS.minimum_version, ssl.TLSVersion.TLSv1_3)
        self.assertEqual(verify.TLS.maximum_version, ssl.TLSVersion.TLSv1_3)
        self.assertIsNone(verify.NoRedirect().redirect_request(
            Mock(spec=Request), io.BytesIO(), 302, "", HTTPMessage(), "http://untrusted.invalid/",
        ))

    def test_http_preserves_error_and_conditional_status_without_redirects(self):
        for status in (403, 409, 304, 302):
            with self.subTest(status=status):
                error = HTTPError("https://173.208.50.216/mesh/test", status, "", HTTPMessage(), io.BytesIO(b"test"))
                with patch.object(verify.HTTP, "open", side_effect=error) as request:
                    self.assertEqual(verify.http("/mesh/test"), (status, b"test"))
                    request.assert_called_once_with(
                        "https://173.208.50.216/mesh/test", data=None, timeout=15,
                    )

    def test_http_rejects_nonlocal_paths(self):
        with patch.object(verify.HTTP, "open") as request:
            for path in ("http://other.invalid", "//other.invalid"):
                with self.assertRaises(ValueError):
                    verify.http(path)
            request.assert_not_called()

    def test_invalid_json_has_context_but_never_payload_in_exception(self):
        ws = AsyncMock()
        ws.recv.return_value = "PRIVATE_SENTINEL not JSON"
        with self.assertRaisesRegex(RuntimeError, "Invalid JSON in relay WebSocket frame") as error:
            asyncio.run(verify.receive(ws))
        self.assertNotIn("PRIVATE_SENTINEL", str(error.exception))
        self.assertIsNone(error.exception.__cause__)
        self.assertTrue(error.exception.__suppress_context__)

    def test_nonobject_json_is_rejected_and_valid_object_is_accepted(self):
        with self.assertRaisesRegex(RuntimeError, "Expected a JSON object"):
            verify.decode_json_object("[]", "relay WebSocket frame")
        self.assertEqual(verify.decode_json_object('{"type":"presence"}', "relay WebSocket frame"), {"type": "presence"})


if __name__ == "__main__":
    unittest.main()
