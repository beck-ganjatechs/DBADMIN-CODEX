from pathlib import Path
import subprocess

from textual.app import App, ComposeResult
from textual.widgets import Header, Footer, Button, Static
from textual.containers import Vertical

SCRIPT_PATH = Path(__file__).parent / "dbdeenkus.sh"

class RecoveryApp(App):
    MENU = [
        ("Check cluster status", "1"),
        ("Check database connectivity", "2"),
        ("Check PostgreSQL cluster status", "3"),
        ("Check repmgr status", "4"),
        ("Check machine resources", "5"),
        ("Check DNS resolution", "6"),
        ("Create backup", "7"),
        ("Restart failed machines only", "8"),
        ("Force restart ALL machines", "9"),
        ("Attempt PostgreSQL recovery", "10"),
        ("Promote standby to primary", "11"),
        ("Scale restart", "12"),
        ("Check error logs", "13"),
        ("Full diagnostic report", "14"),
        ("Auto recovery", "15"),
    ]

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("Fly.io PostgreSQL Recovery", id="title")
        with Vertical(id="menu"):
            for label, _ in self.MENU:
                yield Button(label, id=label)
        yield Button("Exit", id="exit")
        yield Footer()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        label = event.button.id
        if label == "exit":
            self.exit()
            return
        # Find the corresponding choice number
        for text, num in self.MENU:
            if text == label:
                choice = num
                break
        else:
            return
        # Run the shell script with the choice and exit command
        subprocess.run(["bash", str(SCRIPT_PATH)], input=f"{choice}\n0\n", text=True)

if __name__ == "__main__":
    RecoveryApp().run()
