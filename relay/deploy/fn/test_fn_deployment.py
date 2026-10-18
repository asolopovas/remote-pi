"""Security invariants for the checked-in fn deployment (no remote mutations)."""
import pathlib
import unittest

import yaml

DIRECTORY = pathlib.Path(__file__).resolve().parent


class FnDeploymentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compose = yaml.safe_load((DIRECTORY / "compose.yaml").read_text())
        cls.nginx = (DIRECTORY / "nginx.conf").read_text()

    def test_relay_is_unpublished_and_uses_internal_backend(self):
        relay = self.compose["services"]["relay"]
        self.assertNotIn("ports", relay)
        self.assertEqual(relay["networks"], ["backend"])
        self.assertTrue(self.compose["networks"]["backend"]["internal"])
        self.assertEqual(relay["volumes"], ["data:/data"])
        self.assertTrue(self.compose["volumes"]["data"]["external"])
        self.assertEqual(relay["pull_policy"], "never")

    def test_containers_are_nonroot_and_restricted(self):
        for service in self.compose["services"].values():
            self.assertNotEqual(service["user"].split(":")[0], "0")
            self.assertTrue(service["read_only"])
            self.assertEqual(service["cap_drop"], ["ALL"])
            self.assertEqual(service["security_opt"], ["no-new-privileges:true"])
            self.assertIn("mem_limit", service)
            self.assertIn("pids_limit", service)
            self.assertEqual(service["logging"]["options"]["max-file"], "3")
        proxy = self.compose["services"]["proxy"]
        self.assertIn("@sha256:", proxy["image"])
        self.assertEqual(proxy["ports"], [
            "173.208.50.216:80:8080", "173.208.50.216:443:8443",
        ])
        self.assertIn("uid=101,gid=101", proxy["tmpfs"][0])

    def test_http_is_acme_only_and_bootstrap_has_no_relay(self):
        http, tls = self.nginx.split("        listen 8443 ssl;", 1)
        self.assertNotIn("proxy_pass", http)
        self.assertIn("location / { return 404; }", http)
        self.assertIn("acme-challenge/[A-Za-z0-9_-]+$", http)
        bootstrap = (DIRECTORY / "nginx-bootstrap.conf").read_text()
        self.assertNotIn("proxy_pass", bootstrap)
        self.assertNotIn("ssl_certificate", bootstrap)
        self.assertIn("proxy_pass http://relay:3000;", tls)

    def test_tls13_ws_and_membership_compatibility(self):
        self.assertIn("ssl_protocols TLSv1.3;", self.nginx)
        self.assertNotIn("TLSv1.2", self.nginx)
        self.assertIn("proxy_http_version 1.1;", self.nginx)
        self.assertIn("proxy_set_header Upgrade $http_upgrade;", self.nginx)
        self.assertIn("proxy_read_timeout 75s;", self.nginx)
        self.assertIn("client_max_body_size 500k;", self.nginx)
        self.assertIn("access_log off;", self.nginx)

    def test_renewal_never_deploys_staging(self):
        deploy = (DIRECTORY / "deploy-certificate.sh").read_text()
        self.assertIn("cert=acme-production/config/live/173.208.50.216", deploy)
        self.assertNotIn("acme-staging", deploy)
        self.assertIn("./reload-proxy.sh", deploy)
        reload = (DIRECTORY / "reload-proxy.sh").read_text()
        self.assertIn("nginx -t", reload)
        self.assertIn("nginx -s reload", reload)
        renew = (DIRECTORY / "renew.sh").read_text()
        self.assertIn('if [ -f "$marker" ]; then', renew)
        self.assertIn("flock -n 9", renew)
        self.assertIn("172800", (DIRECTORY / "check.sh").read_text())

    def test_upgrade_and_rollback_wait_then_refresh_static_upstream(self):
        upgrade = (DIRECTORY / "upgrade-relay.sh").read_text()
        self.assertLess(upgrade.index("docker compose up"), upgrade.index("./reload-proxy.sh"))
        self.assertLess(upgrade.index("./reload-proxy.sh"), upgrade.index("./check.sh --wait-for-deployment"))
        reload = (DIRECTORY / "reload-proxy.sh").read_text()
        self.assertLess(reload.index("http://127.0.0.1:3000/health"), reload.index("nginx -t"))


if __name__ == "__main__":
    unittest.main()
