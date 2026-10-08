# Tetoris PS - Tetris clássico (1984) em PowerShell
param([switch]$NoAudio)

$ErrorActionPreference = 'Stop'
try { [Console]::CursorVisible = $false } catch {}

function Write-At([int]$x,[int]$y,[string]$s) {
  try { [Console]::SetCursorPosition($x,$y); [Console]::Write($s) } catch {}
}

$W = 10; $H = 20
$field = @()
for ($y = 0; $y -lt $H; $y++) {
  $r = @()
  for ($x = 0; $x -lt $W; $x++) { $r += 0 }
  $field += @(, $r)
}

$pieces = @(
  @(@(0,0,0,0),@(1,1,1,1),@(0,0,0,0),@(0,0,0,0)),
  @(@(1,1),@(1,1)),
  @(@(0,1,0),@(1,1,1),@(0,0,0)),
  @(@(0,1,1),@(1,1,0),@(0,0,0)),
  @(@(1,1,0),@(0,1,1),@(0,0,0)),
  @(@(1,0,0),@(1,1,1),@(0,0,0)),
  @(@(0,0,1),@(1,1,1),@(0,0,0))
)

function Rotate([array]$p) {
  $h = $p.Length; $w = $p[0].Length
  $res = @()
  for ($y = 0; $y -lt $w; $y++) {
    $row = @()
    for ($x = 0; $x -lt $h; $x++) { $row += $p[$h-1-$x][$y] }
    $res += @(, $row)
  }
  return ,$res
}

function CanPlace([array]$p, [int]$px, [int]$py) {
  $h = $p.Length; $w = $p[0].Length
  for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
      if ($p[$y][$x] -ne 0) {
        $nx = $px + $x; $ny = $py + $y
        if ($nx -lt 0 -or $nx -ge $W -or $ny -ge $H) { return $false }
        if ($ny -ge 0 -and $field[$ny][$nx] -ne 0) { return $false }
      }
    }
  }
  return $true
}

function Merge([array]$p, [int]$px, [int]$py) {
  $h = $p.Length; $w = $p[0].Length
  for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
      if ($p[$y][$x] -ne 0) { $field[$py + $y][$px + $x] = 1 }
    }
  }
}

function ClearLines {
  $new = @()
  for ($y = $H-1; $y -ge 0; $y--) {
    $full = $true
    for ($x = 0; $x -lt $W; $x++) {
      if ($field[$y][$x] -eq 0) { $full = $false; break }
    }
    if (-not $full) { $new = @(, $field[$y]) + $new }
  }
  while ($new.Count -lt $H) {
    $row = @()
    for ($x = 0; $x -lt $W; $x++) { $row += 0 }
    $new = @(, $row) + $new
  }
  $field = $new
}

function Draw {
  [Console]::Clear()
  Write-At 0 0 "+----------+"
  for ($y = 0; $y -lt $H; $y++) {
    $line = "|"
    for ($x = 0; $x -lt $W; $x++) {
      $line += if ($field[$y][$x] -eq 1) { "#" } else { " " }
    }
    $line += "|"
    Write-At 0 ($y+1) $line
  }
  Write-At 0 ($H+1) "+----------+"
  Write-At 12 2 "TETORIS PS"
  Write-At 12 4 "←→↓ ↑/SPACE ROT"
  Write-At 12 6 "Q/ESC SAIR"
}

if (-not $NoAudio) {
  try {
    Add-Type -AssemblyName System.Media
    $mel = @(@(660,120),@(588,120),@(524,120),@(588,120),@(660,120),@(660,120),@(660,240))
    $i = 0
  } catch {}
}

function Play {
  try { [Console]::CursorVisible = $false } catch {}
  $idx = Get-Random -Max $pieces.Count
$cur = $pieces[$idx]
  $px = 3; $py = 0
  $last = [DateTime]::Now
  $speed = 300
  $mi = 0
  while ($true) {
    if (-not $NoAudio) {
      try {
        $el = ([DateTime]::Now - $last).TotalMilliseconds
        if ($el -gt $speed * 0.25) {
          if ($mel -and $mi -lt $mel.Count) {
            [Console]::Beep($mel[$mi][0], $mel[$mi][1])
            $mi++
            if ($mi -ge $mel.Count) { $mi = 0 }
          }
        }
      } catch {}
    }
    if (([DateTime]::Now - $last).TotalMilliseconds -gt $speed) {
      if (CanPlace $cur $px ($py + 1)) { $py++ } else {
        Merge $cur $px $py
        ClearLines
        $idx = Get-Random -Max $pieces.Count
        $cur = , ($pieces[$idx])
        $px = 3; $py = 0
        if (-not (CanPlace $cur $px $py)) { break }
      }
      Draw
      $last = [DateTime]::Now
    }
    if ([Console]::KeyAvailable) {
      $k = [Console]::ReadKey($True)
      switch ($k.Key) {
        'LeftArrow' { if (CanPlace $cur ($px-1) $py) { $px--; Draw } }
        'RightArrow' { if (CanPlace $cur ($px+1) $py) { $px++; Draw } }
        'DownArrow' { if (CanPlace $cur $px ($py+1)) { $py++; Draw } }
        'UpArrow' { $nr = Rotate $cur; if (CanPlace $nr $px $py) { $cur = $nr; Draw } }
        'Spacebar' { $nr = Rotate $cur; if (CanPlace $nr $px $py) { $cur = $nr; Draw } }
        'Q' { try { [Console]::CursorVisible = $true } catch {}; exit }
        'Escape' { try { [Console]::CursorVisible = $true } catch {}; exit }
      }
    }
    [Threading.Thread]::Sleep(10)
  }
  try { [Console]::CursorVisible = $true } catch {}
  Write-At 0 ($H + 3) "GAME OVER"
}

Draw
Play
