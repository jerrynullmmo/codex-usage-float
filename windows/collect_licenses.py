"""Copy licenses from the actual build runtime into the distributable, never from user data."""
from pathlib import Path
import importlib.metadata
import shutil
import sys
import tkinter
import ssl

assert tkinter.Tcl().eval('info patchlevel') == '8.6.15', 'Review Tcl notices before changing the release runtime'
assert ssl.OPENSSL_VERSION.startswith('OpenSSL 3.0.16 '), 'Review OpenSSL notices before changing the release runtime'
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
base=Path(sys.base_prefix)
shutil.copy2(base/'LICENSE.txt',out/'Python-LICENSE.txt')
tk_license=base/'tcl/tk8.6/license.terms'
shutil.copy2(tk_license,out/'Tk-LICENSE.txt')
dist=importlib.metadata.distribution('pyinstaller')
license_file=next(f for f in dist.files if str(f).endswith('COPYING.txt'))
shutil.copy2(dist.locate_file(license_file),out/'PyInstaller-COPYING.txt')
for path in (Path(__file__).parent/'third_party').glob('*.txt'):shutil.copy2(path,out/path.name)
