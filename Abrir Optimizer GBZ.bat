@echo off
title Optimizer GBZ
cd /d "%~dp0"
if not exist "%~dp0Optimizer-GBZ.ps1" (
  echo.
  echo  ERRO: nao achei o arquivo Optimizer-GBZ.ps1 nesta pasta.
  echo.
  echo  Voce provavelmente abriu direto de dentro do ZIP.
  echo  Clique com o botao direito no ZIP, escolha "Extrair tudo"
  echo  e abra este .bat de dentro da pasta extraida.
  echo.
  pause
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%~dp0Optimizer-GBZ.ps1'" 2>nul
echo Abrindo o Optimizer GBZ... clique em "Sim" na janela de permissao.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Optimizer-GBZ.ps1"
exit
