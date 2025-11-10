import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

class EmbeddedServerService {
  static Process? _serverProcess;
  static bool _isRunning = false;
  static String? _serverUrl;
  
  // URL сервера
  static String get serverUrl => _serverUrl ?? 'http://127.0.0.1:8000';
  
  // Проверка, запущен ли сервер
  static bool get isRunning => _isRunning;
  
  // Запуск встроенного сервера
  static Future<bool> startServer() async {
    if (_isRunning) return true;
    
    try {
      print('Запуск встроенного Python сервера...');
      
      // Получаем путь к директории приложения
      final appDir = await getApplicationDocumentsDirectory();
      final serverDir = Directory('${appDir.path}/server');
      
      // Создаем директорию сервера если её нет
      if (!await serverDir.exists()) {
        await serverDir.create(recursive: true);
        print('Создана директория сервера: ${serverDir.path}');
      }
      
      // Путь к Python скрипту
      final serverScript = File('${serverDir.path}/main.py');
      
      // Всегда обновляем файлы сервера, чтобы гарантировать актуальные эндпоинты (например, /export_dicom/)
      await _createServerFiles(serverDir);
      // Устанавливаем зависимости Python (идемпотентно)
      await _installPythonDependencies(serverDir);
      
      // Запускаем Python сервер
      _serverProcess = await Process.start(
        'python',
        ['${serverDir.path}/main.py'],
        workingDirectory: serverDir.path,
      );
      
      // Обработка вывода сервера (устойчиво к невалидной UTF-8)
      _serverProcess!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
        (data) {
          print('Server stdout: $data');
        },
        onError: (e, st) {
          print('Server stdout decode error: $e');
        },
        cancelOnError: false,
      );

      _serverProcess!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
        (data) {
          print('Server stderr: $data');
        },
        onError: (e, st) {
          print('Server stderr decode error: $e');
        },
        cancelOnError: false,
      );
      
      // Ждем немного, чтобы сервер запустился
      await Future.delayed(const Duration(seconds: 3));

      // Пробуем несколько портов (совместимость со старыми скриптами)
      final candidatePorts = [8000, 8010];
      for (final port in candidatePorts) {
        final url = 'http://127.0.0.1:$port';
        if (await _checkServerHealth(urlOverride: url)) {
          _isRunning = true;
          _serverUrl = url;
          print('Встроенный сервер успешно запущен на $_serverUrl');
          return true;
        }
      }

