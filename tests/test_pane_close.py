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


class WindowCloseTests(keyboard.PhysicalKeyboardTestCase):
    env_extra = {"G_DEBUG": "fatal-criticals"}

    def ready_surfaces(self):
        surfaces = self.app.call("surface.list")["surfaces"]
        for surface in surfaces:
            params = {"surface_id": surface["id"]}
            self.app.wait(lambda: self.app.call("surface.read_screen", params).get("text"),
                          "shell startup before switching workspaces")
        return surfaces

    def start_workspaces_output(self, lines=400000):
        self.run_x("xdotool", "key", "ctrl+shift+t")
        self.app.wait(lambda: len(self.app.call("surface.list")["surfaces"]) == 2,
                      "second pane")
        self.ready_surfaces()
        self.run_x("xdotool", "key", "ctrl+shift+Return")
        self.app.wait(lambda: len(self.app.call("surface.list")["surfaces"]) == 3,
                      "second column")
        self.ready_surfaces()
        self.app.call("surface.split")
        self.ready_surfaces()
        self.app.call("workspace.create")
        self.ready_surfaces()
        self.app.call("surface.split")
        for surface in self.ready_surfaces():
            self.app.call("surface.send_text", {
                "surface_id": surface["id"], "text": f"seq 1 {lines}\n",
            })
        time.sleep(0.4)

    def assert_no_gtk_criticals(self):
        self.app.log.seek(0)
        self.assertNotIn("CRITICAL", self.app.log.read())

    def test_close_last_window_with_output_in_flight(self):
        self.start_workspaces_output()
        # The last window can exit before the socket reply is delivered.
        try:
            self.app.call("window.close", {"window_id": 0})
        except (OSError, ValueError, AssertionError):
            pass
        self.app.process.wait(timeout=10)
        self.assertEqual(self.app.process.returncode, 0)
        self.assert_no_gtk_criticals()

    def test_close_window_with_scrollback_keeps_other_window_usable(self):
        self.app.call("window.create")
        windows = self.run_x("xdotool", "search", "--onlyvisible", "--pid",
                             str(self.app.process.pid)).strip().splitlines()
        self.run_x("xdotool", "windowfocus", "--sync", windows[-1])
        self.app.wait(lambda: self.app.call("window.current")["index"] == 1,
                      "second window focused")
        self.ready_surfaces()
        self.start_workspaces_output(lines=200)
        self.app.call("window.close", {"window_id": 1})
        self.app.wait(lambda: len(self.app.call("window.list")["windows"]) == 1,
                      "second window closes")
        self.app.print_marker("SURVIVING_WINDOW")
        self.app.stop()
        self.assertEqual(self.app.process.returncode, 0)
        self.assert_no_gtk_criticals()
