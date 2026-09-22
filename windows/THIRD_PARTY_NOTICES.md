# Windows distribution components

The application's own source is MIT licensed. The standalone Windows build also contains an unmodified Python runtime, Tcl/Tk, SQLite, zlib, libffi, OpenSSL and the PyInstaller bootloader. Their license terms remain separate from this project's MIT license.

- Python and the bundled standard-library components: `licenses/Python-LICENSE.txt`, copied from the exact runtime used to build the release. It includes notices for components such as libffi and bzip2.
- Expat: `licenses/Expat-COPYING.txt`, from CPython 3.13.7 bundled source.
- Decimal arithmetic: `licenses/libmpdec-COPYRIGHT.txt`, from CPython's mpdecimal 4.0.0 dependency.
- XZ/liblzma: `licenses/XZ-COPYING.txt`, from the upstream 5.2.5 source.
- Tcl 8.6.15: `licenses/Tcl-8.6.15-LICENSE.txt`, from the official Tcl source tag.
- Tk: `licenses/Tk-LICENSE.txt`, copied from the build runtime.
- zlib: `licenses/zlib-LICENSE.txt`, from the official zlib source repository.
- OpenSSL 3.0.16: `licenses/OpenSSL-3.0.16-LICENSE.txt`, from the official OpenSSL release tag; used by Python for the opt-in HTTPS account query.
- SQLite: `licenses/SQLite-NOTICE.txt`, with the upstream public-domain declaration link.
- PyInstaller: `licenses/PyInstaller-COPYING.txt`, including its bootloader exception, copied from the installed build distribution. The application's MIT source remains available in this repository.

The build uses the Microsoft runtime DLLs supplied with the official Windows Python distribution. The Python license file includes Microsoft Distributable Code conditions; Microsoft also publishes [Visual C++ Runtime terms](https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/). Microsoft components retain their respective terms; they are not relicensed under MIT. The program uses the Windows-provided .NET Framework for its read-only window-title helper.

No OpenAI, Anthropic, Tencent, Cursor or OpenCode application binaries, models, account credentials or user records are included.
