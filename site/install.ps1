# hyperenv command installer (Windows) — https://hyperenv.falcaosl.com
#
#   irm https://hyperenv.falcaosl.com/install.ps1 | iex
#
# Installs the `hyperenv` command from HyperEnv 2 (pre-release).
#
# What it does, in order:
#   1. picks the build for this processor (x64 or ARM64)
#   2. finds the newest `cli-v*` release on GitHub (or $env:HYPERENV_VERSION)
#   3. downloads it and checks it against the published SHA256SUMS
#   4. puts hyperenv.exe in %LOCALAPPDATA%\Programs\hyperenv and adds that
#      folder to *your* PATH (HKCU) — no administrator rights needed
#
# Running it twice is harmless. Read it first if you like:
#
#   irm https://hyperenv.falcaosl.com/install.ps1 -OutFile install.ps1
#   notepad install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = 'iramarfalcao/hyperenv'
$BinDir = if ($env:HYPERENV_BIN_DIR) { $env:HYPERENV_BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\hyperenv' }

function Step($text) { Write-Host "==> $text" }

# --- 1. Which build? -----------------------------------------------------------

$arch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
$target = switch ($arch) {
    'AMD64' { 'x86_64-pc-windows-msvc' }
    'ARM64' { 'aarch64-pc-windows-msvc' }
    default { throw "No Windows build for $arch yet." }
}

# --- 2. Which version? ---------------------------------------------------------

if ($env:HYPERENV_VERSION) {
    $tag = 'cli-v' + ($env:HYPERENV_VERSION -replace '^cli-v', '')
} else {
    Step 'Looking up the newest release'
    $releases = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases?per_page=30"
    $tag = ($releases | Where-Object { $_.tag_name -like 'cli-v*' } | Select-Object -First 1).tag_name
    if (-not $tag) { throw 'No release of the hyperenv command was found.' }
}
$version = $tag -replace '^cli-v', ''
$name = "hyperenv-$version-$target"
$base = "https://github.com/$Repo/releases/download/$tag"

# --- 3. Download and verify ----------------------------------------------------

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("hyperenv-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Step "Downloading $name"
    Invoke-WebRequest "$base/$name.zip" -OutFile "$tmp\$name.zip"
    Invoke-WebRequest "$base/SHA256SUMS" -OutFile "$tmp\SHA256SUMS"

    Step 'Checking the SHA-256'
    $line = Get-Content "$tmp\SHA256SUMS" | Where-Object { $_ -match " $([regex]::Escape("$name.zip"))$" }
    if (-not $line) { throw "$name.zip is not listed in SHA256SUMS." }
    $expected = ($line -split '\s+')[0].ToLower()
    $actual = (Get-FileHash "$tmp\$name.zip" -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw 'Checksum mismatch - the download was not installed.' }

    # --- 4. Install ------------------------------------------------------------

    Expand-Archive "$tmp\$name.zip" -DestinationPath $tmp -Force
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    Copy-Item "$tmp\$name\hyperenv.exe" (Join-Path $BinDir 'hyperenv.exe') -Force
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $BinDir)) {
    $newPath = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Step "Added $BinDir to your PATH (new terminals will see it)"
}
$env:Path = "$env:Path;$BinDir"

Step "Installed hyperenv $version in $BinDir"
& (Join-Path $BinDir 'hyperenv.exe') version
Write-Host 'Next: hyperenv profile create dev; hyperenv var set dev API_URL=http://localhost:8080; hyperenv apply dev'
