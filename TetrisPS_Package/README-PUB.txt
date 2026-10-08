Tetris PS pronto.

Arquivo: tetrisps-repo.zip (repositório Git para publicar em https://github.com/brunohenriquegardanimonteiro/tetrisps)
Conteúdo: tetris.ps1 (jogo completo + mini tema Korobeiniki 8-bit via [Console]::Beep), README.md, LICENSE, CHANGELOG.md, .gitignore, bootstrap.ps1, .github/workflows/selftest.yml

One-liner (após publicar repo tetrisps):
irm https://raw.githubusercontent.com/brunohenriquegardanimonteiro/tetrisps/main/bootstrap.ps1 | iex
irm https://raw.githubusercontent.com/brunohenriquegardanimonteiro/tetrisps/main/bootstrap.ps1 | iex -NoAudio

Rodar local:
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tetris.ps1

Controles: ←→↓ ↑/ESPAÇO rotaciona, Q/ESC sai
