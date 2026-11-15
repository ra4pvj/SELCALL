@echo off
rem Сборка HFSelcall.exe (один файл) для Windows 7 SP1 и новее.
rem Нужен Python 3.8 (https://www.python.org/downloads/release/python-3810/), 64- или 32-битный.
cd /d "%~dp0"
py -3.8 -m pip install -r requirements-win7.txt pyinstaller==5.13.2
py -3.8 -m PyInstaller --noconfirm --onefile --windowed --name HFSelcall ^
    --paths ..\python --collect-all sounddevice --collect-all _sounddevice_data ^
    hfselcall_win.py
echo.
echo Готово: dist\HFSelcall.exe
pause
