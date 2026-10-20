<#
.SYNOPSIS
  One-click local setup for PhotoCraft on Windows.

.DESCRIPTION
  Run through Setup-and-Run-PhotoCraft.bat at the repository root. It:
    1. reads this machine's specifications (Windows, CPU, RAM, disk, GPU) and checks them;
    2. installs what the build needs when it is missing (Rust MSVC toolchain, Visual Studio C++
       Build Tools with the Windows SDK);
    3. builds a release photocraft.exe (icon and version info embedded by apps/photocraft/build.rs);
    4. installs it as %LOCALAPPDATA%\Programs\PhotoCraft\PhotoCraft.exe with Desktop and Start
       menu shortcuts;
    5. opens PhotoCraft.
  Safe to run again: tools are installed only when missing and cargo rebuilds only what changed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File packaging\windows\local-setup.ps1
  powershell -ExecutionPolicy Bypass -File packaging\windows\local-setup.ps1 -NoLaunch
#>
param(
  [switch] $NoLaunch,   # build and install, but don't open PhotoCraft
  [switch] $SkipBuild   # install the already-built target\release\photocraft.exe
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\PhotoCraft'
$InstalledExe = Join-Path $InstallDir 'PhotoCraft.exe'

function Step([string] $m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok([string] $m) { Write-Host "    ok  $m" -ForegroundColor Green }
function Warn([string] $m) { Write-Host "    !!  $m" -ForegroundColor Yellow }
function Info([string] $m) { Write-Host "        $m" }

# Native tools write progress to stderr; don't let PowerShell 5.1 turn that into a terminating error.
function Invoke-Native([string] $What, [scriptblock] $Block) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Block } finally { $ErrorActionPreference = $prev }
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

function Update-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
  $env:Path = "$cargoBin;$user;$machine"
}

