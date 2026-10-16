# Installs Mouse Pad Receiver for the current user (no admin needed): copies
# the Windows build to %LOCALAPPDATA%\Programs, adds Start menu and desktop
# shortcuts, and an entry in Settings > Apps to uninstall it.
#
#   powershell -ExecutionPolicy Bypass -File tool\install_receiver.ps1 [-Build]
param([switch]$Build)
$ErrorActionPreference = 'Stop'

$project = Split-Path $PSScriptRoot -Parent
$source = Join-Path $project 'build\windows\x64\runner\Release'
$name = 'Mouse Pad Receiver'
$target = Join-Path $env:LOCALAPPDATA "Programs\$name"
$exe = Join-Path $target 'MousePadReceiver.exe'
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) "$name.lnk"
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) "$name.lnk"
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MousePadReceiver'

if ($Build) {
  Push-Location $project
  # Without --no-tree-shake-icons the Windows build loses its icons.
  flutter build windows --release --no-tree-shake-icons
  Pop-Location
}
if (-not (Test-Path (Join-Path $source 'MousePadReceiver.exe'))) {
  throw 'Build it first: flutter build windows --release --no-tree-shake-icons'
}

# Close a running copy so its files can be replaced.
Get-Process MousePadReceiver -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

if (Test-Path $target) { Remove-Item $target -Recurse -Force }
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item (Join-Path $source '*') $target -Recurse -Force

$shell = New-Object -ComObject WScript.Shell
foreach ($path in $startMenu, $desktop) {
  $link = $shell.CreateShortcut($path)
  $link.TargetPath = $exe
  $link.WorkingDirectory = $target
  $link.IconLocation = "$exe,0"
  $link.Description = "Use your phone as this PC's touchpad and keyboard"
  $link.Save()
}

$uninstall = Join-Path $target 'uninstall.ps1'
@"
# Removes Mouse Pad Receiver (run from Settings > Apps).
Get-Process MousePadReceiver -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Remove-Item -LiteralPath '$startMenu', '$desktop' -ErrorAction SilentlyContinue
Remove-Item -LiteralPath '$uninstallKey' -Recurse -ErrorAction SilentlyContinue
Set-Location `$env:TEMP
Remove-Item -LiteralPath '$target' -Recurse -Force -ErrorAction SilentlyContinue
"@ | Set-Content -Path $uninstall -Encoding UTF8

$sizeKb = [int]((Get-ChildItem $target -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
New-Item -Path $uninstallKey -Force | Out-Null
$props = @{
  DisplayName = $name
  DisplayIcon = "$exe,0"
  DisplayVersion = '1.0.0'
  Publisher = 'Mouse Pad'
  InstallLocation = $target
  UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstall`""
}
foreach ($p in $props.GetEnumerator()) { Set-ItemProperty $uninstallKey -Name $p.Key -Value $p.Value }
foreach ($p in @{ NoModify = 1; NoRepair = 1; EstimatedSize = $sizeKb }.GetEnumerator()) {
  Set-ItemProperty $uninstallKey -Name $p.Key -Value $p.Value -Type DWord
}

Start-Process $exe
"Installed $name to $target"
