$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $projectRoot
python -c "import sys,struct; assert sys.version_info[:3] == (3,13,7) and struct.calcsize('P')==8; import tkinter, PyInstaller"
if ($LASTEXITCODE -ne 0) { throw 'Requires 64-bit Python 3.13.7, Tkinter and PyInstaller. See windows/README.md.' }
python -m unittest discover -s windows -p test_usage.py
if ($LASTEXITCODE -ne 0) { throw 'Accounting tests failed.' }
$buildDirectory = Join-Path $projectRoot 'build'
New-Item -ItemType Directory -Force $buildDirectory | Out-Null
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$focus = Join-Path $buildDirectory 'FocusProbe.exe'
& (Join-Path $framework 'csc.exe') /nologo /target:exe /optimize "/out:$focus" /reference:System.Web.Extensions.dll "/reference:$framework\WPF\UIAutomationClient.dll" "/reference:$framework\WPF\UIAutomationTypes.dll" (Join-Path $PSScriptRoot 'FocusProbe.cs')
if ($LASTEXITCODE -ne 0) { throw 'Window title probe build failed.' }
Copy-Item $focus (Join-Path $PSScriptRoot 'FocusProbe.exe') -Force
python -m PyInstaller --noconfirm --clean --onefile --windowed --name AIUsageFloat --exclude-module ssl --exclude-module _ssl --exclude-module _hashlib --exclude-module multiprocessing --exclude-module concurrent.futures.process --distpath dist/windows --workpath build/pyinstaller --specpath build --add-data "$PSScriptRoot\prices.json;." --add-data "$focus;." --add-data "$projectRoot\LICENSE;." windows/usage_float.py
if ($LASTEXITCODE -ne 0) { throw 'Application build failed.' }
$version = (Get-Content VERSION -Raw).Trim()
$package = Join-Path $projectRoot 'build/windows-package'
New-Item -ItemType Directory -Force $package | Out-Null
Copy-Item dist/windows/AIUsageFloat.exe $package -Force
Copy-Item windows/README.md (Join-Path $package 'README.md') -Force
Copy-Item LICENSE $package -Force
Copy-Item docs/ADAPTERS.md $package -Force
Copy-Item windows/THIRD_PARTY_NOTICES.md $package -Force
python windows/collect_licenses.py (Join-Path $package 'licenses')
if ($LASTEXITCODE -ne 0) { throw 'Runtime license collection failed.' }
$archive = Join-Path $projectRoot "dist/ai-usage-float-$version-windows-x64.zip"
Compress-Archive -LiteralPath (Get-ChildItem $package).FullName -DestinationPath $archive -Force
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $projectRoot 'dist/WINDOWS-SHA256SUMS'),"$hash  $([IO.Path]::GetFileName($archive))`n",[Text.UTF8Encoding]::new($false))
Write-Output $archive
