# DICOM Viewer Backend

## Запуск сервера

### Способ 1: Через batch файл (Windows)
1. Дважды кликните на `start_server.bat`
2. Сервер запустится на http://127.0.0.1:8000

### Способ 2: Через командную строку
```bash
# Установка зависимостей
pip install -r requirements.txt

# Запуск сервера
python main.py
```

### Способ 3: Через uvicorn
```bash
uvicorn main:app --host 127.0.0.1 --port 8000 --reload
```

## Проверка работы
После запуска откройте в браузере: http://127.0.0.1:8000/docs

## Эндпоинты
- `POST /process_dicom/` - загрузка и обработка DICOM файла
- `POST /update_wl/` - обновление Window/Level и яркости
