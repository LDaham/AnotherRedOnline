# ==============================================================================
# Another Red Online - self-updating launcher
#
# Put this file AND "Another Red Online.bat" in your Another Red game folder
# (the one containing Game.exe), then launch the game via the .bat instead of
# Game.exe. On every launch it:
#   1. asks GitHub for the latest mod version (dist/manifest.json),
#   2. if newer than what's installed, downloads the plugin + assets and applies
#      them IN PLACE (appends into Data/PluginScripts.rxdata, copies assets),
#   3. starts the game.
#
# Any network/update failure is non-fatal: it logs a note and launches the game
# with whatever is already installed, so you can always play offline.
#
# HOW THE APPLY WORKS (no Python, no recompile):
#   PluginScripts.rxdata is Marshal.dump(array_of_plugins). We keep a pristine
#   copy (…​.arnet_base) the first time we run on a clean game, and each update
#   rebuilds from it: restore base -> bump the array count -> append the mod's
#   prebuilt element bytes. Existing base-game plugins are never disturbed.
# ==============================================================================

# --- CONFIG (filled in at release; see README) --------------------------------
$Owner   = "LDaham"             # GitHub owner/org
$Repo    = "AnotherRedOnline"   # GitHub repo name
$Branch  = "main"
$GameExe = "Game.exe"
# ------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$RawBase = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/dist"

$GameDir = $PSScriptRoot
$DataDir = Join-Path $GameDir "Data"
$Rxdata  = Join-Path $DataDir "PluginScripts.rxdata"
$BaseBak = Join-Path $DataDir "PluginScripts.rxdata.arnet_base"
$VerFile = Join-Path $GameDir "arnet_version.txt"
$PluginName = "Another Red Online"

# --- Ruby Marshal 'long' codec (only what a top-level array count needs) -------
function Read-MLong([byte[]]$d, [int]$off, [ref]$len) {
  $c = [int]$d[$off]; if ($c -ge 128) { $c -= 256 }
  if ($c -eq 0) { $len.Value = 1; return 0 }
  if ($c -ge 5) { $len.Value = 1; return ($c - 5) }
  if ($c -ge 1) {
    $n = 0
    for ($k = 0; $k -lt $c; $k++) { $n = $n -bor ([int]$d[$off + 1 + $k] -shl (8 * $k)) }
    $len.Value = 1 + $c; return $n
  }
  throw "unexpected negative array count"
}
function Write-MLong([int]$n) {
  if ($n -eq 0)   { return ,([byte]0) }
  if ($n -le 122) { return ,([byte]($n + 5)) }
  $body = New-Object System.Collections.Generic.List[byte]
  $v = $n
  while ($v -ne 0) { $body.Add([byte]($v -band 0xff)); $v = $v -shr 8 }
  $out = New-Object System.Collections.Generic.List[byte]
  $out.Add([byte]$body.Count); $out.AddRange($body)
  return $out.ToArray()
}

function Test-ContainsPlugin([byte[]]$d) {
  $lat = [Text.Encoding]::GetEncoding("iso-8859-1")
  return ($lat.GetString($d)).IndexOf($lat.GetString([Text.Encoding]::UTF8.GetBytes($PluginName))) -ge 0
}

function New-AppendedRxdata([byte[]]$base, [byte[]]$elem) {
  if ($base.Length -lt 3 -or $base[0] -ne 4 -or $base[1] -ne 8 -or $base[2] -ne 0x5B) {
    throw "PluginScripts.rxdata is not a Marshal array (unexpected format)"
  }
  $clen = 0
  $count = Read-MLong $base 3 ([ref]$clen)
  $newCount = Write-MLong ($count + 1)
  $ms = New-Object System.IO.MemoryStream
  $ms.Write($base, 0, 3)                                   # 04 08 '['
  $ms.Write($newCount, 0, $newCount.Length)                # count + 1
  $tail = 3 + $clen
  $ms.Write($base, $tail, $base.Length - $tail)            # existing plugins
  $ms.Write($elem, 0, $elem.Length)                        # our element
  return $ms.ToArray()
}

function Get-Sha256File([string]$path) {
  return (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
}

function Update-Mod($manifest) {
  if (-not (Test-Path $Rxdata)) { throw "PluginScripts.rxdata not found at $Rxdata" }

  # 1) capture a pristine base the first time (refuse if the file is already
  #    modded and we have no base to rebuild from).
  if (-not (Test-Path $BaseBak)) {
    $cur = [IO.File]::ReadAllBytes($Rxdata)
    if (Test-ContainsPlugin $cur) {
      throw "This PluginScripts.rxdata already contains the mod but no pristine base was saved. Reinstall the launcher onto a clean copy of the game."
    }
    [IO.File]::WriteAllBytes($BaseBak, $cur)
  }

  # 2) download element.bin, verify hash
  $elemTmp = Join-Path $env:TEMP "arnet_element.bin"
  Invoke-WebRequest -UseBasicParsing -Uri "$RawBase/$($manifest.element.path)" -OutFile $elemTmp
  if ((Get-Sha256File $elemTmp) -ne ([string]$manifest.element.sha256).ToLower()) {
    throw "element.bin hash mismatch (download corrupt?)"
  }

  # 3) rebuild rxdata = pristine base + our element
  $base = [IO.File]::ReadAllBytes($BaseBak)
  $elem = [IO.File]::ReadAllBytes($elemTmp)
  [IO.File]::WriteAllBytes($Rxdata, (New-AppendedRxdata $base $elem))

  # 4) assets (game-root relative paths; url-encode each segment for raw URLs)
  foreach ($a in $manifest.assets) {
    $rel = [string]$a.path
    $dst = Join-Path $GameDir ($rel -replace '/', '\')
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $enc = (($rel -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    Invoke-WebRequest -UseBasicParsing -Uri "$RawBase/assets/$enc" -OutFile $dst
    if ((Get-Sha256File $dst) -ne ([string]$a.sha256).ToLower()) {
      throw "asset hash mismatch: $rel"
    }
  }
}

# --- main ---------------------------------------------------------------------
try {
  $local = if (Test-Path $VerFile) { (Get-Content $VerFile -Raw).Trim() } else { "" }
  $manifest = Invoke-RestMethod -UseBasicParsing -TimeoutSec 8 -Uri "$RawBase/manifest.json"
  $latest = [string]$manifest.version
  if ($latest -and $latest -ne $local) {
    Write-Host "[Another Red Online] updating $local -> $latest ..." -ForegroundColor Cyan
    Update-Mod $manifest
    Set-Content -Path $VerFile -Value $latest -Encoding Ascii
    Write-Host "[Another Red Online] update complete." -ForegroundColor Green
  } else {
    Write-Host "[Another Red Online] up to date (v$local)." -ForegroundColor DarkGray
  }
} catch {
  Write-Host "[Another Red Online] update check skipped: $($_.Exception.Message)" -ForegroundColor Yellow
}

# always launch, even if the update failed (offline play must keep working)
$exe = Join-Path $GameDir $GameExe
if (Test-Path $exe) {
  Start-Process -FilePath $exe -WorkingDirectory $GameDir
} else {
  Write-Host "Game.exe not found next to the launcher ($exe)." -ForegroundColor Red
  Start-Sleep -Seconds 4
}
