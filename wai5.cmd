@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: ======================================================================
:: Декларация среды: Universal AI Router (Hybrid Mode)
:: Инженерная инициатива: Прямой вызов модулей (python -m) для обхода 
:: жестко зашитых путей в pip-обертках. Принудительное удержание окна.
:: ======================================================================

set "VPS_IP=77.1107.63"
set "PROXY_PORT=20128"
set "API_BASE_URL=http://!VPS_IP!:%PROXY_PORT%/v1"
set "API_KEY=sk-51efcc9f4212b043-3-6a986a69"

set "RAND_ID=%RANDOM%"
set "TMP_ANTHROPIC=%TEMP%\usb_anth_!RAND_ID!.json"
set "TMP_OPENAI=%TEMP%\usb_oai_!RAND_ID!.json"
set "TMP_TXT=%TEMP%\usb_list_!RAND_ID!.txt"

echo [%DATE% %TIME%] [INFO] Инициализация среды маршрутизации...

:: ==========================================
:: ЭТАП 1: Гибридная настройка путей (PATH)
:: ==========================================
:: Переменная %~dp0 динамически подстраивается под текущую букву диска (I:, G: и т.д.)
set "PORTABLE_WPY=%~dp0AiderEnv\WPy64-31180"
set "PORTABLE_GIT=%~dp0AiderEnv\PortableGit"

if exist "!PORTABLE_WPY!" (
    echo [%DATE% %TIME%] [INFO] Обнаружена портативная среда. Подключение...
    for /d %%I in ("!PORTABLE_WPY!\python*") do (
        if exist "%%I\python.exe" (
            set "PATH=%%I;%%I\Scripts;!PATH!"
        )
    )
    if exist "!PORTABLE_GIT!\cmd\git.exe" (
        set "PATH=!PORTABLE_GIT!\cmd;!PATH!"
    )
) else (
    echo [%DATE% %TIME%] [INFO] Портативная среда не найдена. Режим системного хоста.
)

:: ==========================================
:: ЭТАП 2: Поиск агентов в текущем PATH
:: ==========================================
set "HAS_CECLI=0"
set "HAS_AIDER=0"

where cecli >nul 2>nul
if !ERRORLEVEL! equ 0 set "HAS_CECLI=1"

where aider >nul 2>nul
if !ERRORLEVEL! equ 0 set "HAS_AIDER=1"

if "!HAS_CECLI!"=="0" if "!HAS_AIDER!"=="0" goto :err_agent

:: ==========================================
:: ЭТАП 3: Меню выбора инструмента
:: ==========================================
:agent_menu_loop
cls
echo ======================================================================
echo    UNIVERSAL AI ROUTER - ВЫБОР ИНСТРУМЕНТА
echo ======================================================================
if "!HAS_CECLI!"=="1" echo  [1] CECLI-DEV (Обнаружен в системе)
if "!HAS_AIDER!"=="1" echo  [2] Aider (Обнаружен в системе)
echo ======================================================================
echo.
set "AGENT_INPUT="
set /p "AGENT_INPUT=Выберите агента: "

if "!AGENT_INPUT!"=="1" if "!HAS_CECLI!"=="1" goto :set_cecli
if "!AGENT_INPUT!"=="2" if "!HAS_AIDER!"=="1" goto :set_aider
goto :agent_menu_loop

:set_cecli
:: Используем модульный запуск, чтобы обойти сломанные .exe обертки
set "AGENT_CMD=python -m cecli"
set "AGENT_NAME=CECLI-DEV"
goto :fetch_models

:set_aider
:: Используем модульный запуск, чтобы обойти сломанные .exe обертки
set "AGENT_CMD=python -m aider"
set "AGENT_NAME=Aider"
goto :fetch_models

:: ==========================================
:: ЭТАП 4: Опрос OmniRoute
:: ==========================================
:fetch_models
echo [%DATE% %TIME%] [INFO] Опрос агрегатора OmniRoute...
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

:: ==========================================
:: ЭТАП 5: Меню выбора модели
:: ==========================================
:model_menu_loop
cls
echo ======================================================================
echo    OMNIROUTE (!AGENT_NAME!) - ВЫБОР МОДЕЛИ (НАЙДЕНО: !MODEL_COUNT!)
echo ======================================================================
for /l %%x in (1, 1, !MODEL_COUNT!) do (
    echo  [%%x] !MODEL_ID_%%x!
)
echo ======================================================================
echo.
set "USER_INPUT="
set /p "USER_INPUT=Выберите ИИ-модель [1-!MODEL_COUNT!] (По умолчанию [1]): "

if "!USER_INPUT!"=="" set "USER_INPUT=1"

set "VALID_INPUT=0"
for /l %%x in (1, 1, !MODEL_COUNT!) do (
    if "!USER_INPUT!"=="%%x" (
        set "VALID_INPUT=1"
        set "CHOSEN_MODEL=!MODEL_ID_%%x!"
    )
)

if "!VALID_INPUT!"=="0" goto :model_menu_loop
echo [%DATE% %TIME%] [INFO] Выбран шлюз: !CHOSEN_MODEL!

:: ==========================================
:: ЭТАП 6: Изоляция переменных среды и Запуск
:: ==========================================
set "OPENAI_API_BASE=!API_BASE_URL!"
set "OPENAI_API_KEY=!API_KEY!"
set "ANTHROPIC_API_KEY="
set "ANTHROPIC_BASE_URL="

echo [%DATE% %TIME%] [SUCCESS] Маршруты настроены. Передача управления агенту.
echo Нажмите Ctrl+C для безопасного прерывания.
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
    echo [%DATE% %TIME%] [CRITICAL] Процесс завершился с кодом ошибки: !EXIT_CODE!
)
goto :final_exit

:: ======================================================================
:: Обработчики ошибок
:: ======================================================================
:err_agent
echo [%DATE% %TIME%] [CRITICAL] Агенты не найдены ни в портативной среде, ни в системе.
echo Для работы в глобальном режиме установите агента через Python:
echo   pip install aider-chat
echo   или
echo   pip install cecli-dev
goto :error_exit

:err_no_models
echo [%DATE% %TIME%] [CRITICAL] Пустой список моделей от OmniRoute.
goto :error_exit

:error_exit
set "EXIT_CODE=1"
:: Специальная пауза для ошибок ДО завершения среды
pause

:final_exit
echo [%DATE% %TIME%] [INFO] Очистка временных файлов...
if exist "!TMP_ANTHROPIC!" del /Q "!TMP_ANTHROPIC!"
if exist "!TMP_OPENAI!" del /Q "!TMP_OPENAI!"
if exist "!TMP_TXT!" del /Q "!TMP_TXT!"

echo [%DATE% %TIME%] [INFO] Сессия полностью завершена.
:: ГАРАНТИРОВАННАЯ ПАУЗА. Окно больше не закроется само по себе.
pause
endlocal
exit /b %EXIT_CODE%