function Test-Command([string] $Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

Write-Host 'PhotoCraft local setup' -ForegroundColor White
Info "Source: $Root"

# ---- 1. This machine ---------------------------------------------------------------------------
Step 'Reading this machine''s specifications'
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cores = [Environment]::ProcessorCount
$ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$archName = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$drive = (Get-Item $Root).PSDrive
$freeGB = [math]::Round($drive.Free / 1GB, 1)
$build = [int]$os.BuildNumber

Info "Windows : $($os.Caption) (build $build, $archName)"
Info "CPU     : $($cpu.Name.Trim()) - $cores logical cores"
Info "Memory  : $ramGB GB"
Info "Disk    : $freeGB GB free on $($drive.Name):"
foreach ($gpu in (Get-CimInstance Win32_VideoController)) {
  Info "GPU     : $($gpu.Name) (driver $($gpu.DriverVersion))"
}

switch ($archName) {
  'AMD64' { $Triple = 'x86_64-pc-windows-msvc'; $VcComponent = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
  'ARM64' { $Triple = 'aarch64-pc-windows-msvc'; $VcComponent = 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
  default { throw "PhotoCraft needs 64-bit Windows (x64 or ARM64); this machine is $archName." }
}
if ($build -lt 17763) { throw "PhotoCraft needs Windows 10 version 1809 or later (this is build $build)." }
Ok "64-bit Windows ($archName)"

if ($ramGB -lt 8) { Warn "Only $ramGB GB of memory: the build will be slow, and large images may not fit." } else { Ok "$ramGB GB memory" }
# rustc uses roughly 1.5-2 GB per parallel job on the bigger crates; don't let it swap.
$Jobs = [math]::Max(1, [math]::Min($cores, [math]::Floor($ramGB / 1.5)))
Info "Build will use $Jobs parallel jobs."

$needGB = if (Test-Path (Join-Path $Root 'target\release\photocraft.exe')) { 3 } else { 12 }
if ($freeGB -lt $needGB) { throw "Only $freeGB GB free on $($drive.Name): - the build needs about $needGB GB. Free some space and run again." }
Ok "$freeGB GB free disk"

try {
  $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction Stop).VerifiedAndReputablePolicyState
  if ($sac -eq 1) {
    Warn 'Smart App Control is ON. It can block programs compiled on this PC (error 4551).'
    Warn 'If the build fails with that error, see docs\development.md > Windows source builds.'
  }
} catch { }

# ---- 2. Build tools ----------------------------------------------------------------------------
$HaveWinget = Test-Command 'winget'
Update-SessionPath

Step 'Checking the C++ build tools (MSVC linker and Windows SDK)'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
function Find-VcTools {
  if (-not (Test-Path $vswhere)) { return $null }
  $p = & $vswhere -latest -products '*' -requires $VcComponent -property installationPath 2>$null
  if ($p) { return ($p | Select-Object -First 1) }
  return $null
}
$vs = Find-VcTools
if (-not $vs) {
  Warn 'Visual Studio C++ Build Tools not found. Installing them (about 3-6 GB; Windows will ask for permission)...'
  $vsArgs = "--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --add $VcComponent --includeRecommended"
  if ($HaveWinget) {
    Invoke-Native 'Installing Visual Studio Build Tools' {
      winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget --accept-source-agreements --accept-package-agreements --override $vsArgs
    }
  } else {
    $bootstrap = Join-Path $env:TEMP 'vs_BuildTools.exe'
    Invoke-WebRequest -UseBasicParsing 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $bootstrap
    $p = Start-Process $bootstrap -ArgumentList $vsArgs -Wait -PassThru -Verb RunAs
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "Visual Studio Build Tools installer failed (exit code $($p.ExitCode))" }
  }
  $vs = Find-VcTools
  if (-not $vs) { throw 'The C++ build tools still aren''t installed. Install "Desktop development with C++" from https://visualstudio.microsoft.com/visual-cpp-build-tools/ and run this again.' }
}
Ok "C++ build tools: $vs"

# rc.exe (Windows SDK) embeds the PhotoCraft icon into the exe.
$sdkRoot = $null
foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0', 'HKLM:\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v10.0') {
  try { $sdkRoot = (Get-ItemProperty $key -Name InstallationFolder -ErrorAction Stop).InstallationFolder; break } catch { }
}
$rc = $null
if ($sdkRoot) { $rc = Get-ChildItem (Join-Path $sdkRoot 'bin') -Recurse -Filter rc.exe -ErrorAction SilentlyContinue | Sort-Object { $_.FullName -notlike '*\x64\*' }, FullName -Descending:$false | Select-Object -First 1 }
if (-not $rc) {
  Warn 'Windows SDK (rc.exe) not found; it is needed to put the PhotoCraft logo on the exe. Installing it...'
  if (-not $HaveWinget) { throw 'Install the Windows 10/11 SDK (https://developer.microsoft.com/windows/downloads/windows-sdk/) and run this again.' }
  Invoke-Native 'Installing the Windows SDK' {
    winget install --id Microsoft.WindowsSDK.10.0.26100 -e --source winget --accept-source-agreements --accept-package-agreements
  }
} else {
  Ok "Windows SDK: $($rc.FullName)"
}

Step 'Checking Rust'
if (-not (Test-Command 'rustup')) {
  Warn 'Rust not found. Installing rustup and the stable MSVC toolchain...'
  if ($HaveWinget) {
    Invoke-Native 'Installing rustup' {
      winget install --id Rustlang.Rustup -e --source winget --accept-source-agreements --accept-package-agreements
    }
  } else {
    $init = Join-Path $env:TEMP 'rustup-init.exe'
    Invoke-WebRequest -UseBasicParsing "https://static.rust-lang.org/rustup/dist/$Triple/rustup-init.exe" -OutFile $init
    Invoke-Native 'rustup-init' { & $init -y --default-host $Triple --default-toolchain stable --profile minimal }
  }
  Update-SessionPath
  if (-not (Test-Command 'rustup')) { throw 'rustup was installed but isn''t on PATH yet. Close this window and run the setup again.' }
}

