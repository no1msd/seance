"""Pane teardown regressions with physical input on isolated X servers."""
import time

import test_keyboard_remaps as keyboard


class PaneCloseTests(keyboard.PhysicalKeyboardTestCase):
    def expect_terminal_input(self):
        # Sending through the socket would bypass GTK focus and controllers.
        self.capture()
        self.run_x("xdotool", "key", "a", "b")
        self.app.wait(lambda: self.received() == b"ab", "keyboard input after closing a pane")
        self.app.stop()
        self.assertEqual(self.app.process.returncode, 0)
        self.app.log.seek(0)
        self.assertNotIn("CRITICAL", self.app.log.read())

    def close_last_pane(self, shortcut="ctrl+shift+w"):
        workspace = self.app.call("workspace.current")["id"]
        self.run_x("xdotool", "key", shortcut)
        self.app.wait(lambda: self.app.call("workspace.current")["id"] != workspace,
                      "replacement workspace after closing the last pane")
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "replacement shell startup")
        self.expect_terminal_input()

    def test_close_last_tab_in_stacked_column(self):
        self.run_x("xdotool", "key", "ctrl+shift+t")
        self.app.wait(lambda: len(self.app.call("surface.list")["surfaces"]) == 2,
                      "two stacked panes")
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "second shell startup")
        self.run_x("xdotool", "key", "ctrl+shift+w")
        self.app.wait(lambda: len(self.app.call("surface.list")["surfaces"]) == 1,
                      "first stacked pane closed")
        self.close_last_pane()

    def test_close_last_tab_in_tabbed_column(self):
        self.run_x("xdotool", "key", "ctrl+shift+l")
        # Panels enter AdwTabView only after the layout animation completes.
        time.sleep(1)
        self.close_last_pane()

    def test_close_last_pane_with_pane_shortcut(self):
        self.close_last_pane("ctrl+shift+x")

    def test_shell_exit_from_last_pane(self):
        workspace = self.app.call("workspace.current")["id"]
        self.app.call("surface.send_text", {"text": "exit\n"})
        self.app.wait(lambda: self.app.call("workspace.current")["id"] != workspace,
                      "replacement workspace after shell exit")
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "replacement shell startup")
        self.expect_terminal_input()

    def test_close_last_tab_with_another_workspace_remaining(self):
        remaining = self.app.call("workspace.current")["id"]
        self.app.call("workspace.create")
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"),
                      "second workspace startup")
        self.run_x("xdotool", "key", "ctrl+shift+w")
        self.app.wait(lambda: self.app.call("workspace.current")["id"] == remaining,
                      "focus returns to the remaining workspace")
        self.expect_terminal_input()
