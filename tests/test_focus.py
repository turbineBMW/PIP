"""Focused regression checks for PiP focus prevention behavior."""

from pathlib import Path
import unittest


PLUGIN = Path(__file__).resolve().parents[1]
QML = (PLUGIN / "Pip.qml").read_text()


class FocusBehaviorTests(unittest.TestCase):
    def test_prevent_focus_setting_exists_and_defaults_true(self):
        self.assertIn("property bool preventFocus: true", QML)
        self.assertIn('root.setting("preventFocus", true) === true', QML)
        self.assertIn("onPreventFocusChanged: if (preventFocus) registerWindowRules()", QML)

    def test_window_rules_register_no_initial_focus_and_focus_on_activate(self):
        self.assertIn("function registerWindowRules() {", QML)
        self.assertIn("no_initial_focus = true, focus_on_activate = false", QML)
        self.assertIn("o.window({ tag = 'pip' }", QML)
        self.assertIn("o.window({ title = '(Picture.?in.?[Pp]icture)' }", QML)

    def test_active_window_is_tracked(self):
        self.assertIn("property string lastFocusedAddress: \"\"", QML)
        self.assertIn('if (n === "activewindowv2")', QML)
        self.assertIn("root.lastFocusedAddress = addr", QML)

    def test_rules_reregistered_on_config_reload_and_completed(self):
        self.assertIn('else if (n === "configreloaded") {', QML)
        self.assertIn("root.registerWindowRules()", QML)
        self.assertIn("Component.onCompleted: {", QML)
        self.assertIn("registerWindowRules()", QML)

    def test_focus_restoration_logic_in_client_adoption(self):
        self.assertIn("if (root.preventFocus && pip.focusHistoryID === 0)", QML)
        self.assertIn("Hyprland.dispatch(\"hl.dsp.focus({ window = 'address:\" + prevAddress + \"' })\")", QML)

    def test_ipc_handler_exposes_toggle(self):
        self.assertIn("function preventFocusToggle(): string", QML)


if __name__ == "__main__":
    unittest.main()
