# Tetoris PS - Tetris em PowerShell (versao corrigida)
# Uso:  .\tetris.ps1            (com musica)
#       .\tetris.ps1 -NoAudio   (sem musica)
# Durante o jogo, a tecla M liga/desliga a musica.
param([switch]$NoAudio)

$W = 10; $H = 20
$field = New-Object 'int[,]' $H, $W
$S = @{ Score = 0; Lines = 0 }

$pieces = @(
  @(@(0,0,0,0),@(1,1,1,1),@(0,0,0,0),@(0,0,0,0)),
  @(@(1,1),@(1,1)),
  @(@(0,1,0),@(1,1,1),@(0,0,0)),
  @(@(0,1,1),@(1,1,0),@(0,0,0)),
  @(@(1,1,0),@(0,1,1),@(0,0,0)),
  @(@(1,0,0),@(1,1,1),@(0,0,0)),
  @(@(0,0,1),@(1,1,1),@(0,0,0))
)

function Write-At([int]$x, [int]$y, [string]$s) {
  try { [Console]::SetCursorPosition($x, $y); [Console]::Write($s) } catch {}
}

function Rotate([array]$p) {
  $ph = $p.Length; $pw = $p[0].Length
  $res = @()
  for ($y = 0; $y -lt $pw; $y++) {
    $row = @()
    for ($x = 0; $x -lt $ph; $x++) { $row += $p[$ph-1-$x][$y] }
    $res += @(, $row)
  }
  return ,$res
}

function CanPlace([array]$p, [int]$px, [int]$py) {
  $ph = $p.Length; $pw = $p[0].Length
  for ($y = 0; $y -lt $ph; $y++) {
    for ($x = 0; $x -lt $pw; $x++) {
      if ($p[$y][$x] -ne 0) {
        $nx = $px + $x; $ny = $py + $y
        if ($nx -lt 0 -or $nx -ge $W -or $ny -ge $H) { return $false }
        if ($ny -ge 0 -and $field[$ny,$nx] -ne 0) { return $false }
      }
    }
  }
  return $true
}

function Merge([array]$p, [int]$px, [int]$py) {
  $ph = $p.Length; $pw = $p[0].Length
  for ($y = 0; $y -lt $ph; $y++) {
    for ($x = 0; $x -lt $pw; $x++) {
      if ($p[$y][$x] -ne 0) { $field[($py+$y),($px+$x)] = 1 }
    }
  }
}

# Remove linhas completas (alterando o campo no lugar) e devolve quantas foram.
function ClearLines {
  $cleared = 0
  $y = $H - 1
  while ($y -ge 0) {
    $full = $true
    for ($x = 0; $x -lt $W; $x++) {
      if ($field[$y,$x] -eq 0) { $full = $false; break }
    }
    if ($full) {
      for ($r = $y; $r -gt 0; $r--) {
        for ($x = 0; $x -lt $W; $x++) { $field[$r,$x] = $field[($r-1),$x] }
      }
      for ($x = 0; $x -lt $W; $x++) { $field[0,$x] = 0 }
      $cleared++
    } else {
      $y--
    }
  }
  return $cleared
}

# Redesenha sem limpar a tela (evita piscar).
function Draw([array]$cur, [int]$px, [int]$py) {
  $ph = $cur.Length; $pw = $cur[0].Length
  Write-At 0 0 ('+' + ('-' * ($W * 2)) + '+')
  for ($y = 0; $y -lt $H; $y++) {
    $line = '|'
    for ($x = 0; $x -lt $W; $x++) {
      $on = ($field[$y,$x] -ne 0)
      $cy = $y - $py; $cx = $x - $px
      if (-not $on -and $cy -ge 0 -and $cy -lt $ph -and $cx -ge 0 -and $cx -lt $pw) {
        if ($cur[$cy][$cx] -ne 0) { $on = $true }
      }
      if ($on) { $line += '[]' } else { $line += ' .' }
    }
    $line += '|'
    Write-At 0 ($y + 1) $line
  }
  Write-At 0 ($H + 1) ('+' + ('-' * ($W * 2)) + '+')

  $level = [int][math]::Floor($S.Lines / 10)
  $px0 = $W * 2 + 4
  Write-At $px0 1  'TETORIS PS'
  Write-At $px0 3  ('Pontos: ' + $S.Score).PadRight(20)
  Write-At $px0 4  ('Linhas: ' + $S.Lines).PadRight(20)
  Write-At $px0 5  ('Nivel:  ' + $level).PadRight(20)
  Write-At $px0 7  'Setas: mover / baixar'
  Write-At $px0 8  'Cima ou Espaco: girar'
  Write-At $px0 9  'M: musica liga/desliga'
  Write-At $px0 10 'Q ou Esc: sair'
}


