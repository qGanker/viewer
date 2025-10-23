import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'settings_screen.dart';
import '../services/hotkey_service.dart';
import '../utils/keyboard_utils.dart';

// Перечисление для инструментов
enum ToolMode { pan, ruler, rotate, brightness, invert, annotation }

// Перечисление для типов действий
enum ActionType { rulerAdded, textAdded, arrowAdded, brightnessChanged, inverted, rotated }

// Класс для хранения истории действий
class ActionHistory {
  final ActionType type;
  final dynamic data; // Данные для отмены действия
  
  ActionHistory({required this.type, required this.data});
}

// Класс для текстовых аннотаций
class TextAnnotation {
  final Offset position;
  final String text;
  final Color color;
  final double fontSize;
  
  TextAnnotation({
    required this.position,
    required this.text,
    this.color = Colors.yellow,
    this.fontSize = 16.0,
  });
}

// Класс для стрелок
class ArrowAnnotation {
  final Offset start;
  final Offset end;
  final Color color;
  final double strokeWidth;
  
  ArrowAnnotation({
    required this.start,
    required this.end,
    this.color = Colors.red,
    this.strokeWidth = 3.0,
  });
}

// Класс для рисования аннотаций
class AnnotationPainter extends CustomPainter {
  final List<TextAnnotation> textAnnotations;
  final List<ArrowAnnotation> arrowAnnotations;
  final List<Offset> arrowPoints; // Промежуточные точки для предварительного просмотра
  
  AnnotationPainter({
    required this.textAnnotations,
    required this.arrowAnnotations,
    this.arrowPoints = const [],
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    // Рисуем текстовые аннотации
    for (var annotation in textAnnotations) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: annotation.text,
          style: TextStyle(
            color: annotation.color,
            fontSize: annotation.fontSize,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.black87,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      
      // Рисуем фон для текста
      final bgRect = Rect.fromLTWH(
        annotation.position.dx - 5,
        annotation.position.dy - 2,
        textPainter.width + 10,
        textPainter.height + 4,
      );
      canvas.drawRect(bgRect, Paint()..color = Colors.black87);
      
      textPainter.paint(canvas, annotation.position);
    }
    
    // Рисуем стрелки
    for (var arrow in arrowAnnotations) {
      final paint = Paint()
        ..color = arrow.color
        ..strokeWidth = arrow.strokeWidth
        ..style = PaintingStyle.stroke;
      
      // Рисуем основную линию
      canvas.drawLine(arrow.start, arrow.end, paint);
      
      // Вычисляем направление стрелки
      final dx = arrow.end.dx - arrow.start.dx;
      final dy = arrow.end.dy - arrow.start.dy;
      final length = sqrt(dx * dx + dy * dy);
      
      if (length > 0) {
        // Нормализованный вектор направления
        final unitX = dx / length;
        final unitY = dy / length;
        
        // Размер стрелки
        final arrowLength = 15.0;
        final arrowAngle = 0.5; // угол в радианах
        
        // Вычисляем точки стрелки
        final arrowPoint1 = Offset(
          arrow.end.dx - arrowLength * (unitX * cos(arrowAngle) + unitY * sin(arrowAngle)),
          arrow.end.dy - arrowLength * (unitY * cos(arrowAngle) - unitX * sin(arrowAngle)),
        );
        
        final arrowPoint2 = Offset(
          arrow.end.dx - arrowLength * (unitX * cos(-arrowAngle) + unitY * sin(-arrowAngle)),
          arrow.end.dy - arrowLength * (unitY * cos(-arrowAngle) - unitX * sin(-arrowAngle)),
        );
        
        // Рисуем стрелку
        canvas.drawLine(arrow.end, arrowPoint1, paint);
        canvas.drawLine(arrow.end, arrowPoint2, paint);
      }
    }
    
    // Рисуем промежуточные точки стрелки для предварительного просмотра
    if (arrowPoints.length == 2) {
      final paint = Paint()
        ..color = Colors.red.withOpacity(0.7)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      
      // Рисуем линию предварительного просмотра
      canvas.drawLine(arrowPoints[0], arrowPoints[1], paint);
      
      // Рисуем точки
      final pointPaint = Paint()
        ..color = Colors.red
        ..style = PaintingStyle.fill;
      
      canvas.drawCircle(arrowPoints[0], 4, pointPaint);
      canvas.drawCircle(arrowPoints[1], 4, pointPaint);
    }
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is! AnnotationPainter) return true;
    
    // Проверяем изменения в аннотациях
    if (textAnnotations.length != oldDelegate.textAnnotations.length ||
        arrowAnnotations.length != oldDelegate.arrowAnnotations.length ||
        arrowPoints.length != oldDelegate.arrowPoints.length) {
      return true;
    }
    
    // Проверяем изменения в позициях
    for (int i = 0; i < textAnnotations.length; i++) {
      if (textAnnotations[i].position != oldDelegate.textAnnotations[i].position ||
          textAnnotations[i].text != oldDelegate.textAnnotations[i].text) {
        return true;
      }
    }
    
    for (int i = 0; i < arrowAnnotations.length; i++) {
      if (arrowAnnotations[i].start != oldDelegate.arrowAnnotations[i].start ||
          arrowAnnotations[i].end != oldDelegate.arrowAnnotations[i].end) {
        return true;
      }
    }
    
    return false;
  }
}

// Класс для хранения одной линии линейки
class RulerLine {
  final Offset start;
  final Offset end;
  final double pixelSpacing;
  
