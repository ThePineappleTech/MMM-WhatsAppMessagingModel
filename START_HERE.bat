@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title MMM - Moving Messaging Model
set "PYTHONUTF8=1"

rem ================================================================
rem  MMM - double-click this file. First run sets everything up.
rem ================================================================

rem ---- 1. Find Python (3.12 preferred) --------------------------------
set "PY="
py -3.12 -c "import sys" >nul 2>nul && set "PY=py -3.12"
if not defined PY py -3 -c "import sys" >nul 2>nul && set "PY=py -3"
if not defined PY python -c "import sys" >nul 2>nul && set "PY=python"
if not defined PY goto :nopython

rem ---- 2. Private Python environment + packages ------------------------
rem      First run: create it. Every run: if a package is missing (e.g. requirements.txt
rem      changed since the last run), install the missing ones automatically.
if exist ".venv\Scripts\python.exe" goto :checkpkgs
echo.
echo  First run: setting up MMM. This takes a few minutes and needs internet.
echo.
%PY% -m venv .venv
if errorlevel 1 goto :fail
".venv\Scripts\python.exe" -m pip install --upgrade pip --quiet

:checkpkgs
".venv\Scripts\python.exe" -c "import pandas, numpy, sklearn, boto3, cryptography, snowflake.connector, dotenv" >nul 2>nul
if not errorlevel 1 goto :keys
echo.
echo  Installing / updating packages ...
echo.
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto :fail
echo.
echo  Setup complete.

rem ---- 3. AWS keys (used only to fetch the Snowflake key from S3) ----
:keys
set "VPY=.venv\Scripts\python.exe"
if exist ".env" goto :menu
copy ".env.example" ".env" >nul
echo.
echo  Notepad is opening the .env file. Paste the two AWS keys after the = signs
echo  and SAVE the file. Ask the project owner for the keys.
start "" notepad ".env"
echo.
echo  When the keys are saved, come back to this window and press any key.
pause >nul

rem ---- 4. Menu ---------------------------------------------------------
:menu
cls
echo.
echo   MMM - Moving Messaging Model
echo   ============================
echo.
echo   1  Check everything works      packages, keys, Snowflake login, MMM tables
echo   2  Daily health checks         today's pool, picks and must-be-zero checks
echo   3  Retrain - trial run         trains and compares, writes NOTHING to Snowflake
echo   4  Retrain - for real          monthly: publishes a new model only if it passes the gate
echo   5  Set up Snowflake objects    tables, registry, weights, views - safe to re-run
echo   6  Open the README
echo   7  Edit the AWS keys (.env)
echo   0  Exit
echo.
set "choice="
set /p "choice=  Choose a number and press Enter: "

if "%choice%"=="1" "%VPY%" test_connection.py & goto :done
if "%choice%"=="2" "%VPY%" MMM_run_sql.py checks & goto :done
if "%choice%"=="3" "%VPY%" MMM_auto_retrain.py --dry-run & goto :done
if "%choice%"=="4" goto :retrain
if "%choice%"=="5" "%VPY%" MMM_run_sql.py setup & goto :done
if "%choice%"=="6" start "" "README.md" & goto :menu
if "%choice%"=="7" start "" notepad ".env" & goto :menu
if "%choice%"=="0" goto :eof
goto :menu

:retrain
echo.
echo  This retrains the model on the latest data and, if the new model passes the gate,
echo  makes it the live model for tomorrow's 10:30 pick.
set "confirm="
set /p "confirm=  Type YES to continue: "
if /i not "%confirm%"=="YES" goto :menu
"%VPY%" MMM_auto_retrain.py
goto :done

:done
echo.
pause
goto :menu

:nopython
echo.
echo  Python was not found.
echo  Install Python 3.12 from https://www.python.org/downloads/
echo  and tick "Add python.exe to PATH" on the first screen of the installer.
echo  Then double-click START_HERE.bat again.
echo.
pause
goto :eof

:fail
echo.
echo  Setup failed - see the messages above. Common causes: no internet, or a company
echo  proxy blocking pip. Delete the .venv folder and try again, or ask IT.
echo.
pause
goto :eof
