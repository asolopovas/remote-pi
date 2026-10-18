"""Fail-closed composition checks; runnable without Flutter/native SDKs."""

import pathlib
import plistlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReleaseUpdaterConfigurationTest(unittest.TestCase):
    def test_all_build_modes_bind_only_the_inert_updater(self):
        source = (ROOT / "lib/app/cockpit/cockpit_module.dart").read_text()
        self.assertIn(
            "..addInstance<SelfUpdater>(const NoopSelfUpdater())", source
        )
        self.assertNotIn("AutoUpdaterSelfUpdater", source)
        self.assertNotIn("kReleaseMode", source)

    def test_no_default_or_feed_only_native_opt_in(self):
        # Native verification keys cannot currently be configured through Dart.
        # Even an explicit feed must not enable the native engine via this root.
        source = (ROOT / "lib/app/cockpit/cockpit_module.dart").read_text()
        self.assertNotIn("selfUpdateFeedUrl:", source)
        self.assertNotIn("setFeedURL", source)
        self.assertNotIn("appcast-", source)
        self.assertNotIn("_kDownloadsBase", source)

    def test_manual_checker_has_no_default_feed(self):
        source = (ROOT / "lib/app/cockpit/data/update/update_checker_impl.dart").read_text()
        self.assertIn("final String? manifestUrl;", source)
        self.assertIn("this.manifestUrl,", source)
        self.assertNotIn("defaultManifestUrl", source)
        self.assertNotIn("jacobmoura", source)
        self.assertNotIn("https://", source)

    def test_manual_checker_rejects_unconfigured_feeds_before_network(self):
        source = (ROOT / "lib/app/cockpit/data/update/update_checker_impl.dart").read_text()
        client = source.index("final client = HttpClient()")
        self.assertLess(source.index("if (url == null || url.isEmpty) return null;"), client)
        for guard in (
            "uri.scheme != 'https'",
            "uri.host.isEmpty",
            "uri.userInfo.isNotEmpty",
            "uri.hasFragment",
        ):
            self.assertLess(source.index(guard), client)
        self.assertIn("request.followRedirects = false;", source)

    def test_root_does_not_opt_in_to_manual_updates(self):
        source = (ROOT / "lib/app/cockpit/cockpit_module.dart").read_text()
        self.assertIn("..addInstance<UpdateChecker>(const UpdateCheckerImpl())", source)
        self.assertNotIn("manifestUrl:", source)
        self.assertNotIn("https://", source)

    def test_macos_has_no_inherited_feed_or_signing_authority(self):
        with (ROOT / "macos/Runner/Info.plist").open("rb") as stream:
            plist = plistlib.load(stream)
        self.assertNotIn("SUFeedURL", plist)
        self.assertNotIn("SUPublicEDKey", plist)
        self.assertNotIn("SUPublicDSAKey", plist)
        self.assertNotIn("SUDisableSignatureVerification", plist)

    def test_macos_automatic_updates_are_disabled(self):
        with (ROOT / "macos/Runner/Info.plist").open("rb") as stream:
            plist = plistlib.load(stream)
        self.assertIs(plist["SUEnableAutomaticChecks"], False)
        self.assertIs(plist["SUAutomaticallyUpdate"], False)

    def test_copyright_still_uses_original_native_configuration(self):
        with (ROOT / "macos/Runner/Info.plist").open("rb") as stream:
            plist = plistlib.load(stream)
        self.assertEqual(plist["NSHumanReadableCopyright"], "$(PRODUCT_COPYRIGHT)")


if __name__ == "__main__":
    unittest.main()
