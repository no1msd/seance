"""Check the installed wrapper and integration toggle at the actual pane boundary."""
import shlex
from pathlib import Path

import test_ghostty_integration as integration


class AntigravityPaneTests(integration.GhosttyTestCase):
    config_extra = ('claude-code-hooks = false\ncodex-hooks = false\npi-hooks = false\n'
                    'opencode-hooks = false\nantigravity-hooks = false\n')

    def test_disabled_integration_reaches_new_pane_with_all_hooks_disabled(self):
        self.wait(lambda: self.call('surface.read_screen').get('text'), 'shell startup')
        output = self.root / 'agy-env'
        self.call('surface.send_text', {'text':
            '{ printf "%s\\n" "$SEANCE_ANTIGRAVITY_HOOKS_DISABLED"; command -v agy; } > ' +
            shlex.quote(str(output)) + '\n'})
        self.wait(lambda: output.exists() and len(output.read_text().splitlines()) == 2, 'Antigravity pane environment')
        self.assertEqual(output.read_text().splitlines(), [
            '1', str(Path(self.binary).parent.parent / 'share/seance/bin/agy')])