      print('Ошибка: сервер не отвечает');
      await stopServer();
      return false;
      
    } catch (e) {
      print('Ошибка запуска встроенного сервера: $e');
      return false;
    }
  }
  
  // Остановка сервера
  static Future<void> stopServer() async {
    if (_serverProcess != null) {
      print('Остановка встроенного сервера...');
      _serverProcess!.kill();
      await _serverProcess!.exitCode;
      _serverProcess = null;
    }
    _isRunning = false;
    _serverUrl = null;
    print('Встроенный сервер остановлен');
  }
  
  // Проверка здоровья сервера
  static Future<bool> _checkServerHealth({String? urlOverride}) async {
    try {
      final client = HttpClient();
      final targetUrl = urlOverride ?? '$serverUrl/';
      final request = await client.getUrl(Uri.parse('$targetUrl/'));
      final response = await request.close();
      client.close();
      return response.statusCode == 200;
    } catch (e) {
      print('Ошибка проверки здоровья сервера: $e');
      return false;
    }
  }
  
  // Создание файлов сервера
  static Future<void> _createServerFiles(Directory serverDir) async {
    print('Создание файлов встроенного сервера...');
    
    // Создаем main.py
    final mainPy = File('${serverDir.path}/main.py');
    await mainPy.writeAsString('''
import os
import sys
import base64
import json
from flask import Flask, request, jsonify
from flask_cors import CORS
import pydicom
import numpy as np
from PIL import Image
import io

app = Flask(__name__)
CORS(app)

def _safe_str(value):
    try:
        return str(value)
    except Exception:
        try:
            return value.decode('utf-8', errors='ignore')
        except Exception:
            return ''

def extract_basic_tags(ds):
    tags = {}
    def put(key, attr, default=''):
        tags[key] = _safe_str(getattr(ds, attr, default))
    put('PatientName', 'PatientName')
    put('PatientID', 'PatientID')
    put('StudyDate', 'StudyDate')
    put('StudyTime', 'StudyTime')
    put('Modality', 'Modality')
    put('StudyDescription', 'StudyDescription')
    put('SeriesDescription', 'SeriesDescription')
    put('InstitutionName', 'InstitutionName')
    put('Manufacturer', 'Manufacturer')
    put('BodyPartExamined', 'BodyPartExamined')
    put('StudyInstanceUID', 'StudyInstanceUID')
    put('SeriesInstanceUID', 'SeriesInstanceUID')
    put('SOPInstanceUID', 'SOPInstanceUID')
    # Dimensions
    tags['Rows'] = _safe_str(getattr(ds, 'Rows', ''))
    tags['Columns'] = _safe_str(getattr(ds, 'Columns', ''))
    # Pixel spacing (будет перезаписан после вычисления с правильной логикой)
    # Здесь оставляем базовое извлечение, но оно будет обновлено позже
    ps = getattr(ds, 'PixelSpacing', None)
    if ps is not None:
        try:
            tags['PixelSpacing'] = f"{float(ps[0])} / {float(ps[1])}"
        except Exception:
            tags['PixelSpacing'] = _safe_str(ps)
    # Additional exposure info
    for name in ['SliceThickness', 'KVP', 'ExposureTime', 'XRayTubeCurrent', 'Exposure']:
        if hasattr(ds, name):
            tags[name] = _safe_str(getattr(ds, name))
    return tags

def extract_report(ds):
    # Try common text fields
    for attr in [
        'ImageComments',
        'StudyComments',
        'ClinicalInformation',
        'AdditionalPatientHistory',
        'ReasonForRequestedProcedure',
        'RequestedProcedureDescription',
        'AdmittingDiagnosesDescription',
        'DiagnosisDescription',
    ]:
        if hasattr(ds, attr):
            val = _safe_str(getattr(ds, attr))
            if val:
                return val
    # Very simple SR traversal
    try:
        if hasattr(ds, 'ContentSequence'):
            items = []
            def walk(seq):
                for item in seq:
                    vt = _safe_str(getattr(item, 'ValueType', ''))
                    if vt == 'TEXT' and hasattr(item, 'TextValue'):
                        items.append(_safe_str(item.TextValue))
                    if hasattr(item, 'ContentSequence'):
                        walk(item.ContentSequence)
            walk(ds.ContentSequence)
            if items:
                return "\n".join(items)
    except Exception:
        pass
    return ''

def process_dicom_file(file_bytes, filename):
    """Обработка DICOM файла"""
    try:
        # Создаем временный файл
        temp_path = f"temp_{filename}"
        with open(temp_path, 'wb') as f:
            f.write(file_bytes)
        
        # Читаем DICOM
        ds = pydicom.dcmread(temp_path)
        
        # Извлекаем данные
        pixel_array = ds.pixel_array
        
        # Нормализация для изображения
        if hasattr(ds, 'WindowCenter') and hasattr(ds, 'WindowWidth'):
            window_center = float(ds.WindowCenter) if isinstance(ds.WindowCenter, (int, float)) else float(ds.WindowCenter[0])
            window_width = float(ds.WindowWidth) if isinstance(ds.WindowWidth, (int, float)) else float(ds.WindowWidth[0])
        else:
            window_center = pixel_array.mean()
            window_width = pixel_array.std() * 4
        
        # Применяем window/level
        min_val = window_center - window_width / 2
        max_val = window_center + window_width / 2
        pixel_array = np.clip(pixel_array, min_val, max_val)
        pixel_array = ((pixel_array - min_val) / (max_val - min_val) * 255).astype(np.uint8)
        
        # Конвертируем в PIL Image
        if len(pixel_array.shape) == 3:
            image = Image.fromarray(pixel_array)
        else:
            image = Image.fromarray(pixel_array, mode='L')
        
        # Конвертируем в RGB если нужно
        if image.mode != 'RGB':
            image = image.convert('RGB')
        
        # Конвертируем в base64
        buffer = io.BytesIO()
        image.save(buffer, format='PNG')
        image_base64 = base64.b64encode(buffer.getvalue()).decode('utf-8')
        
        # Получаем метаданные и теги
        patient_name = str(ds.get('PatientName', 'Unknown'))
        
        # Извлекаем PixelSpacing с улучшенной логикой
        pixel_spacing = None
        pixel_spacing_source = "не найден"
        
        # 1. Проверяем стандартный PixelSpacing (0028,0030)
        if hasattr(ds, 'PixelSpacing') and ds.PixelSpacing is not None:
            try:
                ps = ds.PixelSpacing
                if hasattr(ps, '__len__') and len(ps) >= 2:
                    pixel_spacing = [float(ps[0]), float(ps[1])]
                    pixel_spacing_source = "из PixelSpacing"
                    print(f"PixelSpacing найден в файле: {pixel_spacing} мм")
            except Exception as e:
                print(f"Ошибка при извлечении PixelSpacing: {e}")
        
        # 2. Если PixelSpacing отсутствует или равен 1.0, проверяем ImagerPixelSpacing (0018,1164)
        if pixel_spacing is None or (pixel_spacing is not None and len(pixel_spacing) >= 2 and pixel_spacing[0] == 1.0 and pixel_spacing[1] == 1.0):
            if hasattr(ds, 'ImagerPixelSpacing') and ds.ImagerPixelSpacing is not None:
                try:
                    ips = ds.ImagerPixelSpacing
                    if hasattr(ips, '__len__') and len(ips) >= 2:
                        pixel_spacing = [float(ips[0]), float(ips[1])]
                        pixel_spacing_source = "из ImagerPixelSpacing"
                        print(f"ImagerPixelSpacing найден в файле: {pixel_spacing} мм")
                except Exception as e:
                    print(f"Ошибка при извлечении ImagerPixelSpacing: {e}")
        
        # 3. Если все еще нет, используем значение по умолчанию
        if pixel_spacing is None or len(pixel_spacing) < 2:
            pixel_spacing = [1.0, 1.0]
            pixel_spacing_source = "по умолчанию (тег отсутствует в файле)"
            print("Предупреждение: PixelSpacing не найден в DICOM файле, используется значение по умолчанию 1.0 мм")
        
        # Убеждаемся, что значения в мм (если они подозрительно маленькие, возможно они в см)
        if pixel_spacing[0] < 0.5 and pixel_spacing[0] > 0.01:
            print(f"Предупреждение: PixelSpacing подозрительно маленький ({pixel_spacing[0]}), возможно указан в см. Конвертируем в мм (x10).")
            pixel_spacing[0] = pixel_spacing[0] * 10.0
            if len(pixel_spacing) > 1 and pixel_spacing[1] < 0.5 and pixel_spacing[1] > 0.01:
                pixel_spacing[1] = pixel_spacing[1] * 10.0
        
        pixel_spacing_row = float(pixel_spacing[0])
        pixel_spacing_col = float(pixel_spacing[1]) if len(pixel_spacing) > 1 else pixel_spacing_row
        
        print(f"Используемый PixelSpacing для калибровки: {pixel_spacing_row} мм/пиксель (row), {pixel_spacing_col} мм/пиксель (col)")
        
        tags = extract_basic_tags(ds)
        report = extract_report(ds)
        
        # Всегда добавляем/обновляем PixelSpacing в теги для отображения
        # Используем вычисленное значение (может быть из PixelSpacing, ImagerPixelSpacing или по умолчанию)
        # Добавляем пометку об источнике значения
        if pixel_spacing_source == "по умолчанию (тег отсутствует в файле)":
            tags['PixelSpacing'] = f"{pixel_spacing_row:.3f} / {pixel_spacing_col:.3f} мм (по умолчанию, тег отсутствует)"
        else:
            tags['PixelSpacing'] = f"{pixel_spacing_row:.3f} / {pixel_spacing_col:.3f} мм ({pixel_spacing_source})"
        
        # Также добавляем ImagerPixelSpacing, если он был использован
        if hasattr(ds, 'ImagerPixelSpacing') and ds.ImagerPixelSpacing is not None:
            try:
                ips = ds.ImagerPixelSpacing
                if hasattr(ips, '__len__') and len(ips) >= 2:
                    tags['ImagerPixelSpacing'] = f"{float(ips[0]):.3f} / {float(ips[1]):.3f} мм"
            except Exception:
                pass
        
        # Удаляем временный файл
        os.remove(temp_path)
        
        # Отладочный вывод тегов
        print(f"Теги для отправки клиенту: {list(tags.keys())}")
        print(f"PixelSpacing в тегах: {tags.get('PixelSpacing', 'НЕ НАЙДЕН')}")
        
        return {
            'image_base64': image_base64,
            'patient_name': patient_name,
            'pixel_spacing_row': pixel_spacing_row,
            'window_center': window_center,
            'window_width': window_width,
            'tags': tags,
            'report': report,
        }
        
    except Exception as e:
        print(f"Ошибка обработки DICOM: {e}")
        return None

@app.route('/')
def health_check():
    return jsonify({"status": "ok", "message": "Embedded DICOM Server"})

@app.route('/process_dicom/', methods=['POST'])
def process_dicom():
    try:
        if 'file' not in request.files:
            return jsonify({"error": "No file provided"}), 400
        
        file = request.files['file']
        if file.filename == '':
            return jsonify({"error": "No file selected"}), 400
        
        file_bytes = file.read()
        result = process_dicom_file(file_bytes, file.filename)
        
        if result is None:
            return jsonify({"error": "Failed to process DICOM file"}), 500
        
        # Убеждаемся, что теги есть и PixelSpacing присутствует
        if 'tags' not in result or not isinstance(result['tags'], dict):
            result['tags'] = {}
        
        # Принудительно добавляем PixelSpacing, если его нет
        if 'PixelSpacing' not in result['tags'] and 'pixel_spacing_row' in result:
            result['tags']['PixelSpacing'] = f"{result['pixel_spacing_row']:.3f} мм/пиксель"
            print("PixelSpacing принудительно добавлен в теги")
        
        print(f"Отправляем результат с тегами: {list(result.get('tags', {}).keys())}")
        return jsonify(result)
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/update_wl/', methods=['POST'])
def update_wl():
    try:
        data = request.get_json()
        window_center = data.get('window_center', 0)
        window_width = data.get('window_width', 0)
        brightness = data.get('brightness', 1.0)
        
        # Здесь должна быть логика обновления W/L
        # Для простоты возвращаем успех
        return jsonify({"status": "ok"})
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/export_dicom/', methods=['POST'])
def export_dicom():
    """Принимает исходный DICOM файл и metadata (tags/report), возвращает изменённый DICOM base64"""
    try:
        if 'file' not in request.files:
            return jsonify({"error": "No file provided"}), 400
        file = request.files['file']
        file_bytes = file.read()
        meta_json = request.form.get('metadata')
        metadata = json.loads(meta_json) if meta_json else {}

        # Загружаем как DICOM из bytes
        ds = pydicom.dcmread(io.BytesIO(file_bytes), force=True)

        # Применяем report
        report = metadata.get('report', None)
        if report is not None:
            ds.ImageComments = str(report)

        # Применяем теги по словарю {keyword: value}
        from pydicom.datadict import tag_for_keyword
        tags = metadata.get('tags', {}) or {}
        for key, value in tags.items():
            try:
                # Пробуем по ключевому слову DICOM
                tag = tag_for_keyword(key)
                if tag is not None:
                    setattr(ds, key, value)
                else:
                    # Если ключ не стандартный keyword — создаём/обновляем как приватный текстовый элемент в (0x0011,0x0010)-подобном стиле не делаем; просто игнорируем
                    pass
            except Exception:
                pass

        # Сохраняем в память новый DICOM
        out_buf = io.BytesIO()
        ds.save_as(out_buf, write_like_original=False)
        out_bytes = out_buf.getvalue()
        return jsonify({
            'dicom_base64': base64.b64encode(out_bytes).decode('utf-8'),
            'size': len(out_bytes)
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    print("Запуск встроенного DICOM сервера...")
    app.run(host='127.0.0.1', port=8000, debug=False)
''');
    
    // Создаем requirements.txt
    final requirementsTxt = File('${serverDir.path}/requirements.txt');
    await requirementsTxt.writeAsString('''
Flask==2.3.3
Flask-CORS==4.0.0
pydicom==2.4.3
numpy==1.24.3
Pillow==10.0.0
''');
    
    print('Файлы сервера созданы');
  }
  
  // Установка Python зависимостей
  static Future<void> _installPythonDependencies(Directory serverDir) async {
    try {
      print('Установка Python зависимостей...');
      
      final requirementsFile = File('${serverDir.path}/requirements.txt');
      if (await requirementsFile.exists()) {
        final result = await Process.run(
          'pip',
          ['install', '-r', '${serverDir.path}/requirements.txt'],
          workingDirectory: serverDir.path,
        );
        
        if (result.exitCode == 0) {
          print('Python зависимости успешно установлены');
        } else {
          print('Ошибка установки Python зависимостей: ${result.stderr}');
        }
      }
    } catch (e) {
      print('Ошибка при установке Python зависимостей: $e');
    }
  }
}
