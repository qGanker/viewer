import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'settings_screen.dart';
import '../services/hotkey_service.dart';
import '../services/embedded_server_service.dart';
import '../utils/keyboard_utils.dart';
import '../widgets/windows_menu_bar.dart';

// Перечисление для инструментов
enum ToolMode { pan, ruler, angle, rotate, brightness, invert, annotation }

// Перечисление для типов действий
enum ActionType { rulerAdded, angleAdded, textAdded, arrowAdded, brightnessChanged, inverted, rotated }

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

// Класс для хранения одного измерения угла
class AngleMeasurement {
  final Offset vertex;  // Вершина угла
  final Offset point1;  // Первая точка на первом луче
  final Offset point2;  // Вторая точка на втором луче
  
  AngleMeasurement({
    required this.vertex,
    required this.point1,
    required this.point2,
  });
  
  // Вычисление угла в градусах
  double get angleDegrees {
    // Векторы от вершины к точкам
    final v1 = point1 - vertex;
    final v2 = point2 - vertex;
    
    // Вычисляем угол между векторами
    final dot = v1.dx * v2.dx + v1.dy * v2.dy;
    final mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy);
    final mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy);
    
    if (mag1 == 0 || mag2 == 0) return 0.0;
    
    final cosAngle = dot / (mag1 * mag2);
    // Ограничиваем значение cos для избежания ошибок округления
    final clampedCos = cosAngle.clamp(-1.0, 1.0);
    final angleRad = acos(clampedCos);
    
    return angleRad * 180 / pi;
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

// Класс для рисования углов
class AnglePainter extends CustomPainter {
  final List<Offset> currentPoints; // Текущие точки для рисования (0-3 точки)
  final List<AngleMeasurement> completedAngles; // Завершенные измерения углов
  
