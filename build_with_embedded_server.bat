@echo off
echo ========================================
echo Сборка DICOM Viewer с встроенным сервером
echo ========================================

echo.
echo 1. Проверка Flutter...
flutter --version
if %errorlevel% neq 0 (
    echo ОШИБКА: Flutter не найден! Установите Flutter и добавьте в PATH.
    pause
    exit /b 1
)

echo.
echo 2. Проверка Python...
python --version
if %errorlevel% neq 0 (
    echo ОШИБКА: Python не найден! Установите Python 3.8+ и добавьте в PATH.
    pause
    exit /b 1
)

echo.
echo 3. Установка зависимостей Flutter...
flutter pub get
if %errorlevel% neq 0 (
    echo ОШИБКА: Не удалось установить зависимости Flutter!
    pause
    exit /b 1
)

echo.
echo 4. Сборка Windows приложения...
flutter build windows --release
if %errorlevel% neq 0 (
    echo ОШИБКА: Не удалось собрать приложение!
    pause
    exit /b 1
)

echo.
echo 5. Создание папки для распространения...
if exist "release" rmdir /s /q "release"
mkdir "release"

echo.
echo 6. Копирование файлов приложения...
xcopy "build\windows\x64\runner\Release\*" "release\" /E /I /Y

echo.
echo 7. Создание инструкции для пользователя...
echo # DICOM Pathology Viewer > "release\README.txt"
echo. >> "release\README.txt"
echo Это приложение содержит встроенный Python сервер. >> "release\README.txt"
echo. >> "release\README.txt"
echo ТРЕБОВАНИЯ: >> "release\README.txt"
echo - Python 3.8 или выше должен быть установлен в системе >> "release\README.txt"
echo - Python должен быть доступен из командной строки (добавлен в PATH) >> "release\README.txt"
echo. >> "release\README.txt"
echo УСТАНОВКА ЗАВИСИМОСТЕЙ PYTHON: >> "release\README.txt"
echo 1. Откройте командную строку в папке с приложением >> "release\README.txt"
echo 2. Выполните: pip install -r server\requirements.txt >> "release\README.txt"
echo. >> "release\README.txt"
echo ЗАПУСК: >> "release\README.txt"
echo Просто запустите flutter_application_1.exe >> "release\README.txt"
echo. >> "release\README.txt"
echo При первом запуске приложение автоматически: >> "release\README.txt"
echo - Создаст встроенный Python сервер >> "release\README.txt"
echo - Установит необходимые зависимости >> "release\README.txt"
echo - Запустит сервер на порту 8000 >> "release\README.txt"

echo.
echo 8. Создание скрипта установки зависимостей Python...
echo @echo off > "release\install_python_deps.bat"
echo echo Установка зависимостей Python для DICOM Viewer... >> "release\install_python_deps.bat"
echo pip install -r server\requirements.txt >> "release\install_python_deps.bat"
echo echo. >> "release\install_python_deps.bat"
echo echo Готово! Теперь можно запускать приложение. >> "release\install_python_deps.bat"
echo pause >> "release\install_python_deps.bat"

echo.
echo ========================================
echo СБОРКА ЗАВЕРШЕНА УСПЕШНО!
echo ========================================
echo.
echo Файлы находятся в папке: release\
echo.
echo Для распространения:
echo 1. Скопируйте всю папку release\ на целевой компьютер
echo 2. Убедитесь, что Python установлен на целевом компьютере
echo 3. Запустите install_python_deps.bat для установки зависимостей
echo 4. Запустите flutter_application_1.exe
echo.
echo Размер папки release: 
dir "release" /s /-c | find "File(s)"
echo.
pause
