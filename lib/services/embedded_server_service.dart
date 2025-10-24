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
      
      // Если скрипт не существует, создаем его
      if (!await serverScript.exists()) {
        await _createServerFiles(serverDir);
        // Устанавливаем зависимости Python
        await _installPythonDependencies(serverDir);
      }
      
      // Запускаем Python сервер
      _serverProcess = await Process.start(
        'python',
        ['${serverDir.path}/main.py'],
        workingDirectory: serverDir.path,
      );
      
      // Обработка вывода сервера
      _serverProcess!.stdout.transform(utf8.decoder).listen((data) {
        print('Server stdout: $data');
      });
      
      _serverProcess!.stderr.transform(utf8.decoder).listen((data) {
        print('Server stderr: $data');
      });
      
      // Ждем немного, чтобы сервер запустился
      await Future.delayed(const Duration(seconds: 3));
      
      // Проверяем, что сервер запустился
      if (await _checkServerHealth()) {
        _isRunning = true;
        _serverUrl = 'http://127.0.0.1:8000';
        print('Встроенный сервер успешно запущен на $_serverUrl');
        return true;
      } else {
        print('Ошибка: сервер не отвечает');
        await stopServer();
        return false;
      }
      
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
  static Future<bool> _checkServerHealth() async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('$serverUrl/'));
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
        
        # Получаем метаданные
        patient_name = str(ds.get('PatientName', 'Unknown'))
        pixel_spacing = ds.get('PixelSpacing', [1.0, 1.0])
        pixel_spacing_row = float(pixel_spacing[0]) if pixel_spacing else 1.0
        
        # Удаляем временный файл
        os.remove(temp_path)
        
        return {
            'image_base64': image_base64,
            'patient_name': patient_name,
            'pixel_spacing_row': pixel_spacing_row,
            'window_center': window_center,
            'window_width': window_width
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
