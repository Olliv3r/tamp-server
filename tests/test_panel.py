"""Painel real renderizado por PHP CLI; executar: python3 tests/test_panel.py."""
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

PANEL = pathlib.Path(__file__).resolve().parents[1] / 'web/index.php'

@unittest.skipUnless(shutil.which('php'), 'PHP CLI indisponível')
class PanelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def render(self, root=None):
        # Caminhos passados por argv, sem interpolação em código PHP.
        code = "$_SERVER['DOCUMENT_ROOT']=$argv[1]; require $argv[2];"
        result = subprocess.run(['php', '-d', 'display_errors=stderr', '-r', code,
                                 str(root or self.root), str(PANEL)],
                                capture_output=True, text=True, check=True)
        self.assertEqual(result.stderr, '')
        return result.stdout

    def test_natural_order_and_index_detection(self):
        for name in ['site10', 'site2']:
            (self.root/name).mkdir()
        (self.root/'site2/index.php').write_text('<?php echo "MUST_NOT_RUN";')
        output = self.render()
        self.assertLess(output.index('>site2</a>'), output.index('>site10</a>'))
        self.assertIn('Possui index.php ou index.html', output)
        self.assertIn('Sem índice padrão:', output)
        self.assertNotIn('MUST_NOT_RUN', output)

    def test_escaping_and_encoded_links(self):
        (self.root/'ação & "teste" <b>').mkdir()
        output = self.render()
        self.assertIn('ação &amp; &quot;teste&quot; &lt;b&gt;', output)
        self.assertIn('/a%C3%A7%C3%A3o%20%26%20%22teste%22%20%3Cb%3E/', output)

    def test_hidden_reserved_files_and_symlinks_excluded(self):
        for name in ['.segredo', 'tamp', 'phpmyadmin', 'valido']:
            (self.root/name).mkdir()
        (self.root/'senha.env').write_text('segredo')
        (self.root/'atalho').symlink_to(self.root/'valido', target_is_directory=True)
        output = self.render()
        self.assertIn('1 pasta(s) de projeto', output)
        for name in ['.segredo', 'senha.env', 'atalho']:
            self.assertNotIn(name, output)

    def test_empty_and_missing_directory_messages(self):
        self.assertIn('Nenhuma pasta de projeto', self.render())
        self.assertIn('Não foi possível ler', self.render(self.root/'missing'))

    def test_active_root_and_refresh(self):
        (self.root/'primeiro').mkdir()
        self.assertIn('>primeiro</a>', self.render())
        other = self.root/'outra-raiz'
        other.mkdir()
        (other/'segundo').mkdir()
        self.assertIn('>segundo</a>', self.render(other))
        self.assertNotIn('>primeiro</a>', self.render(other))
        (other/'terceiro').mkdir()
        self.assertIn('>terceiro</a>', self.render(other))

    def test_linked_index_not_reported_as_usable(self):
        project = self.root/'site'
        project.mkdir()
        (self.root/'file.php').write_text('<?php')
        (project/'index.php').symlink_to(self.root/'file.php')
        self.assertIn('Sem índice padrão:', self.render())

if __name__ == '__main__':
    unittest.main()
