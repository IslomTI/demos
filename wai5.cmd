@echo off
setlocal enabledelayedexpansion

REM ======================================================================
REM Environment: Universal AI Router (Hybrid Mode)
REM Engineering Initiative: Strict ASCII/English to prevent byte-shifting.
REM Native module execution via python -m.
REM ======================================================================

set "VPS_IP=77.110.117.63"
set "PROXY_PORT=20128"
set "API_BASE_URL=http://!VPS_IP!:%PROXY_PORT%/v1"
set "API_KEY=sk-51efcc9f4212b043-3ed376-6a986a69"

set "RAND_ID=%RANDOM%"
set "TMP_ANTHROPIC=%TEMP%\usb_anth_!RAND_ID!.json"
set "TMP_OPENAI=%TEMP%\usb_oai_!RAND_ID!.json"
set "TMP_TXT=%TEMP%\usb_list_!RAND_ID!.txt"

echo [%DATE% %TIME%] [INFO] Initializing routing environment...

REM ==========================================
REM STAGE 1: Hybrid PATH Resolution
REM ==========================================
set "PORTABLE_WPY=%~dp0AiderEnv\WPy64-31180"
set "PORTABLE_GIT=%~dp0AiderEnv\PortableGit"

if exist "!PORTABLE_WPY!" (
    echo [%DATE% %TIME%] [INFO] Portable environment detected. Connecting...
    for /d %%I in ("!PORTABLE_WPY!\python*") do (
        if exist "%%I\python.exe" (
            set "PATH=%%I;%%I\Scripts;!PATH!"
        )
    )
    if exist "!PORTABLE_GIT!\cmd\git.exe" (
        set "PATH=!PORTABLE_GIT!\cmd;!PATH!"
    )
) else (
    echo [%DATE% %TIME%] [INFO] Portable env NOT found. Using Host OS mode.
)

REM ==========================================
REM STAGE 2: Agent Discovery
REM ==========================================
set "HAS_CECLI=0"
set "HAS_AIDER=0"

where cecli >nul 2>nul
if !ERRORLEVEL! equ 0 set "HAS_CECLI=1"

where aider >nul 2>nul
if !ERRORLEVEL! equ 0 set "HAS_AIDER=1"

if "!HAS_CECLI!"=="0" if "!HAS_AIDER!"=="0" goto :err_agent

REM ==========================================
REM STAGE 3: Agent Menu
REM ==========================================
:agent_menu_loop
cls
echo ======================================================================
echo    UNIVERSAL AI ROUTER - SELECT TOOL
echo ======================================================================
if "!HAS_CECLI!"=="1" echo  [1] CECLI-DEV (Detected)
if "!HAS_AIDER!"=="1" echo  [2] Aider (Detected)
echo ======================================================================
echo.
set "AGENT_INPUT="
set /p "AGENT_INPUT=Select agent [1-2]: "

if "!AGENT_INPUT!"=="1" if "!HAS_CECLI!"=="1" goto :set_cecli
if "!AGENT_INPUT!"=="2" if "!HAS_AIDER!"=="1" goto :set_aider
goto :agent_menu_loop

:set_cecli
set "AGENT_CMD=python -m cecli"
set "AGENT_NAME=CECLI-DEV"
goto :fetch_models

:set_aider
set "AGENT_CMD=python -m aider"
set "AGENT_NAME=Aider"
goto :fetch_models

REM ==========================================
REM STAGE 4: OmniRoute Fetch
REM ==========================================
:fetch_models
echo [%DATE% %TIME%] [INFO] Polling OmniRoute aggregator...
curl.exe -s -X GET "!API_BASE_URL!/models" -H "x-api-key: !API_KEY!" -H "anthropic-version: 2023-06-01" > "!TMP_ANTHROPIC!"
curl.exe -s -X GET "!API_BASE_URL!/models" -H "Authorization: Bearer !API_KEY!" > "!TMP_OPENAI!"

powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $out=@(); $j1=ConvertFrom-Json (Get-Content '!TMP_ANTHROPIC!' -Raw); if($j1.data){$out+=$j1.data|ForEach-Object{$_.id}}; $j2=ConvertFrom-Json (Get-Content '!TMP_OPENAI!' -Raw); if($j2.data){$out+=$j2.data|ForEach-Object{$_.id}}; $out | Select-Object -Unique | Sort-Object | Out-File '!TMP_TXT!' -Encoding ascii"

set "MODEL_COUNT=0"
for /f "usebackq tokens=*" %%i in ("!TMP_TXT!") do (
    set "VAL=%%i"
    set "VAL=!VAL: =!"
    if not "!VAL!"=="" (
        set /a "MODEL_COUNT+=1"
        set "MODEL_ID_!MODEL_COUNT!=!VAL!"
    )
)

if "!MODEL_COUNT!"=="0" goto :err_no_models

REM ==========================================
REM STAGE 5: Model Menu
REM ==========================================
:model_menu_loop
cls
echo ======================================================================
echo    OMNIROUTE (!AGENT_NAME!) - SELECT MODEL (FOUND: !MODEL_COUNT!)
echo ======================================================================
for /l %%x in (1, 1, !MODEL_COUNT!) do (
    echo  [%%x] !MODEL_ID_%%x!
)
echo ======================================================================
echo.
set "USER_INPUT="
set /p "USER_INPUT=Select ID [1-!MODEL_COUNT!] (Default [1]): "

if "!USER_INPUT!"=="" set "USER_INPUT=1"

set "VALID_INPUT=0"
for /l %%x in (1, 1, !MODEL_COUNT!) do (
    if "!USER_INPUT!"=="%%x" (
        set "VALID_INPUT=1"
        set "CHOSEN_MODEL=!MODEL_ID_%%x!"
    )
)

if "!VALID_INPUT!"=="0" goto :model_menu_loop
echo [%DATE% %TIME%] [INFO] Selected route: !CHOSEN_MODEL!

REM ==========================================
REM STAGE 6: Environment Isolation and Launch
REM ==========================================
set "OPENAI_API_BASE=!API_BASE_URL!"
set "OPENAI_API_KEY=!API_KEY!"
set "ANTHROPIC_API_KEY="
set "ANTHROPIC_BASE_URL="

echo [%DATE% %TIME%] [SUCCESS] Routes configured. Handing over to agent.
echo Press Ctrl+C for safe interrupt (SIGINT).
echo ----------------------------------------------------------------------

if "!AGENT_NAME!"=="CECLI-DEV" goto :run_cecli_agent
goto :run_aider_agent

:run_cecli_agent
!AGENT_CMD! --model "openai/!CHOSEN_MODEL!"
goto :end_agent

:run_aider_agent
!AGENT_CMD! --model "openai/!CHOSEN_MODEL!" --no-show-model-warnings
goto :end_agent

:end_agent
set "EXIT_CODE=%ERRORLEVEL%"
echo ----------------------------------------------------------------------
if !EXIT_CODE! neq 0 (
    echo [%DATE% %TIME%] [CRITICAL] Process exited with error code: !EXIT_CODE!
)
goto :final_exit

REM ======================================================================
REM Error Handlers
REM ======================================================================
:err_agent
echo [%DATE% %TIME%] [CRITICAL] No agents found in portable env or system PATH.
echo Please run: pip install aider-chat
goto :error_exit

:err_no_models
echo [%DATE% %TIME%] [CRITICAL] Empty model list returned from OmniRoute.
goto :error_exit

:error_exit
set "EXIT_CODE=1"
pause

:final_exit
echo [%DATE% %TIME%] [INFO] Cleaning up temporary files...
if exist "!TMP_ANTHROPIC!" del /Q "!TMP_ANTHROPIC!"
if exist "!TMP_OPENAI!" del /Q "!TMP_OPENAI!"
if exist "!TMP_TXT!" del /Q "!TMP_TXT!"

echo [%DATE% %TIME%] [INFO] Session terminated safely.
pause
endlocal
exit /b %EXIT_CODE%