  RulerLine({required this.start, required this.end, required this.pixelSpacing});
  
  double get distance {
    return (end - start).distance;
  }
  
  double get realDistanceMm {
    return distance * pixelSpacing;
  }
}

// Класс для рисования линейки
class RulerPainter extends CustomPainter {
  final List<Offset> currentPoints; // Текущие точки для рисования
  final List<RulerLine> completedLines; // Завершенные линии
  final double pixelSpacing;
  
  RulerPainter({
    required this.currentPoints, 
    required this.completedLines,
    required this.pixelSpacing
  });
  @override
  void paint(Canvas canvas, Size size) {
    try {
      final paint = Paint()..color = Colors.yellow..strokeWidth = 2..style = PaintingStyle.stroke;
      final fillPaint = Paint()..color = Colors.yellow..style = PaintingStyle.fill;
      
      // Проверяем корректность pixelSpacing
      final safePixelSpacing = pixelSpacing.isFinite && pixelSpacing > 0 ? pixelSpacing : 1.0;
    
      // Рисуем все завершенные линии
      for (int i = 0; i < completedLines.length; i++) {
        final line = completedLines[i];
        _drawRulerLine(canvas, line.start, line.end, safePixelSpacing, paint, fillPaint, i + 1);
      }
      
      // Рисуем текущие точки и линию (если есть)
      if (currentPoints.isNotEmpty) {
        // Рисуем точки
        for (var point in currentPoints) { 
          canvas.drawCircle(point, 6, fillPaint);
          canvas.drawCircle(point, 6, paint..color = Colors.black);
        }
        
        // Рисуем линию и измерения
        if (currentPoints.length > 1) {
          _drawRulerLine(canvas, currentPoints[0], currentPoints[1], safePixelSpacing, paint, fillPaint, completedLines.length + 1);
        }
      }
    } catch (e) {
      print("Ошибка в RulerPainter: $e");
      // В случае ошибки просто не рисуем ничего
    }
  }
  
  void _drawRulerLine(Canvas canvas, Offset start, Offset end, double safePixelSpacing, Paint paint, Paint fillPaint, int lineNumber) {
    // Основная линия
    canvas.drawLine(start, end, paint..strokeWidth = 3);
    
    // Перпендикулярные линии на концах для точности
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = sqrt(dx * dx + dy * dy);
    
    if (length > 0) {
      // Нормализованный перпендикулярный вектор
      final perpX = -dy / length * 10;
      final perpY = dx / length * 10;
      
      // Рисуем перпендикулярные линии
      canvas.drawLine(
        Offset(start.dx - perpX, start.dy - perpY),
        Offset(start.dx + perpX, start.dy + perpY),
        paint..strokeWidth = 2
      );
      canvas.drawLine(
        Offset(end.dx - perpX, end.dy - perpY),
        Offset(end.dx + perpX, end.dy + perpY),
        paint..strokeWidth = 2
      );
    }
    
    // Вычисляем расстояние
    final pixelDistance = (end - start).distance;
    final realDistanceMm = pixelDistance * safePixelSpacing;
    
    // Рисуем текст с расстоянием и номером линии
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'L$lineNumber: ${realDistanceMm.toStringAsFixed(2)} mm\n(${pixelDistance.toStringAsFixed(1)} px)',
        style: const TextStyle(
          color: Colors.yellow,
          fontSize: 14,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.black87
        )
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    
    // Позиционируем текст
    final textOffset = Offset(
      (start.dx + end.dx) / 2 + 15, 
      (start.dy + end.dy) / 2 - textPainter.height / 2
    );
    
    // Рисуем фон для текста
    final bgRect = Rect.fromLTWH(
      textOffset.dx - 5,
      textOffset.dy - 2,
      textPainter.width + 10,
      textPainter.height + 4
    );
    canvas.drawRect(bgRect, Paint()..color = Colors.black87);
    
    textPainter.paint(canvas, textOffset);
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    // Для надежности всегда перерисовываем, так как списки могут мутировать по месту
    return true;
  }
}

// Новая функция для декодирования в фоне
Uint8List _decodeResponseInIsolate(String responseBody) {
  final Map<String, dynamic> data = jsonDecode(responseBody);
  return base64Decode(data['image_base64']);
}

