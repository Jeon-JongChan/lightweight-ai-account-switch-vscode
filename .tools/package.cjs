const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

/** 모든 에이전트를 포함하는 통합 확장 하나만 빌드하고 패키징한다. */
function packageExtension() {
  const root = path.resolve(__dirname, '..');
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  fs.mkdirSync(path.join(root, 'dist'), { recursive: true });
  const target = path.join(root, 'dist', manifest.name + '-' + manifest.version + '.vsix');
  const vsce = require.resolve('@vscode/vsce/vsce', { paths: [path.join(root, '.tools/.build')] });
  execFileSync(process.execPath, [vsce, 'package', '--no-dependencies',
    '--allow-missing-repository', '--no-rewrite-relative-links', '--out', target], { cwd: root, stdio: 'inherit' });
}

packageExtension();
