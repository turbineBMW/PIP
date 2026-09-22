"""Focused regression checks for automatic subprocess trust boundaries."""

from pathlib import Path
import re
import select
import socket
import subprocess
import tempfile
import threading
import unittest


PLUGIN = Path(__file__).resolve().parents[1]
QML = (PLUGIN / "Pip.qml").read_text()
CURSOR_WATCH = (PLUGIN / "scripts/cursor-watch").read_text()


class ProcessSecurityTests(unittest.TestCase):
    def test_every_process_clears_its_environment(self):
        self.assertEqual(len(re.findall(r"\bProcess\s*\{", QML)), 3)
        self.assertEqual(QML.count("clearEnvironment: true"), 3)
        self.assertEqual(QML.count("environment: root.hyprlandEnvironment()"), 3)
        self.assertEqual(QML.count('workingDirectory: "/"'), 3)
        environment_function = re.search(
            r"function hyprlandEnvironment\(\) \{(?P<body>.*?)\n  \}", QML, re.DOTALL
        ).group("body")
        self.assertEqual(
            set(re.findall(r"Quickshell\.env\(\"([^\"]+)\"\)", environment_function)),
            {"XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE"},
        )
        for forbidden in ("PATH", "LD_PRELOAD", "LD_LIBRARY_PATH", "PYTHONPATH", "PYTHONHOME"):
            self.assertNotIn(forbidden, environment_function)

    def test_automatic_executables_are_absolute(self):
        self.assertEqual(QML.count('"/usr/bin/hyprctl"'), 2)
        self.assertIn('["/usr/bin/python3", "-I", "-S"', QML)
        self.assertNotRegex(QML, r'command:\s*\["hyprctl"')
        self.assertEqual(CURSOR_WATCH.splitlines()[0], "#!/usr/bin/python3")

    def test_hyprctl_output_is_bounded_before_concatenation(self):
        self.assertIn('readonly property int opacityOutputLimit: 4096', QML)
        self.assertIn('readonly property int clientsOutputLimit: 1048576', QML)
        self.assertEqual(QML.count('splitMarker: ""'), 2)
        self.assertNotIn("StdioCollector", QML)
        self.assertIn("chunk.length > limit - target.collected.length", QML)
        self.assertIn("target.signal(9)", QML)

    def test_processes_have_deadlines_and_cleanup(self):
        self.assertIn("id: opacityReadDeadline", QML)
        self.assertIn("id: clientsDeadline", QML)
        self.assertIn("id: cursorWatchKill", QML)
        self.assertIn("opacityRead.signal(9)", QML)
        self.assertIn("clientsProc.signal(9)", QML)
        self.assertIn("cursorWatch.signal(9)", QML)
        self.assertIn("sock.settimeout(1.0)", CURSOR_WATCH)

    def test_cursor_watch_runs_with_only_the_allowlisted_environment(self):
        with tempfile.TemporaryDirectory(prefix="pip-cursor-watch-") as temporary:
            instance = "security-test"
            socket_dir = Path(temporary) / "hypr" / instance
            socket_dir.mkdir(parents=True)
            socket_path = socket_dir / ".socket.sock"
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(socket_path))
            server.listen(1)
            received = []

            def respond():
                connection, _ = server.accept()
                with connection:
                    received.append(connection.recv(64))
                    connection.sendall(b"123, 456")

            thread = threading.Thread(target=respond)
            thread.start()
            environment = {
                "LANG": "C",
                "LC_ALL": "C",
                "XDG_RUNTIME_DIR": temporary,
                "HYPRLAND_INSTANCE_SIGNATURE": instance,
            }
            process = subprocess.Popen(
                ["/usr/bin/python3", "-I", "-S", str(PLUGIN / "scripts/cursor-watch"), "5"],
                env=environment,
                stdout=subprocess.PIPE,
                text=True,
            )
            try:
                readable, _, _ = select.select([process.stdout], [], [], 2)
                self.assertTrue(readable, "cursor watcher did not produce output before its deadline")
                self.assertEqual(process.stdout.readline(), "123 456\n")
            finally:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1)
                process.stdout.close()
                thread.join(timeout=1)
                server.close()
            self.assertEqual(received, [b"cursorpos"])


if __name__ == "__main__":
    unittest.main()