// Функция для декодирования изображения в изоляте
Uint8List _decodeImageInIsolate(dynamic data) {
  final String imageBase64 = data as String;
  return base64Decode(imageBase64);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Uint8List? _imageBytes;
  String? _patientName;
  bool _isLoading = false;
  String _errorMessage = '';
  ToolMode _currentTool = ToolMode.pan;

  // Линейка: текущие точки (0-1 точка) для активного измерения
  List<Offset> _rulerPoints = [];
  
  // Линейка: все завершенные измерения (L1, L2, L3...)
  List<RulerLine> _completedRulerLines = [];
  double _pixelSpacingRow = 1.0;
  final TransformationController _transformationController = TransformationController();

  // Переменные для аннотаций
  List<TextAnnotation> _textAnnotations = [];
  List<ArrowAnnotation> _arrowAnnotations = [];
  List<Offset> _arrowPoints = []; // Для создания стрелок
  bool _isDragging = false; // Флаг для отслеживания перетаскивания
  Offset? _lastTapPosition; // Последняя позиция клика для создания стрелок
  
  // Переменные для истории действий (отмена)
  List<ActionHistory> _actionHistory = [];
  int _maxHistorySize = 50; // Максимальный размер истории

  // Переменные для W/L
  double? _windowCenter, _windowWidth, _initialWC, _initialWW;
  Timer? _debounce;
  bool _isUpdatingWL = false;
  
  // Кэш для предотвращения ненужных пересчетов
  Matrix4? _cachedInvertedMatrix;
  bool _matrixCacheValid = false;
  
  // Переменные для яркости
  double _brightness = 1.0;
  double _initialBrightness = 1.0;
  
  // Переменные для инверсии
  bool _isInverted = false;
  bool _initialInverted = false;
  
  // Переменные для поворота
  double _rotationAngle = 0.0;
  double _initialRotationAngle = 0.0;
  
  // Сохраняем исходное изображение для сброса
  Uint8List? _originalImageBytes;

  @override
  void initState() {
    super.initState();
    _initializeHotkeys();
    
    // Откладываем инициализацию кэша матрицы до первого использования
    _matrixCacheValid = false;
    
    // Слушаем изменения трансформации для инвалидации кэша
    _transformationController.addListener(() {
      _matrixCacheValid = false;
    });
  }

  Future<void> _initializeHotkeys() async {
    await HotkeyService.initialize();
  }

  void _resetAllSettings() {
    setState(() {
      // Восстанавливаем исходное изображение
      if (_originalImageBytes != null) {
        _imageBytes = _originalImageBytes;
      }
      
      // Сбрасываем все параметры
      _brightness = _initialBrightness;
      _isInverted = _initialInverted;
      _rotationAngle = _initialRotationAngle;
      _windowCenter = _initialWC;
      _windowWidth = _initialWW;
      _rulerPoints.clear();
      _completedRulerLines.clear();
      _textAnnotations.clear();
      _arrowAnnotations.clear();
      _arrowPoints.clear();
      _actionHistory.clear();
      _transformationController.value = Matrix4.identity();
    });
  }


  void _showHotkeyNotification(String toolName) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Горячая клавиша: $toolName'),
          duration: const Duration(milliseconds: 1000),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _openAndProcessFile() async {
    // Эта строка теперь правильная, она сбрасывает линейку, яркость, инверсию и поворот
    setState(() { 
      _isLoading = true; 
      _errorMessage = ''; 
      
      _imageBytes = null; 
      _originalImageBytes = null; // Сбрасываем исходное изображение
      _patientName = null; 
      _rulerPoints = []; 
      _completedRulerLines = []; // Сбрасываем завершенные линии
      _textAnnotations = []; // Сбрасываем текстовые аннотации
      _arrowAnnotations = []; // Сбрасываем стрелки
      _arrowPoints = []; // Сбрасываем точки для стрелок
      _isDragging = false; // Сбрасываем флаг перетаскивания
      _actionHistory.clear(); // Очищаем историю действий
      _brightness = 1.0;
      _initialBrightness = 1.0;
      _isInverted = false;
      _initialInverted = false;
      _rotationAngle = 0.0;
      _initialRotationAngle = 0.0;
    });
    
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      
      if (result != null && result.files.single.bytes != null) {
        print("Выбран файл: ${result.files.single.name}, размер: ${result.files.single.bytes!.length} байт");
        
        // Проверяем размер файла
        if (result.files.single.bytes!.length > 100 * 1024 * 1024) { // 100MB
          setState(() { 
            _errorMessage = 'Файл слишком большой (${(result.files.single.bytes!.length / 1024 / 1024).toStringAsFixed(1)} MB). Максимальный размер: 100 MB'; 
            _isLoading = false; 
          });
          return;
        }
        
        // Проверяем доступность сервера
        try {
          final healthCheck = await http.get(Uri.parse('http://127.0.0.1:8000/')).timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              throw Exception('Сервер недоступен (таймаут 5 секунд)');
            },
          );
          print("Сервер доступен, статус: ${healthCheck.statusCode}");
        } catch (healthError) {
          setState(() { 
            _errorMessage = 'Сервер недоступен. Убедитесь, что backend запущен на http://127.0.0.1:8000\n\nОшибка: $healthError'; 
            _isLoading = false; 
          });
          return;
        }
        
        var request = http.MultipartRequest('POST', Uri.parse('http://127.0.0.1:8000/process_dicom/'));
        request.files.add(http.MultipartFile.fromBytes('file', result.files.single.bytes!, filename: result.files.single.name));
        
        print("Отправляем запрос на сервер...");
        
        // Добавляем таймаут для запроса
        var streamedResponse = await request.send().timeout(
          const Duration(seconds: 60), // Увеличиваем таймаут для больших файлов
          onTimeout: () {
            throw Exception('Таймаут запроса к серверу (60 секунд)');
          },
        );
        
        print("Получен ответ от сервера, статус: ${streamedResponse.statusCode}");
        
        if (streamedResponse.statusCode == 200) {
          final responseBody = await streamedResponse.stream.bytesToString().timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw Exception('Таймаут получения ответа от сервера (30 секунд)');
            },
          );
          print("Ответ сервера получен, длина: ${responseBody.length} символов");
          
          try {
            final data = jsonDecode(responseBody);
            print("JSON успешно декодирован");
            
            // Проверяем наличие всех необходимых полей
            if (!data.containsKey('image_base64')) {
              throw Exception('Отсутствует поле image_base64 в ответе сервера');
            }
            if (!data.containsKey('patient_name')) {
              throw Exception('Отсутствует поле patient_name в ответе сервера');
            }
            if (!data.containsKey('pixel_spacing_row')) {
              throw Exception('Отсутствует поле pixel_spacing_row в ответе сервера');
            }
            
            print("Все необходимые поля присутствуют в ответе");
            
            // Декодируем изображение в отдельном изоляте для предотвращения блокировки UI
            try {
              final imageBytes = await compute(_decodeImageInIsolate, data['image_base64']);
              
              setState(() {
                _imageBytes = imageBytes;
                print("Изображение декодировано, размер: ${_imageBytes?.length ?? 0} байт");
                
                _originalImageBytes = _imageBytes; // Сохраняем исходное изображение
                _patientName = data['patient_name'];
                _pixelSpacingRow = (data['pixel_spacing_row'] as num).toDouble();
                _windowCenter = (data['window_center'] as num).toDouble();
                _windowWidth = (data['window_width'] as num).toDouble();
                _initialWC = _windowCenter;
                _initialWW = _windowWidth;
                _isLoading = false;
                
                print("Все данные успешно установлены");
              });
            } catch (decodeError) {
              print("Ошибка при декодировании изображения: $decodeError");
              setState(() { 
                _errorMessage = 'Ошибка при декодировании изображения: $decodeError'; 
                _isLoading = false; 
              });
              return;
            }
            
            print("Изображение успешно загружено");
          } catch (jsonError) {
            print("Ошибка при декодировании JSON: $jsonError");
            setState(() { _errorMessage = 'Ошибка при обработке ответа сервера: $jsonError'; _isLoading = false; });
          }
        } else {
          final errorBody = await streamedResponse.stream.bytesToString();
          print("Ошибка сервера: $errorBody");
          setState(() { _errorMessage = 'Ошибка сервера (${streamedResponse.statusCode}): $errorBody'; _isLoading = false; });
        }

      } else {
        print("Файл не выбран или пустой");
        setState(() => _isLoading = false);
      }
    } catch (e) {
      print("Общая ошибка при загрузке файла: $e");
      setState(() { _errorMessage = 'Произошла ошибка: $e'; _isLoading = false; });
    }
  }


  void _handleTap(TapDownDetails details) {
    // Получаем координаты клика в системе изображения
    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
      _matrixCacheValid = true;
    }
    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, details.localPosition);
    
    // Обрабатываем клик только если активен инструмент линейки
    if (_currentTool != ToolMode.ruler) return;

    // Определяем, зажат ли Ctrl в момент клика
    final bool ctrlPressed = RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.controlLeft) ||
                             RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.controlRight);

    setState(() {
      if (ctrlPressed) {
        // Режим добавления сегментов при зажатом Ctrl
        if (_rulerPoints.length == 1) {
          // Завершаем текущую линию из точки-анкера в новую точку
          final completedLine = RulerLine(
            start: _rulerPoints[0],
            end: sceneOffset,
            pixelSpacing: _pixelSpacingRow,
          );
          _completedRulerLines = List.of(_completedRulerLines)..add(completedLine);
          _addToHistory(ActionType.rulerAdded, null);
          print("Линейка: добавлен сегмент Ctrl из анкера -> новая точка");
          // Очищаем анкер после завершения сегмента
          _rulerPoints = [];
        } else if (_rulerPoints.isEmpty) {
          // Нет ни точек, ни линий — ставим первую точку-анкер
          _rulerPoints.add(sceneOffset);
          print("Линейка: установлен анкер (Ctrl) в пустом состоянии");
        } else if (_rulerPoints.length >= 2) {
          // Если по какой-то причине осталось 2 точки, сбрасываем к одному анкеру
          _rulerPoints = [sceneOffset];
        }
      } else {
        // Режим без Ctrl: если была линия — удалить её и начать новую точку
        if (_completedRulerLines.isNotEmpty) {
          _completedRulerLines = [];
          print("Линейка: без Ctrl — удалены все старые линии");
        }

        // Обычная логика построения: две клики создают линию
        if (_rulerPoints.length == 0) {
          _rulerPoints.add(sceneOffset);
          print("Линейка: добавлена первая точка");
        } else if (_rulerPoints.length == 1) {
          // Завершаем линию
          final completedLine = RulerLine(
            start: _rulerPoints[0],
            end: sceneOffset,
            pixelSpacing: _pixelSpacingRow,
          );
          _completedRulerLines = List.of(_completedRulerLines)..add(completedLine);
          _addToHistory(ActionType.rulerAdded, null);
          print("Линейка: завершено измерение без Ctrl");
          // Очищаем точки для следующего измерения
          _rulerPoints = [];
        } else {
          // Если было больше 1 точки (неожиданно), начинаем заново
          _rulerPoints = [sceneOffset];
        }
      }
    });
  }

  void _handleTapUp(TapUpDetails details) {
    if (_currentTool != ToolMode.annotation || _isDragging) return;
    
    // Используем кэшированную матрицу для производительности
    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
      _matrixCacheValid = true;
    }
    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, details.localPosition);
    
    // Если есть сохраненная позиция, создаем стрелку
    if (_lastTapPosition != null) {
      setState(() {
        _arrowAnnotations.add(ArrowAnnotation(
          start: _lastTapPosition!,
          end: sceneOffset,
        ));
        _lastTapPosition = null;
        // Добавляем в историю
        _addToHistory(ActionType.arrowAdded, null);
      });
    } else {
      // Сохраняем позицию для следующего клика (для создания стрелки)
      // или показываем диалог для текста
      _showAnnotationChoiceDialog(sceneOffset);
    }
  }
  
  void _showAnnotationChoiceDialog(Offset position) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Выберите тип аннотации'),
          content: const Text('Что вы хотите добавить?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _showTextInputDialog(position);
              },
              child: const Text('Текст'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _lastTapPosition = position;
                });
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Кликните в конечную точку стрелки'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: const Text('Стрелка (2 клика)'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена'),
            ),
          ],
        );
      },
    );
  }

  void _handlePanStart(DragStartDetails details) {
    if (_currentTool != ToolMode.annotation) return;
    
    // Используем кэшированную матрицу для производительности
    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
      _matrixCacheValid = true;
    }
    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, details.localPosition);
    
    setState(() {
      _isDragging = true; // Устанавливаем флаг перетаскивания
      _arrowPoints.clear(); // Очищаем предыдущие точки
      _arrowPoints.add(sceneOffset); // Добавляем начальную точку
    });
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (_currentTool != ToolMode.annotation) return;
    
    // Используем кэшированную матрицу для производительности
    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
      _matrixCacheValid = true;
    }
    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, details.localPosition);
    
    // Оптимизированное обновление без лишних setState
    bool needsUpdate = false;
    if (_arrowPoints.length == 1) {
      _arrowPoints.add(sceneOffset);
      needsUpdate = true;
    } else if (_arrowPoints.length == 2) {
      _arrowPoints[1] = sceneOffset;
      needsUpdate = true;
    }
    
    if (needsUpdate) {
      setState(() {});
    }
  }

  void _handlePanEnd(DragEndDetails details) {
    if (_currentTool != ToolMode.annotation || _arrowPoints.isEmpty) return;
    
    // Если у нас есть только одна точка, добавляем вторую в том же месте
    if (_arrowPoints.length == 1) {
      _arrowPoints.add(_arrowPoints[0]);
    }
    
    // Создаем стрелку только если у нас есть хотя бы одна точка
    if (_arrowPoints.length >= 1) {
      final start = _arrowPoints[0];
      final end = _arrowPoints.length > 1 ? _arrowPoints[1] : _arrowPoints[0];
      
      setState(() {
        _arrowAnnotations.add(ArrowAnnotation(
          start: start,
          end: end,
        ));
        _arrowPoints.clear();
        _isDragging = false; // Сбрасываем флаг перетаскивания
        // Добавляем в историю
        _addToHistory(ActionType.arrowAdded, null);
      });
      
      print("Стрелка создана: ${start} -> ${end}");
    }
  }

  void _showTextInputDialog(Offset position) {
    final TextEditingController textController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Добавить текстовую аннотацию'),
          content: TextField(
            controller: textController,
            decoration: const InputDecoration(
              hintText: 'Введите текст аннотации',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                if (textController.text.isNotEmpty) {
                  setState(() {
                    _textAnnotations.add(TextAnnotation(
                      position: position,
                      text: textController.text,
                    ));
                    // Добавляем в историю
                    _addToHistory(ActionType.textAdded, null);
                  });
                }
                Navigator.of(context).pop();
              },
              child: const Text('Добавить'),
            ),
          ],
        );
      },
    );
  }


  // Методы для работы с историей действий
  void _addToHistory(ActionType type, dynamic data) {
    _actionHistory.add(ActionHistory(type: type, data: data));
    
    // Ограничиваем размер истории
    if (_actionHistory.length > _maxHistorySize) {
      _actionHistory.removeAt(0);
    }
  }
  
  void _undoLastAction() {
    if (_actionHistory.isEmpty) {
      return;
    }
    
    final lastAction = _actionHistory.removeLast();
    
    setState(() {
      switch (lastAction.type) {
        case ActionType.rulerAdded:
          // Удаляем последнее завершенное измерение
          if (_completedRulerLines.isNotEmpty) {
            _completedRulerLines.removeLast();
          }
          break;
        case ActionType.textAdded:
          // Удаляем последнюю текстовую аннотацию
          if (_textAnnotations.isNotEmpty) {
            _textAnnotations.removeLast();
          }
          break;
        case ActionType.arrowAdded:
          // Удаляем последнюю стрелку
          if (_arrowAnnotations.isNotEmpty) {
            _arrowAnnotations.removeLast();
          }
          break;
        case ActionType.brightnessChanged:
          // Восстанавливаем предыдущую яркость
          if (lastAction.data != null) {
            _brightness = lastAction.data;
          }
          break;
        case ActionType.inverted:
          // Восстанавливаем предыдущее состояние инверсии
          if (lastAction.data != null) {
            _isInverted = lastAction.data;
          }
          break;
        case ActionType.rotated:
          // Восстанавливаем предыдущий угол поворота
          if (lastAction.data != null) {
            _rotationAngle = lastAction.data;
          }
          break;
      }
    });
  }
  
  void _requestUpdatedImage({double? wc, double? ww}) async {
    final center = wc ?? _windowCenter;
    final width = ww ?? _windowWidth;
    if (center == null || width == null || _isUpdatingWL) return;

    setState(() => _isUpdatingWL = true);
    
    // Используем обычный W/L эндпоинт без яркости
    final url = Uri.parse('http://127.0.0.1:8000/update_wl/');
    final headers = {"Content-Type": "application/json"};
    final body = jsonEncode({
      "window_center": center, 
      "window_width": width,
      "brightness": 1.0  // Яркость теперь обрабатывается во Flutter
    });
    try {
      final response = await http.post(url, headers: headers, body: body);
      if (response.statusCode == 200 && mounted) {
        final newImageBytes = await compute(_decodeResponseInIsolate, response.body);
        setState(() => _imageBytes = newImageBytes);
      }
    } catch (e) {
      print("Failed to update W/L: $e");
    } finally {
      if (mounted) setState(() => _isUpdatingWL = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _transformationController.dispose();
    super.dispose();
  }

  // Кэш для предотвращения повторной обработки одной и той же клавиши
  String? _lastProcessedKey;
  DateTime? _lastKeyTime;
  
  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: FocusNode()..requestFocus(),
      onKey: (RawKeyEvent event) {
        if (event is RawKeyDownEvent) {
          // Нормализуем клавишу к английской букве для работы с любой раскладкой
          String keyString = KeyboardUtils.normalizeKey(event.logicalKey);
          
          // Получаем состояние модификаторов
          bool ctrlPressed = event.isControlPressed;
          bool altPressed = event.isAltPressed;
          bool shiftPressed = event.isShiftPressed;
          
          // Игнорируем модификаторы и пустые клавиши
          if (keyString.isEmpty || 
              keyString.contains('Control') || 
              keyString.contains('Alt') || 
              keyString.contains('Shift') ||
              keyString.contains('Meta') ||
              keyString.contains('Windows')) {
            print('Key ignored: modifier or empty key ($keyString)');
            return;
          }
          
          // Проверяем, что это не только модификаторы без основной клавиши
          if (ctrlPressed && !altPressed && !shiftPressed && keyString.isEmpty) {
            print('Key ignored: only Ctrl pressed without main key');
            return;
          }
          if (altPressed && !ctrlPressed && !shiftPressed && keyString.isEmpty) {
            print('Key ignored: only Alt pressed without main key');
            return;
          }
          if (shiftPressed && !ctrlPressed && !altPressed && keyString.isEmpty) {
            print('Key ignored: only Shift pressed without main key');
            return;
          }
          
          // Создаем уникальный ключ для комбинации
          String keyCombination = '${ctrlPressed ? 'ctrl+' : ''}${altPressed ? 'alt+' : ''}${shiftPressed ? 'shift+' : ''}$keyString';
          
          // Подробное логирование для отладки
          print('=== HOTKEY DEBUG ===');
          print('Key pressed: $keyString');
          print('Key combination: $keyCombination');
          print('Modifiers: Ctrl=$ctrlPressed, Alt=$altPressed, Shift=$shiftPressed');
          print('HotkeyService settings: ${HotkeyService.hotkeySettings.toJson()}');
          
          // Предотвращаем повторную обработку одной и той же клавиши в течение короткого времени
          DateTime now = DateTime.now();
          if (_lastProcessedKey == keyCombination && 
              _lastKeyTime != null && 
              now.difference(_lastKeyTime!).inMilliseconds < 50) {
            print('Key ignored: duplicate within 50ms');
            return;
          }
          
          _lastProcessedKey = keyCombination;
          _lastKeyTime = now;
          
          // Проверяем пользовательские горячие клавиши
          bool toolChanged = false;
          String? toolName;
          
          print('Checking hotkeys...');
          
          if (HotkeyService.isKeyForTool(keyString, 'pan', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ PAN hotkey matched');
            toolChanged = true;
            toolName = 'Панорамирование';
            setState(() => _currentTool = ToolMode.pan);
          } else if (HotkeyService.isKeyForTool(keyString, 'ruler', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ RULER hotkey matched');
            toolChanged = true;
            toolName = 'Линейка';
            setState(() => _currentTool = ToolMode.ruler);
          } else if (HotkeyService.isKeyForTool(keyString, 'brightness', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ BRIGHTNESS hotkey matched');
            toolChanged = true;
            toolName = 'Яркость';
            setState(() => _currentTool = ToolMode.brightness);
          } else if (HotkeyService.isKeyForTool(keyString, 'invert', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ INVERT hotkey matched');
            toolChanged = true;
            toolName = 'Инверсия';
            setState(() {
              _currentTool = ToolMode.invert;
              _isInverted = !_isInverted;
              _addToHistory(ActionType.inverted, !_isInverted);
            });
          } else if (HotkeyService.isKeyForTool(keyString, 'rotate', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ ROTATE hotkey matched');
            toolChanged = true;
            toolName = 'Поворот';
            setState(() {
              _currentTool = ToolMode.rotate;
              _addToHistory(ActionType.rotated, _rotationAngle);
              _rotationAngle += 90.0;
              if (_rotationAngle >= 360.0) _rotationAngle = 0.0;
            });
          } else if (HotkeyService.isKeyForTool(keyString, 'annotation', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ ANNOTATION hotkey matched');
            toolChanged = true;
            toolName = 'Аннотации';
            setState(() => _currentTool = ToolMode.annotation);
          } else if (HotkeyService.isKeyForTool(keyString, 'undo', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ UNDO hotkey matched');
            _undoLastAction();
          } else if (HotkeyService.isKeyForTool(keyString, 'reset', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ RESET hotkey matched');
            _resetAllSettings();
          } else {
            print('✗ No hotkey matched');
          }
          
          if (toolChanged && toolName != null) {
            print('Tool changed to: $toolName');
          }
          
          print('=== END HOTKEY DEBUG ===');
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('DICOM Viewer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
              // Перезагружаем настройки после возврата из экрана настроек
              await HotkeyService.reloadSettings();
              print('Настройки перезагружены: ${HotkeyService.hotkeySettings.toJson()}');
            },
            tooltip: 'Настройки',
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: Center(
        child: _isLoading
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  const Text('Обработка DICOM файла...', style: TextStyle(color: Colors.white, fontSize: 16)),
                  const SizedBox(height: 10),
                  const Text('Это может занять некоторое время для больших файлов', 
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              )
            : _errorMessage.isNotEmpty
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error, color: Colors.red, size: 48),
                      const SizedBox(height: 20),
                      Text(_errorMessage, 
                          style: const TextStyle(color: Colors.red, fontSize: 16),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Попробовать снова'),
                        onPressed: _openAndProcessFile,
                      ),
                    ],
                  )
                : _imageBytes != null
                    ? Row(
                        children: [
                          // Панель инструментов
                          Container(
                            width: 60, color: Colors.grey[900], padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Column(
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.pan_tool), 
                                  color: _currentTool == ToolMode.pan ? Colors.lightBlueAccent : Colors.white, 
                                  onPressed: () => setState(() { 
                                    _currentTool = ToolMode.pan; 
                                    _rulerPoints.clear(); 
                                  })
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.invert_colors), 
                                  color: _currentTool == ToolMode.invert ? Colors.lightBlueAccent : (_isInverted ? Colors.orange : Colors.white), 
                                  onPressed: () {
                                    setState(() { 
                                      _currentTool = ToolMode.invert; 
                                      _rulerPoints.clear();
                                      // Сохраняем предыдущее состояние в историю
                                      _addToHistory(ActionType.inverted, _isInverted);
                                      _isInverted = !_isInverted; // Переключаем инверсию
                                    });
                                  }
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.square_foot), 
                                  color: _currentTool == ToolMode.ruler ? Colors.lightBlueAccent : Colors.white, 
                                  onPressed: () => setState(() { 
                                    _currentTool = ToolMode.ruler; 
                                    _rulerPoints.clear(); // Очищаем текущие точки при переключении
                                  })
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.rotate_90_degrees_cw), 
                                  color: _currentTool == ToolMode.rotate ? Colors.lightBlueAccent : (_rotationAngle != 0.0 ? Colors.orange : Colors.white), 
                                  onPressed: () {
                                    setState(() { 
                                      _currentTool = ToolMode.rotate; 
                                      _rulerPoints.clear();
                                      // Сохраняем предыдущий угол в историю
                                      _addToHistory(ActionType.rotated, _rotationAngle);
                                      _rotationAngle += 90.0; // Поворачиваем на 90 градусов
                                      if (_rotationAngle >= 360.0) _rotationAngle = 0.0; // Сбрасываем после полного оборота
                                    });
                                  }
                                ),
                                const SizedBox(height: 15),
                                IconButton(icon: const Icon(Icons.brightness_7), color: _currentTool == ToolMode.brightness ? Colors.lightBlueAccent : Colors.white, onPressed: () => setState(() { _currentTool = ToolMode.brightness; _rulerPoints.clear(); })),
                                const SizedBox(height: 15),
                                IconButton(icon: const Icon(Icons.edit), color: _currentTool == ToolMode.annotation ? Colors.lightBlueAccent : Colors.white, onPressed: () => setState(() { _currentTool = ToolMode.annotation; _rulerPoints.clear(); })),
                                const SizedBox(height: 15),
                                // Кнопка отмены
                                IconButton(
                                  icon: const Icon(Icons.undo),
                                  color: _actionHistory.isNotEmpty ? Colors.orange : Colors.grey,
                                  tooltip: 'Отменить последнее действие (Ctrl+Z)',
                                  onPressed: _actionHistory.isNotEmpty ? _undoLastAction : null,
                                ),
                                const Divider(color: Colors.grey, height: 40, indent: 8, endIndent: 8),
                                // Кнопка сброса
                                IconButton(
                                  icon: const Icon(Icons.refresh),
                                  color: Colors.white,
                                  tooltip: 'Сброс всех настроек',
                                  onPressed: () {
                                    print("Сброс: восстанавливаем исходное изображение");
                                    
                                    // Сбрасываем все настройки БЕЗ запросов к backend
                                    setState(() {
                                      // Восстанавливаем исходное изображение
                                      if (_originalImageBytes != null) {
                                        _imageBytes = _originalImageBytes;
                                      }
                                      
                                      // Сбрасываем все параметры
                                      _brightness = _initialBrightness;
                                      _isInverted = _initialInverted;
                                      _rotationAngle = _initialRotationAngle;
                                      _windowCenter = _initialWC;
                                      _windowWidth = _initialWW;
                                      _rulerPoints.clear();
                                      _completedRulerLines.clear(); // Очищаем завершенные линии
                                      _textAnnotations.clear(); // Очищаем аннотации
                                      _arrowAnnotations.clear(); // Очищаем стрелки
                                      _arrowPoints.clear(); // Очищаем точки стрелок
                                      _actionHistory.clear(); // Очищаем историю действий
                                      _transformationController.value = Matrix4.identity();
                                    });
                                    
                                    print("Сброс завершен: яркость=$_brightness, W/L=$_windowCenter/$_windowWidth");
                                  },
                                ),
                              ],
                            ),
                          ),
                          // Область просмотра
                          Expanded(
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Column(
                                    children: [
                                      Text("W/L: ${_windowCenter?.round()}/${_windowWidth?.round()} | ${(_pixelSpacingRow * 100).toStringAsFixed(1)}% ${_isInverted ? '| Инвертировано' : ''} ${_rotationAngle != 0.0 ? '| Поворот: ${_rotationAngle.round()}°' : ''}",
                                          style: const TextStyle(color: Colors.white, fontSize: 16)),
                                      if (_currentTool == ToolMode.brightness) ...[
                                        const SizedBox(height: 10),
                                        const Text("💡 Яркость: используйте слайдер ниже или колёсико мыши", style: TextStyle(color: Colors.grey, fontSize: 12)),
                                        const SizedBox(height: 10),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Text("Яркость: ", style: TextStyle(color: Colors.white, fontSize: 14)),
                                            SizedBox(
                                              width: 200,
                                              child: Slider(
                                                value: _brightness,
                                                min: 0.1,
                                                max: 3.0,
                                                divisions: 29,
                                                activeColor: Colors.lightBlueAccent,
                                                inactiveColor: Colors.grey,
                                                onChanged: (value) {
                                                  // Сохраняем предыдущее значение в историю
                                                  _addToHistory(ActionType.brightnessChanged, _brightness);
                                                  setState(() {
                                                    _brightness = value;
                                                  });
                                                  // Яркость теперь обрабатывается прямо во Flutter, не нужны запросы на сервер
                                                },
                                              ),
                                            ),
                                            Text("${_brightness.toStringAsFixed(1)}", 
                                                style: const TextStyle(color: Colors.white, fontSize: 14)),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                        Expanded(
                                          child: Listener(
                                            onPointerSignal: (PointerSignalEvent event) {
                                              // Обрабатываем колёсико мыши только когда активен инструмент яркости
                                              if (event is PointerScrollEvent && _currentTool == ToolMode.brightness) {
                                                // Изменяем яркость в зависимости от направления прокрутки
                                                double delta = event.scrollDelta.dy > 0 ? -0.1 : 0.1;
                                                double newBrightness = (_brightness + delta).clamp(0.1, 3.0);
                                                
                                                // Проверяем, изменилось ли значение
                                                if (newBrightness != _brightness) {
                                                  // Сохраняем предыдущее значение в историю
                                                  _addToHistory(ActionType.brightnessChanged, _brightness);
                                                  setState(() {
                                                    _brightness = newBrightness;
                                                  });
                                                }
                                              }
                                            },
                                            child: GestureDetector(
                                              onTapDown: _handleTap,
                                              onTapUp: _handleTapUp,
                                              onPanStart: _handlePanStart,
                                              onPanUpdate: _handlePanUpdate,
                                              onPanEnd: _handlePanEnd,
                                              child: InteractiveViewer(
                                                transformationController: _transformationController,
                                                panEnabled: _currentTool == ToolMode.pan,
                                                scaleEnabled: _currentTool == ToolMode.pan,
                                                minScale: 0.1, maxScale: 8.0,
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    // Применяем яркость, инверсию и поворот прямо во Flutter
                                                    Transform.rotate(
                                                      angle: _rotationAngle * 3.14159 / 180, // Конвертируем градусы в радианы
                                                      child: ColorFiltered(
                                                        colorFilter: ColorFilter.matrix([
                                                          _brightness, 0, 0, 0, 0,  // Red
                                                          0, _brightness, 0, 0, 0,  // Green  
                                                          0, 0, _brightness, 0, 0,  // Blue
                                                          0, 0, 0, 1, 0,            // Alpha
                                                        ]),
                                                        child: ColorFiltered(
                                                          colorFilter: _isInverted ? ColorFilter.matrix([
                                                            -1, 0, 0, 0, 255,  // Инверсия красного
                                                            0, -1, 0, 0, 255,  // Инверсия зеленого
                                                            0, 0, -1, 0, 255,  // Инверсия синего
                                                            0, 0, 0, 1, 0,     // Альфа без изменений
                                                          ]) : ColorFilter.matrix([
                                                            1, 0, 0, 0, 0,     // Без инверсии
                                                            0, 1, 0, 0, 0,
                                                            0, 0, 1, 0, 0,
                                                            0, 0, 0, 1, 0,
                                                          ]),
                                                          child: _imageBytes != null 
                                                            ? Image.memory(
                                                                _imageBytes!,
                                                                errorBuilder: (context, error, stackTrace) {
                                                                  print("Ошибка при отрисовке изображения: $error");
                                                                  return Container(
                                                                    color: Colors.grey,
                                                                    child: const Center(
                                                                      child: Text(
                                                                        'Ошибка загрузки изображения',
                                                                        style: TextStyle(color: Colors.white),
                                                                      ),
                                                                    ),
                                                                  );
                                                                },
                                                              )
                                                            : const Center(
                                                                child: CircularProgressIndicator(),
                                                              ),
                                                        ),
                                                      ),
                                                  ),
                                                  CustomPaint(
                                                    painter: RulerPainter(
                                                      currentPoints: List.of(_rulerPoints), 
                                                      completedLines: List.of(_completedRulerLines),
                                                      pixelSpacing: _pixelSpacingRow
                                                    ),
                                                    child: Container(), // Пустой контейнер для предотвращения ошибок
                                                  ),
                                                  CustomPaint(
                                                    painter: AnnotationPainter(textAnnotations: _textAnnotations, arrowAnnotations: _arrowAnnotations, arrowPoints: _arrowPoints),
                                                    child: Container(), // Пустой контейнер для предотвращения ошибок
                                                  ),
                                                  if (_isUpdatingWL) const Center(child: CircularProgressIndicator()),
                                                ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : ElevatedButton.icon(icon: const Icon(Icons.folder_open), label: const Text('Открыть DICOM файл'), onPressed: _openAndProcessFile),
      ),
      ),
    );
  }
}