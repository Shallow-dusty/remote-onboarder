#!/usr/bin/env python3
"""Build a portable ZIP (or script-only update) without IExpress/7z.

Packaging is NOT Windows installation acceptance. The WSL wrapper runs Windows
signature/syntax/SelfTest first; direct macOS usage needs that validation separately.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
PINS = {
    'OpenSSH-Win64-v10.0.0.0.msi': 'ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9',
    'tailscale-setup-1.102.3-amd64.msi': '03ac8183c6e3ce276e9b44281ebe7e4c02aef28a971034ca170c4b665df42dce',
}
SCRIPTS = ('launcher.cmd', 'bootstrap.ps1', 'safety.ps1', 'diagnostics.ps1')


def validate_public_key(value):
    keygen = shutil.which('ssh-keygen') or shutil.which('ssh-keygen.exe')
    if not keygen:
        raise ValueError('ssh-keygen is required to validate the controller public key')
    with tempfile.TemporaryDirectory(prefix='onboarder-public-key-') as directory:
        public = Path(directory) / 'controller.pub'
        public.write_text(value + '\n', encoding='utf-8')
        result = subprocess.run([keygen, '-lf', str(public)], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        if result.returncode:
            raise ValueError('OpenSSH rejected the controller public key')


def build(config, payload_dir, output, scripts_only=False):
    if output.exists():
        raise ValueError('refusing to overwrite an existing package')
    # Verify prerequisites even for updates, so their manifest matches the base MSIs.
    for name, digest in PINS.items():
        source = payload_dir / name
        if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != digest:
            raise ValueError('missing or invalid pinned payload: ' + name)
    spec = importlib.util.spec_from_file_location('onboarder_renderer', ROOT / 'scripts/render-setup.py')
    renderer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(renderer)
    rendered = renderer.render((ROOT / 'payload/setup.ps1').read_text(encoding='utf-8-sig'),
                               config, *PINS.values())
    validate_public_key(config['publicKey'])
    files = {name: (ROOT / 'payload' / name).read_bytes() for name in SCRIPTS}
    files['setup.ps1'] = rendered.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8-sig')
    instructions = (
        '迁移协助接入包\r\n\r\n'
        + ('这是脚本更新包：把所有文件复制到原 launcher.cmd 所在文件夹并替换，保留原来的两个 MSI。\r\n' if scripts_only
           else '先右键 ZIP 选择“全部解压”，不要在压缩预览里运行。\r\n')
        + '双击 launcher.cmd，同意管理员权限提示，保持联网和窗口打开。\r\n'
          '程序会自动采集诊断，不需要输入额外排查命令。\r\n'
          '成功后发送桌面 SSH-连接信息.txt；失败时只需发送 SSH-反馈资料.zip，不必输入排查命令。\r\n'
          '安装器正忙会自动等待重试；不要同时重复启动多个窗口。\r\n'
          '本包包含入网授权，勿公开转发。迁移资料验证完成后再恢复出厂。\r\n'
        + ('迁移兼容模式已开启：保留陌生防火墙规则，不保证整台电脑仅对 Tailnet 开放。\r\n'
           if config.get('compatibilityMode') else '')
    )
    if config.get('logEndpoints'):
        instructions += '本包会向协助者的日志服务器上传本次工具运行、诊断、安装器日志及设备连接信息（不含个人迁移文件）。\r\n'
        instructions += 'Tailnet 入网后补传早期事件，结束时上传完整日志并核对回执；上传失败保留本地文件，单文件超过 32 MiB 会明确失败而非截断。\r\n'
    files['使用说明.txt'] = instructions.encode('utf-8-sig')
    hashes = dict(PINS)
    hashes.update({name: hashlib.sha256(data).hexdigest() for name, data in files.items()})
    files['SHA256SUMS.txt'] = ''.join(digest + '  ' + name + '\r\n' for name, digest in sorted(hashes.items())).encode('utf-8')
    output.parent.mkdir(parents=True, exist_ok=True)
    prefix = '' if scripts_only else 'Friend-Migration-SSH/'
    # Exclusive creation; no previous recipient's artifact can be overwritten.
    with output.open('xb') as stream:
        os.chmod(output, 0o600)
        try:
            with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
                for name, data in files.items():
                    archive.writestr(prefix + name, data)
                if not scripts_only:
                    for name in PINS:
                        archive.write(payload_dir / name, prefix + name)
        except BaseException:
            stream.close()
            output.unlink(missing_ok=True)
            raise
    try:
        with zipfile.ZipFile(output) as archive:
            if archive.testzip() is not None:
                raise ValueError('ZIP integrity check failed')
            for name, digest in hashes.items():
                if scripts_only and name in PINS:
                    continue
                if hashlib.sha256(archive.read(prefix + name)).hexdigest() != digest:
                    raise ValueError('ZIP content mismatch: ' + name)
            if archive.read(prefix + 'SHA256SUMS.txt') != files['SHA256SUMS.txt']:
                raise ValueError('ZIP manifest mismatch')
    except BaseException:
        output.unlink(missing_ok=True)
        raise
    return hashlib.sha256(output.read_bytes()).hexdigest()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path)
    parser.add_argument('--payload-dir', type=Path, default=ROOT / 'build/oneclick/payloads')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--scripts-only', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if os.name != 'nt' and args.config.stat().st_mode & 0o077:
            raise ValueError('private config must not be readable by group/others (use chmod 600)')
        digest = build(json.loads(args.config.read_text(encoding='utf-8-sig')), args.payload_dir,
                       args.output, args.scripts_only)
    except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
        # Do not echo config values, rendered source, or subprocess arguments.
        sys.exit('Packaging failed: ' + type(exc).__name__ + '; check config, public key, payloads and output path')
    print('Verified ZIP:', args.output)
    print('SHA-256:', digest)
    print('Windows installation / remote connectivity still requires target verification.')
