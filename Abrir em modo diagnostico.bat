@echo off
title Optimizer GBZ - Modo diagnostico
cd /d "%~dp0"
if not exist "%~dp0Optimizer-GBZ.ps1" (
  echo  ERRO: nao achei o Optimizer-GBZ.ps1. Extraia o ZIP antes de abrir.
  pause
  exit /b
)
echo Abrindo em MODO DIAGNOSTICO: uma janela preta vai mostrar os erros.
echo Se der problema, tire um print desta janela e envie na aba Issues do GitHub do projeto.
echo.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Optimizer-GBZ.ps1" -Diag
pause