# ---- Musica em segundo plano (nao trava o jogo) ----
$music = [hashtable]::Synchronized(@{ On = (-not $NoAudio); Run = $true })

function Start-Music {
  $rs = [runspacefactory]::CreateRunspace()
  $rs.Open()
  $rs.SessionStateProxy.SetVariable('music', $music)
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript({
    # Korobeiniki (tema classico, dominio publico): @(frequencia, duracao_ms)
    $notes = @(
      @(659,300),@(494,150),@(523,150),@(587,300),@(523,150),@(494,150),
      @(440,300),@(440,150),@(523,150),@(659,300),@(587,150),@(523,150),
      @(494,450),@(523,150),@(587,300),@(659,300),@(523,300),@(440,300),@(440,300),@(0,300),
      @(587,450),@(698,150),@(880,300),@(784,150),@(698,150),
      @(659,450),@(523,150),@(659,300),@(587,150),@(523,150),
      @(494,300),@(494,150),@(523,150),@(587,300),@(659,300),@(523,300),@(440,300),@(440,300),@(0,600)
    )
    while ($music.Run) {
      foreach ($n in $notes) {
        if (-not $music.Run) { break }
        if ($music.On -and $n[0] -gt 0) {
          try { [Console]::Beep($n[0], $n[1]) } catch { Start-Sleep -Milliseconds $n[1] }
        } else {
          Start-Sleep -Milliseconds $n[1]
        }
        Start-Sleep -Milliseconds 20
      }
    }
  })
  [void]$ps.BeginInvoke()
  return $ps
}

function Play {
  $cur = $pieces[(Get-Random -Maximum $pieces.Count)]
  $px = 3; $py = 0
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $nextDrop = 0
  $running = $true
  $over = $false
  Draw $cur $px $py

  while ($running) {
    $level = [int][math]::Floor($S.Lines / 10)
    $speed = [math]::Max(80, 500 - 40 * $level)
    $dirty = $false

    while ([Console]::KeyAvailable) {
      $k = [Console]::ReadKey($true)
      switch ($k.Key.ToString()) {
        'LeftArrow'  { if (CanPlace $cur ($px-1) $py) { $px--; $dirty = $true } }
        'RightArrow' { if (CanPlace $cur ($px+1) $py) { $px++; $dirty = $true } }
        'DownArrow'  { if (CanPlace $cur $px ($py+1)) { $py++; $S.Score++; $dirty = $true } }
        { $_ -eq 'UpArrow' -or $_ -eq 'Spacebar' } {
          $nr = Rotate $cur
          foreach ($dx in 0,-1,1,-2,2) {
            if (CanPlace $nr ($px+$dx) $py) { $cur = $nr; $px += $dx; $dirty = $true; break }
          }
        }
        'M'      { $music.On = -not $music.On }
        'Q'      { $running = $false }
        'Escape' { $running = $false }
      }
    }
    if (-not $running) { break }

    if ($sw.ElapsedMilliseconds -ge $nextDrop) {
      if (CanPlace $cur $px ($py+1)) {
        $py++
      } else {
        Merge $cur $px $py
        $n = ClearLines
        if ($n -gt 0) {
          $S.Lines += $n
          $S.Score += @(0,100,300,500,800)[$n] * ($level + 1)
        }
        $cur = $pieces[(Get-Random -Maximum $pieces.Count)]
        $px = 3; $py = 0
        if (-not (CanPlace $cur $px $py)) { $over = $true; $running = $false }
      }
      $nextDrop = $sw.ElapsedMilliseconds + $speed
      $dirty = $true
    }

    if ($dirty) { Draw $cur $px $py }
    [Threading.Thread]::Sleep(10)
  }

  if ($over) {
    Draw $cur $px $py
    Write-At 0 ($H + 3) ('GAME OVER - pontos: ' + $S.Score)
  }
}

try {
  [Console]::CursorVisible = $false
  [Console]::Clear()
  $musicPs = Start-Music
  Play
} finally {
  $music.Run = $false
  try { if ($musicPs) { [void]$musicPs.BeginStop($null, $null) } } catch {}
  try { [Console]::CursorVisible = $true } catch {}
  try { [Console]::SetCursorPosition(0, $H + 5) } catch {}
}
