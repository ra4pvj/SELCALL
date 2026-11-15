@echo off
rem Builds the folder dist\HFSelcall (HFSelcall.exe + libraries) for Windows 7 SP1 and newer.
rem Requires Python 3.8 (https://www.python.org/downloads/release/python-3810/), 32 or 64 bit to match the PC.
cd /d "%~dp0"
py -3.8 -m pip install -r requirements-win7.txt pyinstaller==5.13.2
py -3.8 -m PyInstaller --noconfirm --onedir --windowed --name HFSelcall ^
    --paths ..\python --collect-all sounddevice --collect-all _sounddevice_data ^
    --hidden-import selcall_ptt --hidden-import serial.tools.list_ports ^
    hfselcall_win.py
echo.
echo Done: dist\HFSelcall\HFSelcall.exe
pause
