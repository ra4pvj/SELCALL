"""Проверка совместимости с Windows 7: ищет в DLL/PYD/EXE импорты функций и библиотек,
которых нет в Windows 7 SP1. Запуск: python check_win7.py <папка или файл> ..."""
import os
import sys

import pefile

# функции kernel32/advapi32, появившиеся только в Windows 8+
WIN8_FUNCS = {
    "GetSystemTimePreciseAsFileTime", "CreateFile2", "GetCurrentThreadStackLimits", "CopyFile2",
    "GetProcessMitigationPolicy", "SetProcessMitigationPolicy", "PrefetchVirtualMemory",
    "GetFirmwareType", "SetThreadInformation", "GetThreadInformation", "WaitOnAddress",
    "WakeByAddressSingle", "WakeByAddressAll", "GetOverlappedResultEx", "CreateFileMappingFromApp",
    "MapViewOfFileFromApp", "VirtualAllocFromApp", "GetPackageFamilyName", "GetCurrentPackageId",
    "SetThreadDescription", "GetThreadDescription", "DiscardVirtualMemory", "OfferVirtualMemory",
    "GetSystemCpuSetInformation", "GetProcessInformation", "SetProcessInformation",
}
# библиотеки, которых нет в Windows 7
WIN8_DLLS = ("api-ms-win-core-path-", "api-ms-win-core-winrt", "api-ms-win-core-synch-l1-2",
             "api-ms-win-core-file-l1-2-1", "api-ms-win-core-file-l2-1", "api-ms-win-shcore",
             "api-ms-win-core-libraryloader-l1-2-1", "api-ms-win-core-processthreads-l1-1-3",
             "api-ms-win-core-sysinfo-l1-2", "bcryptprimitives", "shcore.dll")


def files(paths):
    for p in paths:
        if os.path.isfile(p):
            yield p
        else:
            for d, _, fs in os.walk(p):
                for f in fs:
                    if f.lower().endswith((".dll", ".pyd", ".exe")):
                        yield os.path.join(d, f)


def main():
    bad = []
    crt = set()
    n = 0
    for f in files(sys.argv[1:]):
        try:
            pe = pefile.PE(f, fast_load=True)
            pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"],
                                                   pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT"]])
        except Exception:
            continue
        n += 1
        entries = list(getattr(pe, "DIRECTORY_ENTRY_IMPORT", [])) + \
            [(e) for e in getattr(pe, "DIRECTORY_ENTRY_DELAY_IMPORT", [])]
        for e in entries:
            dll = e.dll.decode(errors="replace").lower()
            if dll.startswith("api-ms-win-crt") or dll == "ucrtbase.dll":
                crt.add(os.path.basename(f))
            if any(dll.startswith(w) for w in WIN8_DLLS):
                bad.append("%s: импорт %s" % (f, dll))
            for imp in e.imports:
                name = imp.name.decode(errors="replace") if imp.name else ""
                if name in WIN8_FUNCS:
                    bad.append("%s: %s!%s" % (f, dll, name))
    print("Проверено файлов: %d" % n)
    print("Используют UCRT (нужен ucrtbase/api-ms-win-crt рядом или KB2999226): %d" % len(crt))
    if bad:
        print("НЕСОВМЕСТИМО С WINDOWS 7:")
        for b in sorted(set(bad)):
            print("  " + b)
        sys.exit(1)
    print("Функций и библиотек Windows 8+ не найдено — WIN7 OK")


if __name__ == "__main__":
    main()
