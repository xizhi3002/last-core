# 本地打包工具：收集已导出的程序、报告和截图，生成 ZIP 与校验值。
# 源码打包使用目录遍历；含 .git 或本地私密文件的工作区应改用 git archive 导出已跟踪文件。
"""Build reproducible local deliverables from an already-tested Godot export."""
from pathlib import Path
import hashlib
import json
import shutil
import zipfile

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parent / 'output'
RELEASE = OUT / 'LastCore-Windows-v0.1.0'
RELEASE.mkdir(parents=True, exist_ok=True)
(RELEASE / 'reports').mkdir(exist_ok=True)
(RELEASE / 'screenshots').mkdir(exist_ok=True)
(RELEASE / 'docs').mkdir(exist_ok=True)

results = json.loads((ROOT / 'build/test-results.json').read_text(encoding='utf-8'))
assert not results['failures'] and results['completed'] >= 60
assert (ROOT / 'build/LastCore.exe').stat().st_size > 50_000_000
shutil.copy2(ROOT / 'build/LastCore.exe', RELEASE / 'LastCore.exe')
for name in ['README.md', 'THIRD_PARTY_NOTICES.txt']:
    shutil.copy2(ROOT / name, RELEASE / name)
for file in (ROOT / 'docs').glob('*.md'):
    shutil.copy2(file, RELEASE / 'docs' / file.name)
for name in ['test-results.json', 'balance-results.json', 'ui-test-results.json', 'performance-results.json']:
    shutil.copy2(ROOT / 'build' / name, RELEASE / 'reports' / name)
for name in ['menu.png', 'game.png']:
    shutil.copy2(ROOT / 'build' / name, RELEASE / 'screenshots' / name)
(RELEASE / '开始游戏.txt').write_text(
    '最后核心 · LAST CORE 0.1.0\n\n双击 LastCore.exe 开始。无需安装 Godot。\n'
    '第一局：部署新防线 → 16×16 → 默认蓝图 → 开始出征 → 一键基础布阵 → 启动防线。\n'
    '每15波手动领奖；可把周期奖励切为优先金币/强化以持续挂机。\n'
    '当前为离线开发版。完整操作与范围见 README.md。\n',
    encoding='utf-8-sig')
digest = hashlib.sha256((RELEASE / 'LastCore.exe').read_bytes()).hexdigest()
(RELEASE / 'SHA256.txt').write_text(f'{digest}  LastCore.exe\n', encoding='ascii')
with zipfile.ZipFile(OUT / 'LastCore-Windows-v0.1.0.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for file in sorted(RELEASE.rglob('*')):
        if file.is_file(): archive.write(file, file.relative_to(OUT))
with zipfile.ZipFile(OUT / 'LastCore-Source-v0.1.0.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for file in sorted(ROOT.rglob('*')):
        relative = file.relative_to(ROOT)
        if not file.is_file() or any(p in {'.godot', '__pycache__', 'build'} for p in relative.parts):
            continue
        if file.suffix in {'.tmp', '.bak', '.pyc'}:
            continue
        archive.write(file, Path('last-core') / relative)
    archive.writestr('last-core/build/.gitkeep', '')
    for file in sorted((RELEASE/'reports').glob('*.json')):
        archive.write(file, Path('last-core/docs/reports')/file.name)
print(json.dumps({'exe':str(RELEASE/'LastCore.exe'), 'sha256':digest,
                  'windows_zip_bytes':(OUT/'LastCore-Windows-v0.1.0.zip').stat().st_size,
                  'source_zip_bytes':(OUT/'LastCore-Source-v0.1.0.zip').stat().st_size}, indent=2))