# PhotoCraft builds with the MSVC toolchain; make sure it is the default and new enough.
$need = '0.0'
foreach ($line in Get-Content (Join-Path $Root 'Cargo.toml')) {
  if ($line -match '^\s*rust-version\s*=\s*"([^"]+)"') { $need = $Matches[1]; break }
}
$hostLine = ''
$verLine = ''
try {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $vv = & rustc -vV 2>$null
  $ErrorActionPreference = $prev
  $hostLine = ($vv | Where-Object { $_ -like 'host:*' }) -replace '^host:\s*', ''
  $verLine = ($vv | Where-Object { $_ -like 'release:*' }) -replace '^release:\s*', ''
} catch { }
if (-not $verLine -or $hostLine -notlike '*msvc*') {
  Invoke-Native 'rustup default stable' { rustup default "stable-$Triple" }
} elseif ([version]($verLine -replace '-.*$', '') -lt [version]$need) {
  Warn "Rust $verLine is older than the $need PhotoCraft needs; updating..."
  Invoke-Native 'rustup update' { rustup update stable }
}
Ok ((& rustc --version) + ' / ' + (& cargo --version))

# craft-fonts (optional): bundles the open-licensed fonts when a checkout sits next to this repo.
$fonts = Join-Path (Split-Path $Root -Parent) 'craft-fonts'
if (Test-Path (Join-Path $fonts 'fonts')) {
  $env:CRAFT_FONTS_DIR = (Resolve-Path $fonts).Path
  Ok "Bundling fonts from $env:CRAFT_FONTS_DIR"
} else {
  Info 'No ..\craft-fonts checkout found; building without bundled fonts (optional).'
}

# ---- 3. Build ----------------------------------------------------------------------------------
$Built = Join-Path $Root 'target\release\photocraft.exe'
if (-not $SkipBuild) {
  Step 'Building PhotoCraft (release). The first build takes 10-30 minutes; later ones are quick.'
  $env:PHOTOCRAFT_REQUIRE_WINRES = '1'   # fail rather than build an exe without the logo
  if (-not $env:PHOTOCRAFT_BUILD_SHA) {
    try { $env:PHOTOCRAFT_BUILD_SHA = (& git -C $Root rev-parse HEAD 2>$null) } catch { }
  }
  Push-Location $Root
  try {
    Invoke-Native 'cargo build' { cargo build --release --locked -p photocraft --features heif -j $Jobs }
  } finally { Pop-Location }
}
if (-not (Test-Path $Built)) { throw "No build found at $Built" }
Ok "Built $Built"

# ---- 4. Install --------------------------------------------------------------------------------
Step "Installing to $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -ieq $InstalledExe) }
$same = (Test-Path $InstalledExe) -and ((Get-FileHash $InstalledExe).Hash -eq (Get-FileHash $Built).Hash)
if ($same) {
  Ok 'PhotoCraft.exe is already up to date'
} elseif ($running) {
  Warn 'PhotoCraft is open, so the new build can''t replace it. Close PhotoCraft and run this again to update.'
} else {
  Copy-Item $Built $InstalledExe -Force
  Ok 'Installed PhotoCraft.exe'
}

$shell = New-Object -ComObject WScript.Shell
$links = @(
  (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PhotoCraft.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'PhotoCraft.lnk')
)
foreach ($lnk in $links) {
  $s = $shell.CreateShortcut($lnk)
  $s.TargetPath = $InstalledExe
  $s.WorkingDirectory = $InstallDir
  $s.IconLocation = "$InstalledExe,0"
  $s.Description = 'PhotoCraft image editor'
  $s.Save()
  Ok "Shortcut: $lnk"
}

# ---- 5. Open -----------------------------------------------------------------------------------
if ($NoLaunch) {
  Step 'Done. Open PhotoCraft from the Desktop or Start menu shortcut.'
} else {
  Step 'Opening PhotoCraft'
  if ($running) { Start-Process $InstalledExe } else { Start-Process $InstalledExe -WorkingDirectory $InstallDir }
  Ok 'PhotoCraft is starting. Next time just use the PhotoCraft icon on your Desktop.'
}
