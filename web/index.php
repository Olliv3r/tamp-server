<?php
declare(strict_types=1);

header('Content-Type: text/html; charset=UTF-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");

function html(string $value): string {
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

// O Apache define a raiz ativa; não aceitar caminhos enviados pela requisição.
$root = $_SERVER['DOCUMENT_ROOT'] ?? '';
$entries = $root !== '' && is_dir($root) ? @scandir($root) : false;
$projects = [];
if ($entries !== false) {
    foreach ($entries as $name) {
        if ($name === '' || $name[0] === '.' ||
            in_array(strtolower($name), ['tamp', 'phpmyadmin'], true)) {
            continue;
        }
        $path = rtrim($root, '/') . '/' . $name;
        // Não seguir links simbólicos nem executar código para identificar projetos.
        if (is_link($path) || !is_dir($path)) {
            continue;
        }
        $hasIndex = false;
        foreach (['index.php', 'index.html'] as $index) {
            if (!is_link("$path/$index") && is_file("$path/$index") &&
                is_readable("$path/$index")) {
                $hasIndex = true;
                break;
            }
        }
        $projects[] = ['name' => $name, 'url' => '/' . rawurlencode($name) . '/',
                       'index' => $hasIndex];
    }
    usort($projects, static function (array $a, array $b): int {
        return strnatcasecmp($a['name'], $b['name']);
    });
}
?>
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TAMP — Seus projetos</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}
body{margin:0;background:#101827;color:#eef2ff;font:17px/1.6 system-ui,sans-serif}
main{max-width:960px;margin:auto;padding:32px 20px}
header small{color:#8eb4f5;font-weight:700;letter-spacing:.12em}
h1{font-size:clamp(30px,6vw,44px);line-height:1.2;margin:14px 0}
p{color:#c6d3e7}a{color:#91d6ff}code{overflow-wrap:anywhere}
nav{display:flex;gap:12px;flex-wrap:wrap;margin:24px 0}
nav a{padding:10px 16px;border:1px solid #3c526f;border-radius:9px;text-decoration:none}
nav a:hover,nav a:focus-visible{background:#263a55}
ul{padding:0;list-style:none;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,260px),1fr));gap:16px}
li{background:#1c2a40;border:1px solid #30445e;padding:22px;border-radius:14px}
li a{font-size:23px;font-weight:650;overflow-wrap:anywhere}
li small{display:block;margin-top:12px;color:#b9c9df}
.notice{padding:18px;background:#1c2a40;border-left:3px solid #91d6ff;border-radius:6px}
footer{margin-top:32px;font-size:14px;color:#a4b6d1}
</style>
</head>
<body><main>
<header><small>TAMP · AMBIENTE LOCAL</small><h1>Seus projetos</h1></header>
<p>Pasta ativa: <code><?= html($root) ?></code></p>
<nav aria-label="Ferramentas">
<a href="/tamp/">Atualizar lista</a>
<a href="/phpmyadmin/">phpMyAdmin</a>
<a href="/">Raiz do servidor</a>
</nav>
<?php if ($entries === false): ?>
<p class="notice">Não foi possível ler a pasta de projetos. Confira a pasta ativa
 e a permissão de armazenamento do Termux.</p>
<?php elseif (!$projects): ?>
<p class="notice">Nenhuma pasta de projeto encontrada. Coloque seus projetos na pasta
 ativa indicada acima e atualize esta página.</p>
<?php else: ?>
<p><?= count($projects) ?> pasta(s) de projeto encontrada(s).</p>
<ul aria-label="Projetos">
<?php foreach ($projects as $project): ?>
<li><a href="<?= html($project['url']) ?>"><?= html($project['name']) ?></a>
<small><?= $project['index'] ? 'Possui index.php ou index.html'
 : 'Sem índice padrão: pode exigir uma rota específica ou configuração adicional.' ?></small></li>
<?php endforeach; ?>
</ul>
<?php endif; ?>
<footer>Lista de pastas do primeiro nível, atualizada a cada acesso. Pastas ocultas,
 links simbólicos e nomes reservados do painel não são exibidos.
 Para mudar a pasta: <code>tamp storage private</code> ou
 <code>tamp storage shared</code>; depois <code>tamp restart apache</code>.</footer>
</main></body></html>
