# bootstrap-tetris.ps1
[CmdletBinding()]
param([switch]$NoAudio)
$ErrorActionPreference='Stop'
$Base = Join-Path $env:LOCALAPPDATA 'TetrisPS'
$Zip = Join-Path $Base 'tetrisps.zip'
$Url = 'https://raw.githubusercontent.com/brunohenriquegardanimonteiro-crypto/tetoris/main/tetris.ps1'
New-Item -ItemType Directory -Force $Base | Out-Null
$out = Join-Path $Base 'tetris.ps1'
try { Invoke-WebRequest $Url -OutFile $out -UseBasicParsing } catch {
  (New-Object Net.WebClient).DownloadFile($Url, $out)
}
& $out @PSBoundParameters
