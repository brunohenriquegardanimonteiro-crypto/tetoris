# tetris.ps1 completo com som
param([switch]$NoAudio)

$ErrorActionPreference='Stop'
Hide-Cursor

function Write-At([int]$x,[int]$y,[string]$s){ try{[Console]::SetCursorPosition($x,$y);[Console]::Write($s)}catch{} }

if (-not $NoAudio) {
  Add-Type -AssemblyName System.Media
  $notes = @(
    @{f=660;d=120},@{f=588;d=120},@{f=524;d=120},@{f=588;d=120},@{f=660;d=120},@{f=660;d=120},@{f=660;d=240},
    @{f=588;d=120},@{f=588;d=120},@{f=588;d=240},@{f=660;d=120},@{f=784;d=120},@{f=784;d=240}
  )
  function BeepTone([int]$f,[int]$ms){ if($f-lt20){[Console]::Beep(20,$ms)}else{[Console]::Beep($f,$ms)} }
}

$W=10;$H=20
$field=@(); for($y=0;$y-lt$H;$y++){$r=@();for($x=0;$x-lt$W;$x++){$r+=0};$field+=@(,$r)}

$pieces=@(
  @(@(0,0,0,0),@(1,1,1,1),@(0,0,0,0),@(0,0,0,0)),
  @(@(1,1),@(1,1)),
  @(@(0,1,0),@(1,1,1),@(0,0,0)),
  @(@(0,1,1),@(1,1,0),@(0,0,0)),
  @(@(1,1,0),@(0,1,1),@(0,0,0)),
  @(@(1,0,0),@(1,1,1),@(0,0,0)),
  @(@(0,0,1),@(1,1,1),@(0,0,0))
)

function Rot([array]$p){$h=$p.Length;$w=$p[0].Length;$rr=@();for($y=0;$y-lt$w;$y++){$row=@();for($x=0;$x-lt$h;$x++){$row+=$p[$h-1-$x][$y]};$rr+=@(,$row)};return ,$rr}
function Can([array]$p,[int]$px,[int]$py){$h=$p.Length;$w=$p[0].Length;for($y=0;$y-lt$h;$y++){for($x=0;$x-lt$w;$x++){if($p[$y][$x]-ne0){$nx=$px+$x;$ny=$py+$y;if($nx-lt0-or$nx-ge$W-or$ny-ge$H){return $false};if($ny-ge0-and$field[$ny][$nx]-ne0){return $false}}}};return $true}
function Merge([array]$p,[int]$px,[int]$py){$h=$p.Length;$w=$p[0].Length;for($y=0;$y-lt$h;$y++){for($x=0;$x-lt$w;$x++){if($p[$y][$x]-ne0){$field[$py+$y][$px+$x]=1}}}}
function ClearLines{$new=@();for($y=$H-1;$y-ge0;$y--){$full=$true;for($x=0;$x-lt$W;$x++){if($field[$y][$x]-eq0){$full=$false;break}};if(-not$full){$new=@(,$field[$y])+$new}};while($new.Count-lt$H){$row=@();for($x=0;$x-lt$W;$x++){$row+=0};$new=@(,$row)+$new};$field=$new}
function Draw{[Console]::Clear();Write-At 0 0 "+----------+";for($y=0;$y-lt$H;$y++){$line="|";for($x=0;$x-lt$W;$x++){if($field[$y][$x]-eq1){$line+="#" }else{$line+=" "}};$line+="|";Write-At 0($y+1)$line};Write-At 0($H+1)"+----------+";Write-At 12 2 "TETRIS PS";Write-At 12 4 "←→↓ SPACE/UP ROT";Write-At 12 6 "Q QUIT"}

function Play {
  Hide-Cursor
  $idx=Get-Random -Max $pieces.Count;$cur=,($pieces[$idx]);$px=3;$py=0;$last=[DateTime]::Now;$speed=300
  $nt=0
  while($true){
    if((-not $NoAudio) -and $notes.Count -gt 0){
      $elapsed=([DateTime]::Now - $last).TotalMilliseconds
      if($elapsed -gt $speed*0.3 -and $nt -lt $notes.Count){
        $n=$notes[$nt];$nt++; if($nt -ge $notes.Count){$nt=0}
        BeepTone $n.f $n.d
      }
    }
    if(([DateTime]::Now - $last).TotalMilliseconds -gt $speed){
      if(Can $cur $px ($py+1)){$py++}else{
        Merge $cur $px $py; ClearLines; $idx=Get-Random -Max $pieces.Count;$cur=,($pieces[$idx]);$px=3;$py=0; if(-not(Can $cur $px $py)){break}
      }
      Draw; $last=[DateTime]::Now
    }
    if([Console]::KeyAvailable){
      $k=[Console]::ReadKey($true)
      switch($k.Key){
        'LeftArrow'{if(Can $cur ($px-1)$py){$px--;Draw}}
        'RightArrow'{if(Can $cur ($px+1)$py){$px++;Draw}}
        'DownArrow'{if(Can $cur $px ($py+1)){$py++;Draw}}
        'UpArrow'{$nr=Rot $cur; if(Can $nr $px $py){$cur=$nr}}
        'Spacebar'{while(Can $cur $px ($py+1)){$py++};Draw}
        'Q'{Show-Cursor;exit}
        'Escape'{Show-Cursor;exit}
      }
    }
    [Threading.Thread]::Sleep(10)
  }
  Show-Cursor; Write-At 0 ($H+3) "GAME OVER"
}

Play

