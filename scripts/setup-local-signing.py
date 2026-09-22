#!/usr/bin/env python3
"""Create a stable signing identity for this Mac's local builds, without adding trust roots."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

folder = Path.home() / 'Library/Application Support/Codex Usage Float'
config = folder / 'local-signing-identity.txt'
name = 'AI Usage Float Local Signing'
keychain = Path.home() / 'Library/Keychains/login.keychain-db'

def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout

if config.exists():
    fingerprint = config.read_text().strip()
    if not re.fullmatch(r'[0-9A-Fa-f]{40}', fingerprint):
        raise SystemExit('本地签名配置无效；未创建或替换身份。')
else:
    # Reuse an earlier imported certificate if setup was interrupted before saving config.
    found = subprocess.run(['security', 'find-certificate', '-c', name, '-Z', str(keychain)], capture_output=True, text=True)
    hashes = re.findall(r'SHA-1 hash: ([0-9A-Fa-f]{40})', found.stdout)
    if len(hashes) > 1:
        raise SystemExit('存在多个同名证书，请在钥匙串中核对；未自动选择。')
    if hashes:
        fingerprint = hashes[0]
    else:
        folder.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='local-signing-', dir=folder) as temp:
            tmp = Path(temp)
            (tmp / 'openssl.cnf').write_text('''[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=AI Usage Float Local Signing
[extensions]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
''')
            old_mask = os.umask(0o077)
            try:
                run(['openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '3650', '-sha256',
                     '-config', str(tmp / 'openssl.cnf'), '-keyout', str(tmp / 'key.pem'), '-out', str(tmp / 'cert.pem')])
                fingerprint = run(['openssl', 'x509', '-in', str(tmp / 'cert.pem'), '-noout', '-fingerprint', '-sha1']).strip().split('=')[1].replace(':', '')
                (tmp / 'identity.pem').write_bytes((tmp / 'key.pem').read_bytes() + (tmp / 'cert.pem').read_bytes())
                # Only codesign may use the non-exportable private key without prompting.
                run(['security', 'import', str(tmp / 'identity.pem'), '-f', 'pemseq', '-k', str(keychain), '-x', '-T', '/usr/bin/codesign'])
            finally:
                os.umask(old_mask)

# Check actual signing before making it the default. Never silently fall back to ad-hoc signing.
with tempfile.TemporaryDirectory(prefix='signing-check-') as temp:
    target = Path(temp) / 'probe'
    shutil.copyfile('/usr/bin/true', target)
    target.chmod(0o700)
    run(['codesign', '--force', '--sign', fingerprint, '--timestamp=none', str(target)])
    run(['codesign', '--verify', '--strict', str(target)])
folder.mkdir(parents=True, exist_ok=True)
config.write_text(fingerprint + '\n')
config.chmod(0o600)
print('本地固定签名已启用；私钥保存在登录钥匙串，仅供 codesign 使用。未修改系统信任或辅助功能授权。')
