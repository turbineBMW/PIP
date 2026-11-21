"""Focused regression checks for PiP focus prevention behavior."""

from pathlib import Path
import re
import unittest


PLUGIN = Path(__file__).resolve().parents[1]
QML = (PLUGIN / "Pip.qml").read_text()


def function_body(name):
    match = re.search(r"\n  function " + name + r"\([^)]*\) \{(?P<body>.*?)\n  \}", QML, re.DOTALL)
    assert match, name + " not found"
    return match.group("body")


class FocusBehaviorTests(unittest.TestCase):
    def test_prevent_focus_setting_defaults_true(self):
        self.assertIn("property bool preventFocus: true", QML)
        self.assertIn('root.setting("preventFocus", true) === true', QML)

    def test_window_rules_are_named_and_follow_the_setting(self):
        body = function_body("registerWindowRules")
        # Named rules update in place: no duplicates across reloads, and
        # turning preventFocus off disables them instead of leaving them live.
        self.assertIn("name = 'turbinebmw-pip-focus-tag'", body)
        self.assertIn("name = 'turbinebmw-pip-focus-title'", body)
        self.assertIn('"enabled = " + (preventFocus ? "true" : "false")', body)
        self.assertIn("no_initial_focus = true, focus_on_activate = false", body)
        self.assertNotIn("if (!preventFocus) return", body)
        self.assertEqual(body.count("hl.window_rule({ name = "), 2)
        self.assertIn("onPreventFocusChanged: registerWindowRules()", QML)

    def test_rules_registered_on_startup_and_config_reload(self):
        completed = re.search(r"Component\.onCompleted: \{(?P<body>.*?)\}", QML, re.DOTALL).group("body")
        self.assertIn("registerWindowRules()", completed)
        self.assertRegex(QML, r'n === "configreloaded"\) \{\s*root\.registerWindowRules\(\)')

    def test_event_addresses_are_normalized_to_hyprctl_form(self):
        body = function_body("markFresh")
        self.assertIn('split(",")[0]', body)
        self.assertIn("/^[0-9a-fA-F]+$/.test(hex)", body)
        self.assertIn('freshAddresses["0x" + hex.toLowerCase()]', body)
        self.assertIn('if (n === "openwindow") root.markFresh(event.data)', QML)

    def test_fresh_window_tracking_is_bounded(self):
        self.assertIn("readonly property int freshWindowMs: 2000", QML)
        self.assertIn("delete freshAddresses[address]", function_body("pruneFresh"))
        self.assertTrue(function_body("applyClients").lstrip().startswith("pruneFresh()"))

    def test_focus_is_handed_back_only_for_freshly_opened_pips(self):
        body = function_body("applyClients")
        self.assertIn("if (preventFocus && isFresh(pip.address) && pip.focusHistoryID === 0)", body)
        self.assertIn("a.focusHistoryID - b.focusHistoryID", body)
        self.assertIn("Hyprland.dispatch(\"hl.dsp.focus({ window = 'address:\" + previous.address + \"' })\")", body)
        self.assertNotIn("lastFocusedAddress", QML)
        self.assertNotIn("activewindowv2", QML)

    def test_ipc_handler_exposes_toggle(self):
        self.assertIn("function preventFocusToggle(): string", QML)


if __name__ == "__main__":
    unittest.main()
