"""Check the installed wrapper and integration toggle at the actual pane boundary."""
import shlex
from pathlib import Path

import test_ghostty_integration as integration


class AntigravityPaneTests(integration.GhosttyTestCase):
    config_extra = ('claude-code-hooks = false\ncodex-hooks = false\npi-hooks = false\n'
                    'opencode-hooks = false\nantigravity-hooks = false\nomp-hooks = false\n')

    def test_disabled_integration_reaches_new_pane_with_all_hooks_disabled(self):
        self.wait(lambda: self.call('surface.read_screen').get('text'), 'shell startup')
        output = self.root / 'agy-env'
        self.call('surface.send_text', {'text':
            '{ printf "%s\\n" "$SEANCE_ANTIGRAVITY_HOOKS_DISABLED" "$SEANCE_OMP_HOOKS_DISABLED"; command -v agy; } > ' +
            shlex.quote(str(output)) + '\n'})
        self.wait(lambda: output.exists() and len(output.read_text().splitlines()) == 3, 'Antigravity pane environment')
        self.assertEqual(output.read_text().splitlines(), [
            '1', '1', str(Path(self.binary).parent.parent / 'share/seance/bin/agy')])


class OmpInheritedGuardPaneTests(integration.GhosttyTestCase):
    # A Séance started from inside a tracked omp inherits the wrapper's
    # nested-session guard; the pane must reset it when the integration is on.
    env_extra = {'SEANCE_OMP_HOOKS_DISABLED': '1'}

    def test_enabled_integration_overrides_an_inherited_guard(self):
        self.wait(lambda: self.call('surface.read_screen').get('text'), 'shell startup')
        output = self.root / 'omp-env'
        self.call('surface.send_text', {'text':
            'printf "%s\\n" "$SEANCE_OMP_HOOKS_DISABLED" > ' + shlex.quote(str(output)) + '\n'})
        self.wait(lambda: output.exists() and output.read_text().strip(), 'omp pane environment')
        self.assertEqual(output.read_text().strip(), '0')