  AnglePainter({
    required this.currentPoints,
    required this.completedAngles,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    try {
      final paint = Paint()..color = Colors.cyan..strokeWidth = 2..style = PaintingStyle.stroke;
      final fillPaint = Paint()..color = Colors.cyan..style = PaintingStyle.fill;
      
      // Рисуем все завершенные углы
      for (int i = 0; i < completedAngles.length; i++) {
        final angle = completedAngles[i];
        _drawAngle(canvas, angle.vertex, angle.point1, angle.point2, paint, fillPaint, i + 1, angle.angleDegrees);
      }
      
      // Рисуем текущие точки и углы (если есть)
      if (currentPoints.isNotEmpty) {
        // Рисуем точки
        for (var point in currentPoints) {
          canvas.drawCircle(point, 6, fillPaint);
          canvas.drawCircle(point, 6, paint..color = Colors.black);
        }
        
        // Рисуем предварительный просмотр угла
        if (currentPoints.length == 2) {
          // Рисуем линию от первой точки (вершина) ко второй
          canvas.drawLine(currentPoints[0], currentPoints[1], paint);
        } else if (currentPoints.length == 3) {
          // Рисуем полный угол
          final vertex = currentPoints[0];
          final point1 = currentPoints[1];
          final point2 = currentPoints[2];
          
          // Вычисляем угол для предварительного просмотра
          final v1 = point1 - vertex;
          final v2 = point2 - vertex;
          final dot = v1.dx * v2.dx + v1.dy * v2.dy;
          final mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy);
          final mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy);
          double angleDeg = 0.0;
          if (mag1 > 0 && mag2 > 0) {
            final cosAngle = (dot / (mag1 * mag2)).clamp(-1.0, 1.0);
            angleDeg = acos(cosAngle) * 180 / pi;
          }
          
          _drawAngle(canvas, vertex, point1, point2, paint, fillPaint, completedAngles.length + 1, angleDeg);
        }
      }
    } catch (e) {
      print("Ошибка в AnglePainter: $e");
    }
  }
  
  void _drawAngle(Canvas canvas, Offset vertex, Offset point1, Offset point2, Paint paint, Paint fillPaint, int angleNumber, double angleDegrees) {
    // Рисуем два луча от вершины
    canvas.drawLine(vertex, point1, paint..strokeWidth = 3);
    canvas.drawLine(vertex, point2, paint..strokeWidth = 3);
    
    // Рисуем дугу угла
    final v1 = point1 - vertex;
    final v2 = point2 - vertex;
    final mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy);
    final mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy);
    
    if (mag1 > 0 && mag2 > 0) {
      // Вычисляем углы для дуги
      final angle1 = atan2(v1.dy, v1.dx);
      final angle2 = atan2(v2.dy, v2.dx);
      
      // Радиус дуги (30 пикселей или меньше, если лучи короткие)
      final arcRadius = min(30.0, min(mag1, mag2) * 0.3);
      
      // Рисуем дугу
      final rect = Rect.fromCircle(center: vertex, radius: arcRadius);
      canvas.drawArc(
        rect,
        angle1,
        angle2 - angle1,
        false,
        paint..strokeWidth = 2,
      );
    }
    
    // Рисуем вершину угла более заметно
    canvas.drawCircle(vertex, 8, fillPaint);
    canvas.drawCircle(vertex, 8, paint..color = Colors.black..strokeWidth = 2);
    
    // Рисуем текст с углом
    final textPainter = TextPainter(
      text: TextSpan(
        text: '∠$angleNumber: ${angleDegrees.toStringAsFixed(1)}°',
        style: const TextStyle(
          color: Colors.cyan,
          fontSize: 14,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.black87,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    
    // Позиционируем текст рядом с вершиной
    final textOffset = Offset(
      vertex.dx + 20,
      vertex.dy - textPainter.height / 2,
    );
    
    // Рисуем фон для текста
    final bgRect = Rect.fromLTWH(
      textOffset.dx - 5,
      textOffset.dy - 2,
      textPainter.width + 10,
      textPainter.height + 4,
    );
    canvas.drawRect(bgRect, Paint()..color = Colors.black87);
    
    textPainter.paint(canvas, textOffset);
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
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
  Uint8List? _originalDicomBytes;
  Map<String, String> _dicomTags = {};
  String? _dicomReport;
  final ScrollController _tagsScrollController = ScrollController();
  bool _showInfoPanel = true;
  bool _editInfo = false;
  String? _currentFileName;
  final TextEditingController _reportController = TextEditingController();
  final Map<String, TextEditingController> _tagControllers = {};

  // Линейка: текущие точки (0-1 точка) для активного измерения
  List<Offset> _rulerPoints = [];
  
  // Линейка: все завершенные измерения (L1, L2, L3...)
  List<RulerLine> _completedRulerLines = [];
  
  // Угол: текущие точки (0-3 точки) для активного измерения
  List<Offset> _anglePoints = [];
  
  // Угол: все завершенные измерения (∠1, ∠2, ∠3...)
  List<AngleMeasurement> _completedAngles = [];
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
  // Ключ для захвата экрана (PNG)
  final GlobalKey _captureKey = GlobalKey();
  double _initialBrightness = 1.0;
  
  // Переменные для инверсии
  bool _isInverted = false;
  bool _initialInverted = false;
  
  // Переменные для поворота
  double _rotationAngle = 0.0;
  double _initialRotationAngle = 0.0;
  
  // Сохраняем исходное изображение для сброса
  Uint8List? _originalImageBytes;

  // Создаем меню-бар
  List<MenuTab> get _menuTabs => [
    MenuTab(
      name: 'File',
      items: [
        MenuItem(
          name: 'Open File',
          icon: Icons.folder_open,
          shortcut: 'Ctrl+O',
        ),
        MenuItem(
          name: 'Save PNG with annotations',
          icon: Icons.image,
          shortcut: 'Ctrl+Shift+S',
          enabled: _imageBytes != null,
        ),
        MenuItem(
          name: 'Save with annotations',
          icon: Icons.save,
          shortcut: 'Ctrl+S',
          enabled: _originalDicomBytes != null,
        ),
        MenuItem(name: '-'), // Разделитель
        MenuItem(
          name: 'Exit',
          icon: Icons.exit_to_app,
          shortcut: 'Alt+F4',
        ),
      ],
    ),
  ];

  // Обработчик выбора пунктов меню
  void _onMenuItemSelected(String tabName, String itemName) {
    switch (tabName) {
      case 'File':
        switch (itemName) {
          case 'Open File':
            _openAndProcessFile();
            break;
          case 'Save PNG with annotations':
            _saveAnnotatedPng();
            break;
          case 'Save with annotations':
            if (_originalDicomBytes != null) {
              _exportDicom();
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Нет загруженного DICOM для сохранения'), backgroundColor: Colors.red),
              );
            }
            break;
          case 'Exit':
            SystemNavigator.pop();
            break;
        }
        break;
    }
  }

  Future<void> _saveAnnotatedPng() async {
    try {
      if (_imageBytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нет изображения для сохранения'), backgroundColor: Colors.red),
        );
        return;
      }

      // Захватываем ровно то, что на экране внутри RepaintBoundary
      final boundary = _captureKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        throw Exception('Render boundary not found');
      }
      // Используем повышенный pixelRatio для четкости
      final image = await boundary.toImage(pixelRatio: ui.window.devicePixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();

      final dir = await getApplicationDocumentsDirectory();
      final outDir = Directory('${dir.path}/png_exports');
      if (!await outDir.exists()) await outDir.create(recursive: true);
      final baseName = (_currentFileName ?? 'image').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${outDir.path}/${baseName.replaceAll('.dcm','')}_annotated.png');
      await file.writeAsBytes(pngBytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PNG сохранён: ${file.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка сохранения PNG: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // Централизованный метод для переключения инструментов
  void _switchTool(ToolMode newTool) {
    setState(() {
      // Очищаем все состояния инструментов
      _rulerPoints.clear();
      _anglePoints.clear();
      _arrowPoints.clear();
      _isDragging = false;
      _lastTapPosition = null;
      
      // Переключаем инструмент
      _currentTool = newTool;
      
      print('Инструмент переключен на: $newTool');
    });
  }

  @override
  void initState() {
    super.initState();
    _initializeHotkeys();
    _initializeEmbeddedServer();
    
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

  Future<void> _initializeEmbeddedServer() async {
    print('Инициализация встроенного сервера...');
    final success = await EmbeddedServerService.startServer();
    if (success) {
      print('Встроенный сервер успешно запущен');
    } else {
      print('Ошибка запуска встроенного сервера');
      setState(() {
        _errorMessage = 'Не удалось запустить встроенный сервер. Убедитесь, что Python установлен.';
      });
    }
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
      _anglePoints.clear();
      _completedAngles.clear();
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
      _dicomTags = {};
      _dicomReport = null;
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
        _currentFileName = result.files.single.name;
        _originalDicomBytes = result.files.single.bytes;
        
        // Проверяем размер файла
        if (result.files.single.bytes!.length > 100 * 1024 * 1024) { // 100MB
          setState(() { 
            _errorMessage = 'Файл слишком большой (${(result.files.single.bytes!.length / 1024 / 1024).toStringAsFixed(1)} MB). Максимальный размер: 100 MB'; 
            _isLoading = false; 
          });
          return;
        }
        
        // Проверяем доступность встроенного сервера
        if (!EmbeddedServerService.isRunning) {
          setState(() { 
            _errorMessage = 'Встроенный сервер не запущен. Попробуйте перезапустить приложение.'; 
            _isLoading = false; 
          });
          return;
        }
        
        var request = http.MultipartRequest('POST', Uri.parse('${EmbeddedServerService.serverUrl}/process_dicom/'));
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
                _isLoading = false;
                _errorMessage = '';
                print("Изображение декодировано, размер: ${_imageBytes?.length ?? 0} байт");
                
                _originalImageBytes = _imageBytes; // Сохраняем исходное изображение
                _patientName = data['patient_name'];
                if (data['tags'] is Map) {
                  _dicomTags = (data['tags'] as Map)
                      .map((key, value) => MapEntry(key.toString(), value.toString()));
                }
                if (data['report'] != null) {
                  _dicomReport = data['report'].toString();
                }
                _reportController.text = _dicomReport ?? '';
                // Обновляем контроллеры по тегам
                _tagControllers.clear();
                _dicomTags.forEach((k, v) {
                  _tagControllers[k] = TextEditingController(text: v);
                });
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
    
    // Обрабатываем клик для инструмента угла
    if (_currentTool == ToolMode.angle) {
      setState(() {
        if (_anglePoints.length == 0) {
          // Первый клик - устанавливаем вершину угла
          _anglePoints.add(sceneOffset);
          print("Угол: установлена вершина");
        } else if (_anglePoints.length == 1) {
          // Второй клик - устанавливаем первую точку на луче
          _anglePoints.add(sceneOffset);
          print("Угол: установлена первая точка на луче");
        } else if (_anglePoints.length == 2) {
          // Третий клик - устанавливаем вторую точку на луче и завершаем измерение
          _anglePoints.add(sceneOffset);
          final completedAngle = AngleMeasurement(
            vertex: _anglePoints[0],
            point1: _anglePoints[1],
            point2: _anglePoints[2],
          );
          _completedAngles = List.of(_completedAngles)..add(completedAngle);
          _addToHistory(ActionType.angleAdded, null);
          print("Угол: завершено измерение, угол = ${completedAngle.angleDegrees.toStringAsFixed(1)}°");
          // Очищаем точки для следующего измерения
          _anglePoints = [];
        } else {
          // Если по какой-то причине больше 3 точек, начинаем заново
          _anglePoints = [sceneOffset];
        }
      });
      return;
    }
    
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
        case ActionType.angleAdded:
          // Удаляем последнее завершенное измерение угла
          if (_completedAngles.isNotEmpty) {
            _completedAngles.removeLast();
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
    final url = Uri.parse('${EmbeddedServerService.serverUrl}/update_wl/');
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

  Future<void> _saveMetadata() async {
    try {
      // Обновляем локальное состояние из контроллеров
      _dicomReport = _reportController.text.trim();
      _dicomTags = Map.fromEntries(_dicomTags.keys.map((k) => MapEntry(k, _tagControllers[k]?.text ?? '')));

      final dir = await getApplicationDocumentsDirectory();
      final metaDir = Directory('${dir.path}/dicom_metadata');
      if (!await metaDir.exists()) {
        await metaDir.create(recursive: true);
      }
      final baseName = (_currentFileName ?? 'session').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${metaDir.path}/$baseName.metadata.json');
      // Подготовка данных аннотаций для сохранения
      final rulers = _completedRulerLines.map((line) => {
        'x1': line.start.dx,
        'y1': line.start.dy,
        'x2': line.end.dx,
        'y2': line.end.dy,
        'distance_mm': line.realDistanceMm,
        'distance_px': line.distance,
      }).toList();
      
      final angles = _completedAngles.map((angle) => {
        'vertexX': angle.vertex.dx,
        'vertexY': angle.vertex.dy,
        'point1X': angle.point1.dx,
        'point1Y': angle.point1.dy,
        'point2X': angle.point2.dx,
        'point2Y': angle.point2.dy,
        'angle_degrees': angle.angleDegrees,
      }).toList();
      
      final texts = _textAnnotations.map((text) => {
        'x': text.position.dx,
        'y': text.position.dy,
        'text': text.text,
        'color': text.color.value,
        'fontSize': text.fontSize,
      }).toList();
      
      final arrows = _arrowAnnotations.map((arrow) => {
        'x1': arrow.start.dx,
        'y1': arrow.start.dy,
        'x2': arrow.end.dx,
        'y2': arrow.end.dy,
        'color': arrow.color.value,
        'strokeWidth': arrow.strokeWidth,
      }).toList();
      
      final data = {
        'patient_name': _patientName,
        'report': _dicomReport,
        'tags': _dicomTags,
        'window_center': _windowCenter,
        'window_width': _windowWidth,
        'pixel_spacing_row': _pixelSpacingRow,
        'annotations': {
          'rulers': rulers,
          'angles': angles,
          'texts': texts,
          'arrows': arrows,
        },
        'view_settings': {
          'brightness': _brightness,
          'inverted': _isInverted,
          'rotation_deg': _rotationAngle,
        },
        'updated_at': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Метаданные сохранены'), duration: Duration(milliseconds: 1200)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка сохранения: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showAddTagDialog() {
    final keyController = TextEditingController();
    final valueController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Новый тег'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: keyController,
                decoration: const InputDecoration(labelText: 'Ключ'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: valueController,
                decoration: const InputDecoration(labelText: 'Значение'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
            TextButton(
              onPressed: () {
                final k = keyController.text.trim();
                final v = valueController.text.trim();
                if (k.isNotEmpty) {
                  setState(() {
                    _dicomTags[k] = v;
                    _tagControllers[k]?.dispose();
                    _tagControllers[k] = TextEditingController(text: v);
                  });
                }
                Navigator.of(ctx).pop();
              },
              child: const Text('Добавить'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exportDicom() async {
    if (_originalDicomBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Исходный DICOM недоступен для экспорта'), backgroundColor: Colors.red),
      );
      return;
    }
    try {
      if (!EmbeddedServerService.isRunning) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сервер не запущен'), backgroundColor: Colors.red),
        );
        return;
      }
      var request = http.MultipartRequest('POST', Uri.parse('${EmbeddedServerService.serverUrl}/export_dicom/'));
      request.files.add(http.MultipartFile.fromBytes('file', _originalDicomBytes!, filename: _currentFileName ?? 'image.dcm'));
      final meta = jsonEncode({'tags': _dicomTags, 'report': _reportController.text});
      request.fields['metadata'] = meta;

      // Подготовка аннотаций для сервера (координаты уже в системе изображения)
      String _colorToHex(Color c) {
        return '#${c.red.toRadixString(16).padLeft(2, '0')}${c.green.toRadixString(16).padLeft(2, '0')}${c.blue.toRadixString(16).padLeft(2, '0')}'.toUpperCase();
      }

      final texts = _textAnnotations.map((t) => {
        'x': t.position.dx,
        'y': t.position.dy,
        'text': t.text,
        'color': _colorToHex(t.color),
        'fontSize': t.fontSize,
      }).toList();

      final arrows = _arrowAnnotations.map((a) => {
        'x1': a.start.dx,
        'y1': a.start.dy,
        'x2': a.end.dx,
        'y2': a.end.dy,
        'color': _colorToHex(a.color),
        'strokeWidth': a.strokeWidth,
      }).toList();

      final rulers = <Map<String, dynamic>>[];
      for (int i = 0; i < _completedRulerLines.length; i++) {
        final line = _completedRulerLines[i];
        final pixelDistance = (line.end - line.start).distance;
        final realDistanceMm = pixelDistance * (line.pixelSpacing.isFinite && line.pixelSpacing > 0 ? line.pixelSpacing : _pixelSpacingRow);
        final label = 'L${i + 1}: ${realDistanceMm.toStringAsFixed(2)} mm (${pixelDistance.toStringAsFixed(1)} px)';
        rulers.add({
          'x1': line.start.dx,
          'y1': line.start.dy,
          'x2': line.end.dx,
          'y2': line.end.dy,
          'label': label,
        });
      }

      final angles = <Map<String, dynamic>>[];
      for (int i = 0; i < _completedAngles.length; i++) {
        final angle = _completedAngles[i];
        final label = '∠${i + 1}: ${angle.angleDegrees.toStringAsFixed(1)}°';
        angles.add({
          'vertexX': angle.vertex.dx,
          'vertexY': angle.vertex.dy,
          'point1X': angle.point1.dx,
          'point1Y': angle.point1.dy,
          'point2X': angle.point2.dx,
          'point2Y': angle.point2.dy,
          'angle': angle.angleDegrees,
          'label': label,
        });
      }

      final annotations = jsonEncode({
        'texts': texts,
        'arrows': arrows,
        'rulers': rulers,
        'angles': angles,
        // Параметры вида для совпадения с экраном
        'rotation_deg': _rotationAngle, // в градусах, кратно 90
        'inverted': _isInverted,
        'brightness': _brightness,
      });
      request.fields['annotations'] = annotations;

      // Добавляем готовый PNG-рендер из области RepaintBoundary, чтобы DICOM совпадал 1:1
      final boundary = _captureKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary != null) {
        final image = await boundary.toImage(pixelRatio: ui.window.devicePixelRatio);
        final pngData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (pngData != null) {
          final pngBytes = pngData.buffer.asUint8List();
          request.files.add(http.MultipartFile.fromBytes('render', pngBytes, filename: 'render.png'));
        }
      }
      final streamed = await request.send();
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode == 200) {
        final resp = jsonDecode(body) as Map<String, dynamic>;
        final base64Str = resp['dicom_base64'] as String;
        final bytes = base64Decode(base64Str);
        final dir = await getApplicationDocumentsDirectory();
        final outDir = Directory('${dir.path}/dicom_exports');
        if (!await outDir.exists()) await outDir.create(recursive: true);
        final baseName = (_currentFileName ?? 'image').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final file = File('${outDir.path}/${baseName.replaceAll('.dcm','')}_edited.dcm');
        await file.writeAsBytes(bytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Сохранено: ${file.path}')), 
          );
        }
      } else {
        throw Exception('HTTP ${streamed.statusCode}: $body');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка экспорта: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _transformationController.dispose();
    EmbeddedServerService.stopServer();
    _reportController.dispose();
    for (final c in _tagControllers.values) { c.dispose(); }
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
          // Если фокус в любом текстовом поле (включая вложенные EditableText), не обрабатываем хоткеи
          final primaryFocus = FocusManager.instance.primaryFocus;
          bool isTextInput = false;
          if (primaryFocus != null) {
            final ctx = primaryFocus.context;
            if (ctx != null) {
              final w = ctx.widget;
              if (w is EditableText) {
                isTextInput = true;
              } else {
                // Проверяем предков на наличие текстовых виджетов
                if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) {
                  isTextInput = true;
                } else if (ctx.findAncestorWidgetOfExactType<TextField>() != null) {
                  isTextInput = true;
                } else if (ctx.findAncestorWidgetOfExactType<TextFormField>() != null) {
                  isTextInput = true;
                }
              }
            }
          }
          if (isTextInput) return;

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
            _switchTool(ToolMode.pan);
          } else if (HotkeyService.isKeyForTool(keyString, 'ruler', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ RULER hotkey matched');
            toolChanged = true;
            toolName = 'Линейка';
            _switchTool(ToolMode.ruler);
          } else if (HotkeyService.isKeyForTool(keyString, 'angle', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ ANGLE hotkey matched');
            toolChanged = true;
            toolName = 'Угол';
            _switchTool(ToolMode.angle);
          } else if (HotkeyService.isKeyForTool(keyString, 'brightness', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ BRIGHTNESS hotkey matched');
            toolChanged = true;
            toolName = 'Яркость';
            _switchTool(ToolMode.brightness);
          } else if (HotkeyService.isKeyForTool(keyString, 'invert', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ INVERT hotkey matched');
            toolChanged = true;
            toolName = 'Инверсия';
            setState(() {
              _switchTool(ToolMode.invert);
              _isInverted = !_isInverted;
              _addToHistory(ActionType.inverted, !_isInverted);
            });
          } else if (HotkeyService.isKeyForTool(keyString, 'rotate', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ ROTATE hotkey matched');
            toolChanged = true;
            toolName = 'Поворот';
            setState(() {
              _switchTool(ToolMode.rotate);
              _addToHistory(ActionType.rotated, _rotationAngle);
              _rotationAngle += 90.0;
              if (_rotationAngle >= 360.0) _rotationAngle = 0.0;
            });
          } else if (HotkeyService.isKeyForTool(keyString, 'annotation', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ ANNOTATION hotkey matched');
            toolChanged = true;
            toolName = 'Аннотации';
            _switchTool(ToolMode.annotation);
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
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // Меню-бар в стиле Windows
          WindowsMenuBar(
            tabs: _menuTabs,
            onMenuItemSelected: _onMenuItemSelected,
          ),
          // Основной AppBar
          AppBar(
            title: const Text('DICOM Viewer'),
            backgroundColor: const Color(0xFFF0F0F0),
            foregroundColor: Colors.black87,
            elevation: 0,
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
          // Основное содержимое
          Expanded(
            child: Center(
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
                                  onPressed: () => _switchTool(ToolMode.pan)
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.invert_colors), 
                                  color: _currentTool == ToolMode.invert ? Colors.lightBlueAccent : (_isInverted ? Colors.orange : Colors.white), 
                                  onPressed: () {
                                    setState(() { 
                                      _switchTool(ToolMode.invert);
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
                                  onPressed: () => _switchTool(ToolMode.ruler)
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.alt_route), 
                                  color: _currentTool == ToolMode.angle ? Colors.lightBlueAccent : Colors.white, 
                                  onPressed: () => _switchTool(ToolMode.angle),
                                  tooltip: 'Измерение угла (3 клика)',
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.rotate_90_degrees_cw), 
                                  color: _currentTool == ToolMode.rotate ? Colors.lightBlueAccent : (_rotationAngle != 0.0 ? Colors.orange : Colors.white), 
                                  onPressed: () {
                                    setState(() { 
                                      _switchTool(ToolMode.rotate);
                                      // Сохраняем предыдущий угол в историю
                                      _addToHistory(ActionType.rotated, _rotationAngle);
                                      _rotationAngle += 90.0; // Поворачиваем на 90 градусов
                                      if (_rotationAngle >= 360.0) _rotationAngle = 0.0; // Сбрасываем после полного оборота
                                    });
                                  }
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.brightness_7), 
                                  color: _currentTool == ToolMode.brightness ? Colors.lightBlueAccent : Colors.white, 
                                  onPressed: () => _switchTool(ToolMode.brightness)
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.edit), 
                                  color: _currentTool == ToolMode.annotation ? Colors.lightBlueAccent : Colors.white, 
                                  onPressed: () => _switchTool(ToolMode.annotation)
                                ),
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
                                      _anglePoints.clear(); // Очищаем точки углов
                                      _completedAngles.clear(); // Очищаем завершенные углы
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
                                                child: RepaintBoundary(
                                                  key: _captureKey,
                                                  child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    // Базовый чёрный слой, чтобы фон всегда оставался чёрным
                                                    Container(color: Colors.black),
                                                    // Применяем яркость, инверсию и поворот прямо во Flutter
                                                    ClipRect(
                                                    child: Transform.rotate(
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
                                                                width: double.infinity,
                                                                height: double.infinity,
                                                                fit: BoxFit.contain,
                                                                alignment: Alignment.center,
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
                                                  )),
                                                  CustomPaint(
                                                    painter: RulerPainter(
                                                      currentPoints: List.of(_rulerPoints), 
                                                      completedLines: List.of(_completedRulerLines),
                                                      pixelSpacing: _pixelSpacingRow
                                                    ),
                                                    child: Container(), // Пустой контейнер для предотвращения ошибок
                                                  ),
                                                  CustomPaint(
                                                    painter: AnglePainter(
                                                      currentPoints: List.of(_anglePoints),
                                                      completedAngles: List.of(_completedAngles),
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
                                        ),
                              ],
                            ),
                          ),
                          // Тумблер сворачивания/разворачивания панели
                          Container(
                            width: 28,
                            color: const Color(0xFF0C0C0C),
                            child: Center(
                              child: IconButton(
                                iconSize: 18,
                                padding: EdgeInsets.zero,
                                tooltip: _showInfoPanel ? 'Скрыть панель' : 'Показать панель',
                                icon: Icon(_showInfoPanel ? Icons.chevron_right : Icons.chevron_left, color: Colors.white70),
                                onPressed: () {
                                  setState(() { _showInfoPanel = !_showInfoPanel; });
                                },
                              ),
                            ),
                          ),
                          // Панель с тегами и заключением (можно скрыть)
                          if (_showInfoPanel)
                            Container(
                              width: 320,
                              color: const Color(0xFF111111),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: const BoxDecoration(
                                      border: Border(bottom: BorderSide(color: Color(0xFF222222), width: 1)),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _patientName != null ? 'Пациент: '+_patientName! : 'DICOM сведения',
                                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                                          ),
                                        ),
                                        IconButton(
                                          icon: Icon(_editInfo ? Icons.check : Icons.edit, size: 16, color: Colors.white70),
                                          tooltip: _editInfo ? 'Сохранить' : 'Редактировать',
                                          onPressed: () async {
                                            if (_editInfo) {
                                              // Сохранение
                                              await _saveMetadata();
                                            }
                                            setState(() { _editInfo = !_editInfo; });
                                          },
                                        ),
                                        const SizedBox(width: 4),
                                        IconButton(
                                          icon: const Icon(Icons.download, size: 16, color: Colors.white70),
                                          tooltip: 'Экспортировать DICOM с правками',
                                          onPressed: _exportDicom,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text('Заключение', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                                        const SizedBox(height: 6),
                                        _editInfo
                                          ? TextField(
                                              controller: _reportController,
                                              maxLines: 6,
                                              style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.3),
                                              decoration: InputDecoration(
                                                hintText: 'Введите заключение...',
                                                hintStyle: const TextStyle(color: Color(0xFF7A7A7A), fontSize: 12),
                                                isDense: true,
                                                filled: true,
                                                fillColor: const Color(0xFF1A1A1A),
                                                border: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFF2C2C2C)), borderRadius: BorderRadius.circular(4)),
                                              ),
                                            )
                                          : SelectableText(
                                              (_dicomReport != null && _dicomReport!.trim().isNotEmpty)
                                                  ? _dicomReport!
                                                  : 'Не найдено в файле',
                                              style: TextStyle(
                                                color: (_dicomReport != null && _dicomReport!.trim().isNotEmpty)
                                                    ? const Color(0xFFCCCCCC)
                                                    : const Color(0xFF7A7A7A),
                                                fontSize: 12,
                                                height: 1.3,
                                              ),
                                            ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text('Теги', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                                          const SizedBox(height: 6),
                                          if (_editInfo)
                                            Align(
                                              alignment: Alignment.centerLeft,
                                              child: TextButton.icon(
                                                onPressed: _showAddTagDialog,
                                                icon: const Icon(Icons.add, size: 16),
                                                label: const Text('Добавить тег'),
                                              ),
                                            ),
                                          Expanded(
                                            child: Scrollbar(
                                              controller: _tagsScrollController,
                                              thumbVisibility: true,
                                              child: ListView(
                                                controller: _tagsScrollController,
                                                children: _dicomTags.entries.map((e) {
                                                  if (_editInfo) {
                                                    _tagControllers.putIfAbsent(e.key, () => TextEditingController(text: e.value));
                                                    return Padding(
                                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                                      child: Row(
                                                        crossAxisAlignment: CrossAxisAlignment.center,
                                                        children: [
                                                          SizedBox(
                                                            width: 130,
                                                            child: Text(e.key, style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12)),
                                                          ),
                                                          const SizedBox(width: 8),
                                                          Expanded(
                                                            child: TextField(
                                                              controller: _tagControllers[e.key],
                                                              style: const TextStyle(color: Colors.white, fontSize: 12),
                                                              decoration: InputDecoration(
                                                                isDense: true,
                                                                filled: true,
                                                                fillColor: const Color(0xFF1A1A1A),
                                                                border: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFF2C2C2C)), borderRadius: BorderRadius.circular(4)),
                                                              ),
                                                            ),
                                                          ),
                                                          IconButton(
                                                            icon: const Icon(Icons.close, size: 16, color: Color(0xFF888888)),
                                                            tooltip: 'Удалить тег',
                                                            onPressed: () {
                                                              setState(() {
                                                                _dicomTags.remove(e.key);
                                                                _tagControllers.remove(e.key)?.dispose();
                                                              });
                                                            },
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                  } else {
                                                    return Padding(
                                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                                      child: Row(
                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                        children: [
                                                          SizedBox(
                                                            width: 130,
                                                            child: Text(e.key, style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12)),
                                                          ),
                                                          const SizedBox(width: 8),
                                                          Expanded(
                                                            child: Text(
                                                              e.value,
                                                              style: const TextStyle(color: Colors.white, fontSize: 12),
                                                              softWrap: true,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                  }
                                                }).toList(),
                                              ),
                                            ),
                                          ),
                                        ],
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
        ],
      ),
      ),
    );
  }
}