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
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_screen.dart';
import '../services/hotkey_service.dart';
import '../services/embedded_server_service.dart';
import '../utils/keyboard_utils.dart';
import '../widgets/windows_menu_bar.dart';

// Перечисление для инструментов
enum ToolMode { pan, ruler, angle, magnifier, rotate, brightness, invert, arrow, text }

// Перечисление для типов измерения углов
enum AngleType { normal, cobb }

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
  final int? selectedTextIndex; // Индекс выбранной текстовой аннотации
  final int? selectedArrowIndex; // Индекс выбранной стрелки
  
  AnnotationPainter({
    required this.textAnnotations,
    required this.arrowAnnotations,
    this.arrowPoints = const [],
    this.selectedTextIndex,
    this.selectedArrowIndex,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    // Рисуем текстовые аннотации
    for (int i = 0; i < textAnnotations.length; i++) {
      final annotation = textAnnotations[i];
      final isSelected = selectedTextIndex == i;
      
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
      
      // Рисуем рамку выделения, если аннотация выбрана
      if (isSelected) {
        final selectionRect = Rect.fromLTWH(
          annotation.position.dx - 8,
          annotation.position.dy - 5,
          textPainter.width + 16,
          textPainter.height + 10,
        );
        canvas.drawRect(selectionRect, Paint()
          ..color = Colors.orange
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0);
        
        // Рисуем индикатор перетаскивания (квадратик со стрелочками) сверху над аннотацией
        final dragHandleSize = 20.0;
        final dragHandleX = annotation.position.dx + textPainter.width / 2 - dragHandleSize / 2;
        final dragHandleY = annotation.position.dy - dragHandleSize - 5;
        final dragHandleRect = Rect.fromLTWH(dragHandleX, dragHandleY, dragHandleSize, dragHandleSize);
        
        // Рисуем фон индикатора
        canvas.drawRect(dragHandleRect, Paint()
          ..color = Colors.orange
          ..style = PaintingStyle.fill);
        canvas.drawRect(dragHandleRect, Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
        
        // Рисуем стрелочки (крестик из стрелок)
        final centerX = dragHandleX + dragHandleSize / 2;
        final centerY = dragHandleY + dragHandleSize / 2;
        final arrowSize = 6.0;
        
        // Верхняя стрелка
        canvas.drawLine(
          Offset(centerX, centerY - arrowSize),
          Offset(centerX, centerY),
          Paint()..color = Colors.white..strokeWidth = 2.0
        );
        canvas.drawLine(
          Offset(centerX - 2, centerY - 2),
          Offset(centerX, centerY),
          Paint()..color = Colors.white..strokeWidth = 2.0
        );
        canvas.drawLine(
          Offset(centerX + 2, centerY - 2),
          Offset(centerX, centerY),
          Paint()..color = Colors.white..strokeWidth = 2.0
        );
        
        // Нижняя стрелка
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX, centerY + arrowSize),
          Paint()..color = Colors.white..strokeWidth = 2.0
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX - 2, centerY + 2),
          Paint()..color = Colors.white..strokeWidth = 2.0
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX + 2, centerY + 2),
          Paint()..color = Colors.white..strokeWidth = 2.0
        );
      }
      
      textPainter.paint(canvas, annotation.position);
    }
    
    // Рисуем стрелки
    for (int i = 0; i < arrowAnnotations.length; i++) {
      final arrow = arrowAnnotations[i];
      final isSelected = selectedArrowIndex == i;
      
      final paint = Paint()
        ..color = isSelected ? Colors.orange : arrow.color
        ..strokeWidth = isSelected ? arrow.strokeWidth + 1.0 : arrow.strokeWidth
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
// Координаты хранятся в относительных координатах (0.0-1.0) для независимости от размера окна
class RulerLine {
  final Offset start;  // Относительные координаты (0.0-1.0)
  final Offset end;    // Относительные координаты (0.0-1.0)
  final double pixelSpacing;
  
  RulerLine({required this.start, required this.end, required this.pixelSpacing});
  
  // Преобразует относительные координаты в абсолютные для заданного размера
  Offset getAbsoluteStart(Size size) {
    return Offset(start.dx * size.width, start.dy * size.height);
  }
  
  Offset getAbsoluteEnd(Size size) {
    return Offset(end.dx * size.width, end.dy * size.height);
  }
  
  double getDistance(Size size) {
    final absStart = getAbsoluteStart(size);
    final absEnd = getAbsoluteEnd(size);
    return (absEnd - absStart).distance;
  }
  
  double getRealDistanceMm(Size size) {
    return getDistance(size) * pixelSpacing;
  }
}

// Класс для хранения одного измерения угла
// Координаты хранятся в относительных координатах (0.0-1.0) для независимости от размера окна
class AngleMeasurement {
  final Offset vertex;  // Вершина угла (относительные координаты 0.0-1.0)
  final Offset point1;  // Первая точка на первом луче (относительные координаты 0.0-1.0)
  final Offset point2;  // Вторая точка на втором луче (относительные координаты 0.0-1.0)
  final AngleType type; // Тип угла (обычный или Кобба)
  final Offset? line1End; // Конечная точка первой линии (для угла Кобба)
  final Offset? line2End; // Конечная точка второй линии (для угла Кобба)
  
  AngleMeasurement({
    required this.vertex,
    required this.point1,
    required this.point2,
    this.type = AngleType.normal,
    this.line1End,
    this.line2End,
  });
  
  // Преобразует относительные координаты в абсолютные для заданного размера
  Offset getAbsoluteVertex(Size size) {
    return Offset(vertex.dx * size.width, vertex.dy * size.height);
  }
  
  Offset getAbsolutePoint1(Size size) {
    return Offset(point1.dx * size.width, point1.dy * size.height);
  }
  
  Offset getAbsolutePoint2(Size size) {
    return Offset(point2.dx * size.width, point2.dy * size.height);
  }
  
  Offset? getAbsoluteLine1End(Size size) {
    if (line1End == null) return null;
    return Offset(line1End!.dx * size.width, line1End!.dy * size.height);
  }
  
  Offset? getAbsoluteLine2End(Size size) {
    if (line2End == null) return null;
    return Offset(line2End!.dx * size.width, line2End!.dy * size.height);
  }
  
  // Вычисление угла в градусах для заданного размера
  double getAngleDegrees(Size size) {
    if (type == AngleType.cobb) {
      return _calculateCobbAngle(size);
    }
    
    final v = getAbsoluteVertex(size);
    final p1 = getAbsolutePoint1(size);
    final p2 = getAbsolutePoint2(size);
    
    // Векторы от вершины к точкам
    final v1 = p1 - v;
    final v2 = p2 - v;
    
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
  
  // Вычисление угла Кобба
  // Угол Кобба измеряется между перпендикулярами к двум линиям
  double _calculateCobbAngle(Size size) {
    if (line1End == null || line2End == null) return 0.0;
    
    final l1Start = getAbsolutePoint1(size);
    final l1End = getAbsoluteLine1End(size)!;
    final l2Start = getAbsolutePoint2(size);
    final l2End = getAbsoluteLine2End(size)!;
    
    // Направляющие векторы для двух линий
    final v1 = l1End - l1Start;
    final v2 = l2End - l2Start;
    
    // Нормализуем векторы
    final mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy);
    final mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy);
    
    if (mag1 == 0 || mag2 == 0) return 0.0;
    
    // Вычисляем угол между линиями
    final dot = v1.dx * v2.dx + v1.dy * v2.dy;
    final cosAngle = dot / (mag1 * mag2);
    final clampedCos = cosAngle.clamp(-1.0, 1.0);
    final angleRad = acos(clampedCos);
    final angleDeg = angleRad * 180 / pi;
    
    // Угол Кобба - это меньший из двух углов (угол или 180 - угол)
    return angleDeg > 90 ? 180 - angleDeg : angleDeg;
  }
}

// Класс для рисования линейки
class RulerPainter extends CustomPainter {
  final List<Offset> currentPoints; // Текущие точки для рисования (в scene coordinates)
  final List<RulerLine> completedLines; // Завершенные линии (в относительных координатах)
  final double pixelSpacing;
  final int? selectedIndex; // Индекс выбранной линии
  final Size? imageSize; // Размер исходного изображения для нормализации
  final double rotationAngle; // Угол поворота изображения в градусах
  
  RulerPainter({
    required this.currentPoints, 
    required this.completedLines,
    required this.pixelSpacing,
    this.selectedIndex,
    this.imageSize,
    this.rotationAngle = 0.0,
  });
  @override
  void paint(Canvas canvas, Size size) {
    try {
      // Проверяем корректность pixelSpacing
      final safePixelSpacing = pixelSpacing.isFinite && pixelSpacing > 0 ? pixelSpacing : 1.0;
    
      // Применяем поворот к canvas, если есть
      if (rotationAngle != 0.0) {
        canvas.save();
        final center = Offset(size.width / 2, size.height / 2);
        canvas.translate(center.dx, center.dy);
        canvas.rotate(rotationAngle * 3.14159 / 180);
        canvas.translate(-center.dx, -center.dy);
      }
    
      // Рисуем все завершенные линии
      // Важно: используем размер canvas для отрисовки, так как scene coordinates зависят от размера canvas
      // Относительные координаты (0.0-1.0) преобразуются в абсолютные используя размер canvas
      for (int i = 0; i < completedLines.length; i++) {
        final line = completedLines[i];
        final isSelected = selectedIndex == i;
        final color = isSelected ? Colors.orange : Colors.yellow;
        final paint = Paint()..color = color..strokeWidth = 1.0..style = PaintingStyle.stroke;
        final fillPaint = Paint()..color = color..style = PaintingStyle.fill;
        // Преобразуем относительные координаты в абсолютные используя размер canvas
        // Это гарантирует, что координаты останутся на месте при изменении размера окна
        final absStart = line.getAbsoluteStart(size);
        final absEnd = line.getAbsoluteEnd(size);
        // Для вычисления расстояния используем размер изображения, если он доступен
        final distanceSize = imageSize ?? size;
        _drawRulerLine(canvas, absStart, absEnd, safePixelSpacing, paint, fillPaint, i + 1, isSelected, line, distanceSize);
      }
      
      // Рисуем текущие точки и линию (если есть)
      if (currentPoints.isNotEmpty) {
        // Объявляем paint и fillPaint для текущих точек
        final paint = Paint()..color = Colors.yellow..strokeWidth = 1.0..style = PaintingStyle.stroke;
        final fillPaint = Paint()..color = Colors.yellow..style = PaintingStyle.fill;
        
        // Рисуем точки
        for (var point in currentPoints) { 
          canvas.drawCircle(point, 3, fillPaint);
          canvas.drawCircle(point, 3, paint..color = Colors.black);
        }
        
        // Рисуем линию и измерения
        if (currentPoints.length > 1) {
          _drawRulerLine(canvas, currentPoints[0], currentPoints[1], safePixelSpacing, paint, fillPaint, completedLines.length + 1, false, null, size);
        }
      }
      
      // Восстанавливаем canvas после поворота
      if (rotationAngle != 0.0) {
        canvas.restore();
      }
    } catch (e) {
      print("Ошибка в RulerPainter: $e");
      // В случае ошибки просто не рисуем ничего
    }
  }
  
  void _drawRulerLine(Canvas canvas, Offset start, Offset end, double safePixelSpacing, Paint paint, Paint fillPaint, int lineNumber, bool isSelected, RulerLine? line, Size size) {
    // Основная линия (тонкая)
    canvas.drawLine(start, end, paint);
    
    // Перпендикулярные линии на концах для точности
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = sqrt(dx * dx + dy * dy);
    
    if (length > 0) {
      // Нормализованный перпендикулярный вектор
      final perpX = -dy / length * 8;
      final perpY = dx / length * 8;
      
      // Рисуем перпендикулярные линии (тонкие)
      canvas.drawLine(
        Offset(start.dx - perpX, start.dy - perpY),
        Offset(start.dx + perpX, start.dy + perpY),
        paint
      );
      canvas.drawLine(
        Offset(end.dx - perpX, end.dy - perpY),
        Offset(end.dx + perpX, end.dy + perpY),
        paint
      );
    }
    
    // Вычисляем расстояние
    final pixelDistance = line != null ? line.getDistance(size) : (end - start).distance;
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
    
    // Рисуем индикатор перетаскивания для выбранной линейки
    if (isSelected) {
      final dragHandleSize = 20.0;
      final dragHandleX = (start.dx + end.dx) / 2 - dragHandleSize / 2;
      final dragHandleY = (start.dy + end.dy) / 2 - dragHandleSize - 5;
      final dragHandleRect = Rect.fromLTWH(dragHandleX, dragHandleY, dragHandleSize, dragHandleSize);
      
      // Рисуем фон индикатора
      canvas.drawRect(dragHandleRect, Paint()
        ..color = Colors.orange
        ..style = PaintingStyle.fill);
      canvas.drawRect(dragHandleRect, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
      
      // Рисуем стрелочки (крестик из стрелок)
      final centerX = dragHandleX + dragHandleSize / 2;
      final centerY = dragHandleY + dragHandleSize / 2;
      final arrowSize = 6.0;
      
      // Верхняя стрелка
      canvas.drawLine(
        Offset(centerX, centerY - arrowSize),
        Offset(centerX, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX - 2, centerY - 2),
        Offset(centerX, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX + 2, centerY - 2),
        Offset(centerX, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      
      // Нижняя стрелка
      canvas.drawLine(
        Offset(centerX, centerY),
        Offset(centerX, centerY + arrowSize),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX, centerY),
        Offset(centerX - 2, centerY + 2),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX, centerY),
        Offset(centerX + 2, centerY + 2),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    // Для надежности всегда перерисовываем, так как списки могут мутировать по месту
    return true;
  }
}

// Класс для рисования углов
class AnglePainter extends CustomPainter {
  final List<Offset> currentPoints; // Текущие точки для рисования (0-3 точки для обычного угла, 0-4 для Кобба, в scene coordinates)
  final List<AngleMeasurement> completedAngles; // Завершенные измерения углов (в относительных координатах)
  final int? selectedIndex; // Индекс выбранного угла
  final Size? imageSize; // Размер исходного изображения для нормализации
  final double rotationAngle; // Угол поворота изображения в градусах
  final AngleType currentAngleType; // Текущий тип угла для предварительного просмотра
  
  AnglePainter({
    required this.currentPoints,
    required this.completedAngles,
    this.selectedIndex,
    this.imageSize,
    this.rotationAngle = 0.0,
    this.currentAngleType = AngleType.normal,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    try {
      // Применяем поворот к canvas, если есть
      if (rotationAngle != 0.0) {
        canvas.save();
        final center = Offset(size.width / 2, size.height / 2);
        canvas.translate(center.dx, center.dy);
        canvas.rotate(rotationAngle * 3.14159 / 180);
        canvas.translate(-center.dx, -center.dy);
      }
      
      // Важно: используем размер canvas для отрисовки, так как scene coordinates зависят от размера canvas
      // Относительные координаты (0.0-1.0) преобразуются в абсолютные используя размер canvas
      // Рисуем все завершенные углы
      for (int i = 0; i < completedAngles.length; i++) {
        final angle = completedAngles[i];
        final isSelected = selectedIndex == i;
        final color = isSelected ? Colors.orange : Colors.cyan;
        final paint = Paint()..color = color..strokeWidth = 1.0..style = PaintingStyle.stroke;
        final fillPaint = Paint()..color = color..style = PaintingStyle.fill;
        // Преобразуем относительные координаты в абсолютные используя размер canvas
        // Это гарантирует, что координаты останутся на месте при изменении размера окна
        final absVertex = angle.getAbsoluteVertex(size);
        final absPoint1 = angle.getAbsolutePoint1(size);
        final absPoint2 = angle.getAbsolutePoint2(size);
        final absLine1End = angle.getAbsoluteLine1End(size);
        final absLine2End = angle.getAbsoluteLine2End(size);
        // Для вычисления угла используем размер изображения, если он доступен
        final angleSize = imageSize ?? size;
        final angleDeg = angle.getAngleDegrees(angleSize);
        
        if (angle.type == AngleType.cobb && absLine1End != null && absLine2End != null) {
          _drawCobbAngle(canvas, absPoint1, absLine1End, absPoint2, absLine2End, paint, fillPaint, i + 1, angleDeg, isSelected);
        } else {
          _drawAngle(canvas, absVertex, absPoint1, absPoint2, paint, fillPaint, i + 1, angleDeg, isSelected);
        }
      }
      
      // Рисуем текущие точки и углы (если есть)
      if (currentPoints.isNotEmpty) {
        // Объявляем paint и fillPaint для текущих точек
        final paint = Paint()..color = Colors.cyan..strokeWidth = 1.0..style = PaintingStyle.stroke;
        final fillPaint = Paint()..color = Colors.cyan..style = PaintingStyle.fill;
        
        // Рисуем точки
        for (var point in currentPoints) {
          canvas.drawCircle(point, 3, fillPaint);
          canvas.drawCircle(point, 3, paint..color = Colors.black);
        }
        
        // Рисуем предварительный просмотр угла
        if (currentAngleType == AngleType.normal) {
          // Обычный угол: 3 точки
          if (currentPoints.length == 2) {
            // Рисуем линию от первой точки ко второй (вершине)
            canvas.drawLine(currentPoints[0], currentPoints[1], paint);
          } else if (currentPoints.length == 3) {
            // Рисуем полный угол
            final vertex = currentPoints[1]; // Вершина - вторая точка
            final point1 = currentPoints[0]; // Первая точка на первом луче
            final point2 = currentPoints[2]; // Третья точка на втором луче
            
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
            
            _drawAngle(canvas, vertex, point1, point2, paint, fillPaint, completedAngles.length + 1, angleDeg, false);
          }
        } else {
          // Угол Кобба: 4 точки
          if (currentPoints.length == 2) {
            // Рисуем первую линию
            canvas.drawLine(currentPoints[0], currentPoints[1], paint);
          } else if (currentPoints.length == 3) {
            // Рисуем первую линию и начало второй
            canvas.drawLine(currentPoints[0], currentPoints[1], paint);
          } else if (currentPoints.length == 4) {
            // Рисуем обе линии и вычисляем угол Кобба
            final l1Start = currentPoints[0];
            final l1End = currentPoints[1];
            final l2Start = currentPoints[2];
            final l2End = currentPoints[3];
            
            // Вычисляем угол Кобба для предварительного просмотра
            final v1 = l1End - l1Start;
            final v2 = l2End - l2Start;
            final mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy);
            final mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy);
            double angleDeg = 0.0;
            if (mag1 > 0 && mag2 > 0) {
              final dot = v1.dx * v2.dx + v1.dy * v2.dy;
              final cosAngle = (dot / (mag1 * mag2)).clamp(-1.0, 1.0);
              final angle = acos(cosAngle) * 180 / pi;
              angleDeg = angle > 90 ? 180 - angle : angle;
            }
            
            _drawCobbAngle(canvas, l1Start, l1End, l2Start, l2End, paint, fillPaint, completedAngles.length + 1, angleDeg, false);
          }
        }
      }
      
      // Восстанавливаем canvas после поворота
      if (rotationAngle != 0.0) {
        canvas.restore();
      }
    } catch (e) {
      print("Ошибка в AnglePainter: $e");
    }
  }
  
  void _drawAngle(Canvas canvas, Offset vertex, Offset point1, Offset point2, Paint paint, Paint fillPaint, int angleNumber, double angleDegrees, bool isSelected) {
    // Рисуем два луча от вершины (тонкие)
    canvas.drawLine(vertex, point1, paint);
    canvas.drawLine(vertex, point2, paint);
    
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
      
      // Рисуем дугу (тонкая)
      final rect = Rect.fromCircle(center: vertex, radius: arcRadius);
      canvas.drawArc(
        rect,
        angle1,
        angle2 - angle1,
        false,
        paint,
      );
    }
    
    // Рисуем вершину угла (меньше размер для тонкого дизайна)
    canvas.drawCircle(vertex, 5, fillPaint);
    canvas.drawCircle(vertex, 5, Paint()..color = Colors.black..strokeWidth = 1.0);
    
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
    
    // Рисуем индикатор перетаскивания для выбранного угла
    if (isSelected) {
      final dragHandleSize = 20.0;
      final dragHandleX = vertex.dx - dragHandleSize / 2;
      final dragHandleY = vertex.dy - dragHandleSize - 5;
      final dragHandleRect = Rect.fromLTWH(dragHandleX, dragHandleY, dragHandleSize, dragHandleSize);
      
      // Рисуем фон индикатора
      canvas.drawRect(dragHandleRect, Paint()
        ..color = Colors.orange
        ..style = PaintingStyle.fill);
      canvas.drawRect(dragHandleRect, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
      
      // Рисуем стрелочки (крестик из стрелок)
      final centerX = dragHandleX + dragHandleSize / 2;
      final centerY = dragHandleY + dragHandleSize / 2;
      final arrowSize = 6.0;
      
      // Верхняя стрелка
      canvas.drawLine(
        Offset(centerX, centerY - arrowSize),
        Offset(centerX, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX - 2, centerY - 2),
        Offset(centerX, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX + 2, centerY - 2),
        Offset(centerX, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      
      // Нижняя стрелка
      canvas.drawLine(
        Offset(centerX, centerY),
        Offset(centerX, centerY + arrowSize),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX, centerY),
        Offset(centerX - 2, centerY + 2),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX, centerY),
        Offset(centerX + 2, centerY + 2),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
    }
  }
  
  void _drawCobbAngle(Canvas canvas, Offset line1Start, Offset line1End, Offset line2Start, Offset line2End, Paint paint, Paint fillPaint, int angleNumber, double angleDegrees, bool isSelected) {
    // Рисуем две линии
    canvas.drawLine(line1Start, line1End, paint..strokeWidth = 2.0);
    canvas.drawLine(line2Start, line2End, paint..strokeWidth = 2.0);
    
    // Рисуем пунктирную линию между концами (line1End и line2End)
    final dashedPaint = Paint()
      ..color = paint.color.withOpacity(0.5)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    _drawDashedLine(canvas, line1End, line2End, dashedPaint);
    
    // Рисуем конечные точки линий
    canvas.drawCircle(line1Start, 4, fillPaint);
    canvas.drawCircle(line1Start, 4, Paint()..color = Colors.black..strokeWidth = 1.0);
    canvas.drawCircle(line1End, 4, fillPaint);
    canvas.drawCircle(line1End, 4, Paint()..color = Colors.black..strokeWidth = 1.0);
    canvas.drawCircle(line2Start, 4, fillPaint);
    canvas.drawCircle(line2Start, 4, Paint()..color = Colors.black..strokeWidth = 1.0);
    canvas.drawCircle(line2End, 4, fillPaint);
    canvas.drawCircle(line2End, 4, Paint()..color = Colors.black..strokeWidth = 1.0);
    
    // Рисуем текст с углом Кобба
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'Cobb ∠$angleNumber: ${angleDegrees.toStringAsFixed(1)}°',
        style: const TextStyle(
          color: Colors.cyan,
          fontSize: 14,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.black87,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    
    // Позиционируем текст между двумя линиями
    final midPoint = Offset(
      (line1Start.dx + line1End.dx + line2Start.dx + line2End.dx) / 4,
      (line1Start.dy + line1End.dy + line2Start.dy + line2End.dy) / 4,
    );
    
    final textOffset = Offset(
      midPoint.dx + 20,
      midPoint.dy - textPainter.height / 2,
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
    
    // Рисуем индикатор перетаскивания для выбранного угла
    if (isSelected) {
      final dragHandleSize = 20.0;
      final dragHandleX = midPoint.dx - dragHandleSize / 2;
      final dragHandleY = midPoint.dy - dragHandleSize - 5;
      final dragHandleRect = Rect.fromLTWH(dragHandleX, dragHandleY, dragHandleSize, dragHandleSize);
      
      // Рисуем фон индикатора
      canvas.drawRect(dragHandleRect, Paint()
        ..color = Colors.orange
        ..style = PaintingStyle.fill);
      canvas.drawRect(dragHandleRect, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
      
      // Рисуем стрелочки (крестик из стрелок)
      final centerX = dragHandleX + dragHandleSize / 2;
      final centerY = dragHandleY + dragHandleSize / 2;
      final arrowSize = 6.0;
      
      // Вертикальные стрелки
      canvas.drawLine(
        Offset(centerX, centerY - arrowSize),
        Offset(centerX, centerY + arrowSize),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX - 2, centerY - 4),
        Offset(centerX, centerY - arrowSize),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX + 2, centerY - 4),
        Offset(centerX, centerY - arrowSize),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX - 2, centerY + 4),
        Offset(centerX, centerY + arrowSize),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX + 2, centerY + 4),
        Offset(centerX, centerY + arrowSize),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      
      // Горизонтальные стрелки
      canvas.drawLine(
        Offset(centerX - arrowSize, centerY),
        Offset(centerX + arrowSize, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX - 4, centerY - 2),
        Offset(centerX - arrowSize, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX - 4, centerY + 2),
        Offset(centerX - arrowSize, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX + 4, centerY - 2),
        Offset(centerX + arrowSize, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
      canvas.drawLine(
        Offset(centerX + 4, centerY + 2),
        Offset(centerX + arrowSize, centerY),
        Paint()..color = Colors.white..strokeWidth = 2.0
      );
    }
  }
  
  // Вспомогательная функция для рисования пунктирной линии
  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashWidth = 5.0;
    const dashSpace = 3.0;
    
    final delta = end - start;
    final distance = delta.distance;
    final normalizedDelta = delta / distance;
    
    double currentDistance = 0;
    while (currentDistance < distance) {
      final segmentStart = start + normalizedDelta * currentDistance;
      final nextDistance = currentDistance + dashWidth;
      final segmentEnd = nextDistance > distance
          ? end
          : start + normalizedDelta * nextDistance;
      
      canvas.drawLine(segmentStart, segmentEnd, paint);
      currentDistance = nextDistance + dashSpace;
    }
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

// Класс для рисования лупы
class MagnifierPainter extends CustomPainter {
  final Offset? position;
  final double size;
  final double zoom;
  final Matrix4? transformMatrix;
  final ui.Image? decodedImage;
  final double pixelSpacing; // Пиксельный размер для масштабной линейки
  final double brightness; // Яркость
  final bool isInverted; // Инверсия
  final double rotationAngle; // Угол поворота в градусах
  
  MagnifierPainter({
    required this.position,
    required this.size,
    required this.zoom,
    this.transformMatrix,
    this.decodedImage,
    this.pixelSpacing = 1.0,
    this.brightness = 1.0,
    this.isInverted = false,
    this.rotationAngle = 0.0,
  });
  
  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (position == null || decodedImage == null) return;
    
    try {
      final imageWidth = decodedImage!.width.toDouble();
      final imageHeight = decodedImage!.height.toDouble();
      
      // Вычисляем реальный размер изображения на экране с учетом BoxFit.contain
      final imageAspect = imageWidth / imageHeight;
      final canvasAspect = canvasSize.width / canvasSize.height;
      
      double displayedImageWidth;
      double displayedImageHeight;
      double imageOffsetX = 0;
      double imageOffsetY = 0;
      
      if (imageAspect > canvasAspect) {
        // Изображение шире - ограничено по ширине
        displayedImageWidth = canvasSize.width;
        displayedImageHeight = canvasSize.width / imageAspect;
        imageOffsetY = (canvasSize.height - displayedImageHeight) / 2;
      } else {
        // Изображение выше - ограничено по высоте
        displayedImageHeight = canvasSize.height;
        displayedImageWidth = canvasSize.height * imageAspect;
        imageOffsetX = (canvasSize.width - displayedImageWidth) / 2;
      }
      
      // Преобразуем позицию курсора в координаты изображения с учетом трансформации
      Offset? imagePosition;
      if (transformMatrix != null) {
        final invertedMatrix = Matrix4.inverted(transformMatrix!);
        final transformedPosition = MatrixUtils.transformPoint(invertedMatrix, position!);
        // Преобразуем из координат canvas в координаты исходного изображения
        // Учитываем поворот изображения
        double relativeX = (transformedPosition.dx - imageOffsetX) / displayedImageWidth;
        double relativeY = (transformedPosition.dy - imageOffsetY) / displayedImageHeight;
        
        // Применяем обратный поворот к координатам
        if (rotationAngle != 0.0) {
          final rotationRad = -rotationAngle * 3.14159 / 180; // Обратный поворот
          final centerX = 0.5;
          final centerY = 0.5;
          final dx = relativeX - centerX;
          final dy = relativeY - centerY;
          final cosR = cos(rotationRad);
          final sinR = sin(rotationRad);
          relativeX = centerX + dx * cosR - dy * sinR;
          relativeY = centerY + dx * sinR + dy * cosR;
        }
        
        imagePosition = Offset(
          relativeX * imageWidth,
          relativeY * imageHeight,
        );
      } else {
        // Без трансформации
        double relativeX = (position!.dx - imageOffsetX) / displayedImageWidth;
        double relativeY = (position!.dy - imageOffsetY) / displayedImageHeight;
        
        // Применяем обратный поворот к координатам
        if (rotationAngle != 0.0) {
          final rotationRad = -rotationAngle * 3.14159 / 180; // Обратный поворот
          final centerX = 0.5;
          final centerY = 0.5;
          final dx = relativeX - centerX;
          final dy = relativeY - centerY;
          final cosR = cos(rotationRad);
          final sinR = sin(rotationRad);
          relativeX = centerX + dx * cosR - dy * sinR;
          relativeY = centerY + dx * sinR + dy * cosR;
        }
        
        imagePosition = Offset(
          relativeX * imageWidth,
          relativeY * imageHeight,
        );
      }
      
      // Проверяем, что imagePosition находится в пределах изображения
      if (imagePosition.dx < 0 || imagePosition.dx > imageWidth ||
          imagePosition.dy < 0 || imagePosition.dy > imageHeight) {
        return; // Курсор вне изображения
      }
      
      // Размер области для захвата (в координатах исходного изображения)
      // size - размер лупы на экране в пикселях экрана (например, 200px)
      // zoom - коэффициент увеличения (например, 2.0 означает 2x увеличение)
      // Размер области на экране без увеличения = size / zoom
      // Но нужно пересчитать в пиксели исходного изображения с учетом масштаба
      // Масштаб = imageWidth / displayedImageWidth
      final scaleFactor = imageWidth / displayedImageWidth;
      final captureSizeOnScreen = size / zoom; // Размер области на экране без увеличения
      final captureSizeInImagePixels = captureSizeOnScreen * scaleFactor;
      final halfCapture = captureSizeInImagePixels / 2;
      
      // Вычисляем область для увеличения в координатах исходного изображения
      final sourceRect = Rect.fromLTWH(
        (imagePosition.dx - halfCapture).clamp(0.0, imageWidth),
        (imagePosition.dy - halfCapture).clamp(0.0, imageHeight),
        captureSizeInImagePixels.clamp(0.0, imageWidth - (imagePosition.dx - halfCapture).clamp(0.0, imageWidth)),
        captureSizeInImagePixels.clamp(0.0, imageHeight - (imagePosition.dy - halfCapture).clamp(0.0, imageHeight)),
      );
      
      // Позиция лупы на экране (смещена от курсора вверх и влево)
      final magnifierOffset = Offset(
        (position!.dx - size / 2).clamp(0.0, canvasSize.width - size),
        (position!.dy - size / 2 - 30).clamp(0.0, canvasSize.height - size),
      );
      
      // Область для отрисовки увеличенного изображения
      final destRect = Rect.fromLTWH(
        magnifierOffset.dx,
        magnifierOffset.dy,
        size,
        size,
      );
      
      // Сохраняем состояние canvas
      canvas.save();
      
      // Обрезаем canvas до области лупы
      canvas.clipRect(destRect);
      
      // Применяем фильтры для яркости и инверсии
      final colorFilter = _createColorFilter();
      
      // Рисуем увеличенное изображение с фильтрами
      final paint = Paint()
        ..filterQuality = FilterQuality.high
        ..colorFilter = colorFilter;
      
      canvas.drawImageRect(
        decodedImage!,
        sourceRect,
        destRect,
        paint,
      );
      
      // Восстанавливаем состояние canvas
      canvas.restore();
      
      // Рисуем рамку
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(destRect, borderPaint);
      
      // Рисуем сетку поверх изображения
      final gridPaint = Paint()
        ..color = Colors.white.withOpacity(0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      
      final gridStep = size / 4; // 4x4 сетка
      for (int i = 1; i < 4; i++) {
        // Вертикальные линии
        canvas.drawLine(
          Offset(magnifierOffset.dx + i * gridStep, magnifierOffset.dy),
          Offset(magnifierOffset.dx + i * gridStep, magnifierOffset.dy + size),
          gridPaint,
        );
        // Горизонтальные линии
        canvas.drawLine(
          Offset(magnifierOffset.dx, magnifierOffset.dy + i * gridStep),
          Offset(magnifierOffset.dx + size, magnifierOffset.dy + i * gridStep),
          gridPaint,
        );
      }
      
      // Рисуем подписи на осях
      final textStyle = TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontWeight: FontWeight.bold,
        shadows: [
          Shadow(
            offset: Offset(1, 1),
            blurRadius: 2,
            color: Colors.black,
          ),
        ],
      );
      final textPainter = TextPainter(
        textDirection: TextDirection.ltr,
      );
      
      // Вычисляем размер в см для масштабной линейки
      // Используем captureSizeInImagePixels (реальный размер области в пикселях исходного изображения)
      // pixelSpacing - это размер пикселя в мм/пиксель
      // Размер области в мм = количество пикселей * размер пикселя в мм
      final actualCaptureSize = captureSizeInImagePixels;
      final sizeInMm = actualCaptureSize * pixelSpacing;
      // Переводим мм в см (1 см = 10 мм)
      final sizeInCm = sizeInMm / 10.0;
      
      // Отладочный вывод (можно убрать после проверки)
      // print("Лупа: actualCaptureSize=$actualCaptureSize px, pixelSpacing=$pixelSpacing мм/px, sizeInMm=$sizeInMm мм, sizeInCm=$sizeInCm см");
      
      // Подписи по горизонтали (0, 1, 2, 3, 4 см)
      for (int i = 0; i <= 4; i++) {
        final x = magnifierOffset.dx + i * gridStep;
        final cmValue = i * sizeInCm / 4;
        String label;
        if (i == 0) {
          label = '0см';
        } else {
          // Форматируем значение: показываем с одним знаком после запятой, убираем лишние нули
          String formattedValue;
          if (cmValue == cmValue.roundToDouble()) {
            // Если значение целое, показываем без десятичной части
            formattedValue = cmValue.toInt().toString();
          } else {
            // Если есть дробная часть, показываем с одним знаком после запятой
            formattedValue = cmValue.toStringAsFixed(1);
            // Убираем лишние нули в конце
            formattedValue = formattedValue.replaceAll(RegExp(r'\.?0+$'), '');
          }
          label = '$formattedValueсм';
        }
        textPainter.text = TextSpan(
          text: label,
          style: textStyle,
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(x - textPainter.width / 2, magnifierOffset.dy + size + 2),
        );
      }
      
      // Подписи по вертикали (0, 1, 2, 3, 4 см)
      for (int i = 0; i <= 4; i++) {
        final y = magnifierOffset.dy + i * gridStep;
        final cmValue = i * sizeInCm / 4;
        String label;
        if (i == 0) {
          label = '0см';
        } else {
          // Форматируем значение: показываем с одним знаком после запятой, убираем лишние нули
          String formattedValue;
          if (cmValue == cmValue.roundToDouble()) {
            // Если значение целое, показываем без десятичной части
            formattedValue = cmValue.toInt().toString();
          } else {
            // Если есть дробная часть, показываем с одним знаком после запятой
            formattedValue = cmValue.toStringAsFixed(1);
            // Убираем лишние нули в конце
            formattedValue = formattedValue.replaceAll(RegExp(r'\.?0+$'), '');
          }
          label = '$formattedValueсм';
        }
        textPainter.text = TextSpan(
          text: label,
          style: textStyle,
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(magnifierOffset.dx - textPainter.width - 2, y - textPainter.height / 2),
        );
      }
      
    } catch (e) {
      print("Ошибка в MagnifierPainter: $e");
    }
  }
  
  // Создает ColorFilter для яркости и инверсии
  ColorFilter? _createColorFilter() {
    if (brightness == 1.0 && !isInverted) {
      return null; // Нет необходимости в фильтре
    }
    
    // Матрица для яркости
    final brightnessMatrix = <double>[
      brightness, 0.0, 0.0, 0.0, 0.0,  // Red
      0.0, brightness, 0.0, 0.0, 0.0,  // Green  
      0.0, 0.0, brightness, 0.0, 0.0,  // Blue
      0.0, 0.0, 0.0, 1.0, 0.0,            // Alpha
    ];
    
    if (isInverted) {
      // Матрица для инверсии
      final invertMatrix = <double>[
        -1.0, 0.0, 0.0, 0.0, 255.0,  // Инверсия красного
        0.0, -1.0, 0.0, 0.0, 255.0,  // Инверсия зеленого
        0.0, 0.0, -1.0, 0.0, 255.0,  // Инверсия синего
        0.0, 0.0, 0.0, 1.0, 0.0,     // Альфа без изменений
      ];
      
      // Комбинируем матрицы: сначала применяем яркость, потом инверсию
      // Для цветовых фильтров: результат = invert(brightness(input))
      // Это означает: invertMatrix * brightnessMatrix
      final combinedMatrix = List<double>.filled(20, 0.0);
      for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
          combinedMatrix[i * 5 + j] = invertMatrix[i * 5 + j] * brightnessMatrix[j * 5 + j];
        }
        // Последний столбец (смещение)
        combinedMatrix[i * 5 + 4] = invertMatrix[i * 5 + 4];
      }
      return ColorFilter.matrix(combinedMatrix);
    } else {
      return ColorFilter.matrix(brightnessMatrix);
    }
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is! MagnifierPainter) return true;
    return oldDelegate.position != position ||
           oldDelegate.size != size ||
           oldDelegate.zoom != zoom ||
           oldDelegate.decodedImage != decodedImage ||
           oldDelegate.pixelSpacing != pixelSpacing ||
           oldDelegate.brightness != brightness ||
           oldDelegate.isInverted != isInverted ||
           oldDelegate.rotationAngle != rotationAngle;
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
  final bool calibrationMode;
  
  const HomeScreen({super.key, this.calibrationMode = false});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
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
  
  // Режим калибровки
  bool _isCalibrationMode = false;
  List<Offset> _calibrationPoints = []; // Точки для калибровки

  // Линейка: текущие точки (0-1 точка) для активного измерения
  List<Offset> _rulerPoints = [];
  
  // Линейка: все завершенные измерения (L1, L2, L3...)
  List<RulerLine> _completedRulerLines = [];
  
  // Угол: текущие точки (0-3 точки для обычного угла, 0-4 точки для Кобба)
  List<Offset> _anglePoints = [];
  
  // Угол: все завершенные измерения (∠1, ∠2, ∠3...)
  List<AngleMeasurement> _completedAngles = [];
  
  // Текущий тип измерения угла
  AngleType _currentAngleType = AngleType.normal;
  
  // Выделение и перетаскивание
  int? _selectedRulerIndex; // Индекс выбранной линейки
  int? _selectedAngleIndex; // Индекс выбранного угла
  int? _selectedTextIndex; // Индекс выбранной текстовой аннотации
  int? _selectedArrowIndex; // Индекс выбранной стрелки
  bool _isDraggingRuler = false; // Флаг перетаскивания линейки
  bool _isDraggingAngle = false; // Флаг перетаскивания угла
  bool _isDraggingText = false; // Флаг перетаскивания текстовой аннотации
  bool _isDraggingArrow = false; // Флаг перетаскивания стрелки
  Offset? _dragOffset; // Смещение при перетаскивании
  bool _hasMeasurementNearPointer = false; // Флаг наличия измерения рядом с указателем (для блокировки pan)
  
  // Лупа: позиция курсора для отображения увеличенной области
  Offset? _magnifierPosition;
  bool _isMagnifierPressed = false; // Флаг зажатой ЛКМ для лупы
  bool _isRightButtonPressed = false; // Флаг зажатой ПКМ для pan в режиме brightness
  double _magnifierSize = 200.0; // Размер лупы в пикселях
  double _magnifierZoom = 2.0; // Увеличение
  ui.Image? _decodedImage; // Кэшированное декодированное изображение для лупы
  
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
  
  // Кэш для размера canvas
  Size? _cachedCanvasSize;
  bool _canvasSizeCacheValid = false;
  
  // Переменные для яркости
  double _brightness = 1.0;
  double _initialBrightness = 1.0;
  // Переменные для контраста
  double _contrast = 1.0;
  double _initialContrast = 1.0;
  // Переменные для отслеживания перетаскивания яркости/контраста
  Offset? _brightnessDragStart;
  double? _brightnessAtDragStart;
  double? _contrastAtDragStart;
  // Ключ для захвата экрана (PNG)
  final GlobalKey _captureKey = GlobalKey();
  // Ключ для получения размера canvas
  final GlobalKey _canvasSizeKey = GlobalKey();
  
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
      _magnifierPosition = null; // Очищаем позицию лупы
      _isMagnifierPressed = false; // Сбрасываем флаг зажатой ЛКМ
      _isRightButtonPressed = false; // Сбрасываем флаг зажатой ПКМ
      _selectedRulerIndex = null; // Сбрасываем выделение линеек
      _selectedAngleIndex = null; // Сбрасываем выделение углов
      _selectedTextIndex = null; // Сбрасываем выделение текстовых аннотаций
      _selectedArrowIndex = null; // Сбрасываем выделение стрелок
      _isDraggingRuler = false;
      _isDraggingAngle = false;
      _isDraggingText = false;
      _isDraggingArrow = false;
      _dragOffset = null;
      // Сбрасываем переменные перетаскивания яркости/контраста
      _brightnessDragStart = null;
      _brightnessAtDragStart = null;
      _contrastAtDragStart = null;
      
      // Переключаем инструмент
      _currentTool = newTool;
      
      print('Инструмент переключен на: $newTool');
    });
  }
  
  // Обработка движения мыши для лупы
  void _handlePointerMove(PointerEvent event) {
    if (_currentTool == ToolMode.magnifier && _imageBytes != null && _isMagnifierPressed) {
      setState(() {
        _magnifierPosition = event.localPosition;
      });
    }
  }
  
  // Обработка нажатия ЛКМ для лупы
  void _handlePointerDown(PointerDownEvent event) {
    if (_currentTool == ToolMode.magnifier && _imageBytes != null && event.buttons == 1) {
      setState(() {
        _isMagnifierPressed = true;
        _magnifierPosition = event.localPosition;
      });
    }
  }
  
  // Обработка отпускания ЛКМ для лупы
  void _handlePointerUp(PointerUpEvent event) {
    if (_currentTool == ToolMode.magnifier) {
      setState(() {
        _isMagnifierPressed = false;
        _magnifierPosition = null;
      });
    }
  }
  
  // Обработка выхода мыши из области для лупы
  void _handlePointerExit(PointerEvent event) {
    if (_currentTool == ToolMode.magnifier) {
      setState(() {
        _isMagnifierPressed = false;
        _magnifierPosition = null;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeHotkeys();
    _initializeEmbeddedServer();
    
    // Режим калибровки теперь активируется только через настройки
    
    // Откладываем инициализацию кэша матрицы до первого использования
    _matrixCacheValid = false;
    
    // Слушаем изменения трансформации для инвалидации кэша
    _transformationController.addListener(() {
      _matrixCacheValid = false;
    });
    
    // Инвалидируем кэш размера canvas при изменении размера
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _canvasSizeCacheValid = false;
    });
    
    // Слушаем изменения размера окна
    WidgetsBinding.instance.addObserver(this);
  }
  
  Future<void> _loadPixelSpacing() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pixelSpacing = prefs.getDouble('pixel_spacing_row');
      if (pixelSpacing != null) {
        setState(() {
          _pixelSpacingRow = pixelSpacing;
        });
      }
    } catch (e) {
      print('Ошибка при загрузке pixelSpacing: $e');
    }
  }
  
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Инвалидируем кэш матрицы и размера canvas при изменении размера окна
    setState(() {
      _matrixCacheValid = false;
      _canvasSizeCacheValid = false;
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
      _contrast = _initialContrast;
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
      _decodedImage?.dispose();
      _decodedImage = null; 
      _originalImageBytes = null; // Сбрасываем исходное изображение
      _patientName = null; 
      _dicomTags = {};
      _dicomReport = null;
      _rulerPoints = []; 
      _completedRulerLines = []; // Сбрасываем завершенные линии
      _anglePoints = []; // Сбрасываем текущие точки углов
      _completedAngles = []; // Сбрасываем завершенные углы
      _textAnnotations = []; // Сбрасываем текстовые аннотации
      _arrowAnnotations = []; // Сбрасываем стрелки
      _arrowPoints = []; // Сбрасываем точки для стрелок
      _isDragging = false; // Сбрасываем флаг перетаскивания
      _actionHistory.clear(); // Очищаем историю действий
      _brightness = 1.0;
      _initialBrightness = 1.0;
      _contrast = 1.0;
      _initialContrast = 1.0;
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
            // pixel_spacing_row может отсутствовать, если используется сохраненное значение
            
            print("Все необходимые поля присутствуют в ответе");
            
            // Декодируем изображение в отдельном изоляте для предотвращения блокировки UI
            try {
              final imageBytes = await compute(_decodeImageInIsolate, data['image_base64']);
              
              // Декодируем изображение для лупы
              ui.Image? decodedImage;
              try {
                final codec = await ui.instantiateImageCodec(imageBytes);
                final frame = await codec.getNextFrame();
                decodedImage = frame.image;
              } catch (e) {
                print("Ошибка при декодировании изображения для лупы: $e");
              }
              
              // Загружаем pixelSpacing из данных или из SharedPreferences (до setState)
              double pixelSpacingToUse;
              final pixelSpacingFromData = (data['pixel_spacing_row'] as num?)?.toDouble();
              if (pixelSpacingFromData != null) {
                pixelSpacingToUse = pixelSpacingFromData;
              } else {
                // Если в данных нет, загружаем из SharedPreferences
                final prefs = await SharedPreferences.getInstance();
                final savedPixelSpacing = prefs.getDouble('pixel_spacing_row');
                pixelSpacingToUse = savedPixelSpacing ?? _pixelSpacingRow;
              }
              
              setState(() {
                _imageBytes = imageBytes;
                _decodedImage = decodedImage; // Сохраняем декодированное изображение
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
                // Устанавливаем pixelSpacing
                _pixelSpacingRow = pixelSpacingToUse;
                _windowCenter = (data['window_center'] as num).toDouble();
                _windowWidth = (data['window_width'] as num).toDouble();
                _initialWC = _windowCenter;
                _initialWW = _windowWidth;
                _isLoading = false;
                
                print("Все данные успешно установлены");
              });
              
              // Загружаем сохраненные метаданные, если они есть
              // Загружаем метаданные и аннотации после установки изображения
              // Используем addPostFrameCallback, чтобы canvas успел отрендериться
              WidgetsBinding.instance.addPostFrameCallback((_) async {
              await _loadMetadata();
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


  // Преобразует scene coordinates в относительные координаты (0.0-1.0)
  // Использует размер canvas для нормализации
  Offset _sceneToRelativeCoordinates(Offset scenePoint, Size canvasSize) {
    if (canvasSize.width <= 0 || canvasSize.height <= 0) return Offset.zero;
    
    // Применяем обратный поворот к координатам клика, если изображение повернуто
    Offset rotatedPoint = scenePoint;
    if (_rotationAngle != 0.0) {
      final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
      final dx = scenePoint.dx - center.dx;
      final dy = scenePoint.dy - center.dy;
      final rotationRad = -_rotationAngle * 3.14159 / 180; // Обратный поворот
      final cosR = cos(rotationRad);
      final sinR = sin(rotationRad);
      rotatedPoint = Offset(
        center.dx + dx * cosR - dy * sinR,
        center.dy + dx * sinR + dy * cosR,
      );
    }
    
    return Offset(
      rotatedPoint.dx / canvasSize.width,
      rotatedPoint.dy / canvasSize.height,
    );
  }
  
  // Преобразует относительные координаты (0.0-1.0) в scene coordinates
  Offset _relativeToSceneCoordinates(Offset relativePoint, Size canvasSize) {
    return Offset(
      relativePoint.dx * canvasSize.width,
      relativePoint.dy * canvasSize.height,
    );
  }
  
  // Получает размер canvas для измерений
  // Используем реальный размер canvas для нормализации координат
  // Это гарантирует, что координаты останутся на месте при изменении размера окна
  Size _getCanvasSize() {
    // Используем кэш если он валиден
    if (_canvasSizeCacheValid && _cachedCanvasSize != null) {
      return _cachedCanvasSize!;
    }
    
    // Пытаемся получить размер canvas из RenderBox
    final renderBox = _canvasSizeKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      _cachedCanvasSize = renderBox.size;
      _canvasSizeCacheValid = true;
      return _cachedCanvasSize!;
    }
    // Если не удалось получить размер canvas, используем размер изображения как fallback
    if (_decodedImage != null) {
      _cachedCanvasSize = Size(_decodedImage!.width.toDouble(), _decodedImage!.height.toDouble());
      _canvasSizeCacheValid = true;
      return _cachedCanvasSize!;
    }
    // Если изображение не загружено, используем размер по умолчанию
    _cachedCanvasSize = const Size(1000, 1000);
    _canvasSizeCacheValid = true;
    return _cachedCanvasSize!;
  }

  // Проверяет, находится ли точка рядом с линией
  // point в scene coordinates
  int? _getRulerLineAtPoint(Offset point, double threshold) {
    final canvasSize = _getCanvasSize();
    for (int i = 0; i < _completedRulerLines.length; i++) {
      final line = _completedRulerLines[i];
      // Преобразуем относительные координаты в scene coordinates
      final absStart = line.getAbsoluteStart(canvasSize);
      final absEnd = line.getAbsoluteEnd(canvasSize);
      final distance = _pointToLineDistance(point, absStart, absEnd);
      if (distance <= threshold) {
        return i;
      }
    }
    return null;
  }
  
  // Проверяет, находится ли точка рядом с углом
  // point в scene coordinates
  int? _getAngleAtPoint(Offset point, double threshold) {
    final canvasSize = _getCanvasSize();
    for (int i = 0; i < _completedAngles.length; i++) {
      final angle = _completedAngles[i];
      
      if (angle.type == AngleType.cobb) {
        // Для угла Кобба проверяем попадание на обе линии
        final absPoint1 = angle.getAbsolutePoint1(canvasSize);
        final absLine1End = angle.getAbsoluteLine1End(canvasSize);
        final absPoint2 = angle.getAbsolutePoint2(canvasSize);
        final absLine2End = angle.getAbsoluteLine2End(canvasSize);
        
        if (absLine1End != null && absLine2End != null) {
          final distToLine1 = _pointToLineDistance(point, absPoint1, absLine1End);
          final distToLine2 = _pointToLineDistance(point, absPoint2, absLine2End);
          final distToLine1Start = (point - absPoint1).distance;
          final distToLine1End = (point - absLine1End).distance;
          final distToLine2Start = (point - absPoint2).distance;
          final distToLine2End = (point - absLine2End).distance;
          
          if (distToLine1 <= threshold || distToLine2 <= threshold ||
              distToLine1Start <= threshold * 2 || distToLine1End <= threshold * 2 ||
              distToLine2Start <= threshold * 2 || distToLine2End <= threshold * 2) {
            return i;
          }
        }
      } else {
        // Для обычного угла проверяем лучи и вершину
        final absVertex = angle.getAbsoluteVertex(canvasSize);
        final absPoint1 = angle.getAbsolutePoint1(canvasSize);
        final absPoint2 = angle.getAbsolutePoint2(canvasSize);
        // Проверяем расстояние до лучей и вершины
        final distToRay1 = _pointToLineDistance(point, absVertex, absPoint1);
        final distToRay2 = _pointToLineDistance(point, absVertex, absPoint2);
        final distToVertex = (point - absVertex).distance;
        if (distToRay1 <= threshold || distToRay2 <= threshold || distToVertex <= threshold * 2) {
          return i;
        }
      }
    }
    return null;
  }
  
  // Проверяет, находится ли точка рядом с текстовой аннотацией
  int? _getTextAnnotationAtPoint(Offset point, double threshold) {
    for (int i = _textAnnotations.length - 1; i >= 0; i--) {
      final annotation = _textAnnotations[i];
      final distance = (point - annotation.position).distance;
      // Увеличиваем хитбокс - учитываем размер текста
      if (distance <= threshold) {
        return i;
      }
    }
    return null;
  }
  
  // Проверяет, находится ли точка рядом со стрелкой
  int? _getArrowAnnotationAtPoint(Offset point, double threshold) {
    for (int i = _arrowAnnotations.length - 1; i >= 0; i--) {
      final arrow = _arrowAnnotations[i];
      final distToLine = _pointToLineDistance(point, arrow.start, arrow.end);
      if (distToLine <= threshold) {
        return i;
      }
    }
    return null;
  }
  
  // Проверяет, находится ли точка на индикаторе перетаскивания текстовой аннотации
  bool _isPointOnTextDragHandle(Offset point, int textIndex) {
    if (textIndex < 0 || textIndex >= _textAnnotations.length) return false;
    final annotation = _textAnnotations[textIndex];
    final textPainter = TextPainter(
      text: TextSpan(text: annotation.text, style: TextStyle(fontSize: annotation.fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    
    // Увеличенный хитбокс для лучшего UX
    final dragHandleSize = 50.0;
    final dragHandleX = annotation.position.dx + textPainter.width / 2 - dragHandleSize / 2;
    final dragHandleY = annotation.position.dy - dragHandleSize - 5;
    final dragHandleRect = Rect.fromLTWH(dragHandleX, dragHandleY, dragHandleSize, dragHandleSize);
    
    return dragHandleRect.contains(point);
  }
  
  // Проверяет, находится ли точка на индикаторе перетаскивания стрелки
  bool _isPointOnArrowDragHandle(Offset point, int arrowIndex) {
    if (arrowIndex < 0 || arrowIndex >= _arrowAnnotations.length) return false;
    final arrow = _arrowAnnotations[arrowIndex];
    
    // Увеличенный хитбокс для лучшего UX
    final dragHandleSize = 50.0;
    final centerX = (arrow.start.dx + arrow.end.dx) / 2;
    final centerY = (arrow.start.dy + arrow.end.dy) / 2;
    final dragHandleX = centerX - dragHandleSize / 2;
    final dragHandleY = centerY - dragHandleSize - 5;
    final dragHandleRect = Rect.fromLTWH(dragHandleX, dragHandleY, dragHandleSize, dragHandleSize);
    
    return dragHandleRect.contains(point);
  }
  
  // Проверяет, находится ли точка на индикаторе перетаскивания линейки
  bool _isPointOnRulerDragHandle(Offset point, int rulerIndex) {
    if (rulerIndex < 0 || rulerIndex >= _completedRulerLines.length) return false;
    final canvasSize = _getCanvasSize();
    final line = _completedRulerLines[rulerIndex];
    final absStart = line.getAbsoluteStart(canvasSize);
    final absEnd = line.getAbsoluteEnd(canvasSize);
    
    // Увеличенный хитбокс для лучшего UX
    final dragHandleSize = 50.0;
    final dragHandleX = (absStart.dx + absEnd.dx) / 2 - dragHandleSize / 2;
    final dragHandleY = (absStart.dy + absEnd.dy) / 2 - dragHandleSize - 5;
    final dragHandleRect = Rect.fromLTWH(dragHandleX, dragHandleY, dragHandleSize, dragHandleSize);
    
    return dragHandleRect.contains(point);
  }
  
  // Проверяет, находится ли точка на индикаторе перетаскивания угла
  bool _isPointOnAngleDragHandle(Offset point, int angleIndex) {
    if (angleIndex < 0 || angleIndex >= _completedAngles.length) return false;
    final canvasSize = _getCanvasSize();
    final angle = _completedAngles[angleIndex];
    
    Offset handleCenter;
    if (angle.type == AngleType.cobb) {
      // Для угла Кобба используем центр между двумя линиями
      final absPoint1 = angle.getAbsolutePoint1(canvasSize);
      final absLine1End = angle.getAbsoluteLine1End(canvasSize);
      final absPoint2 = angle.getAbsolutePoint2(canvasSize);
      final absLine2End = angle.getAbsoluteLine2End(canvasSize);
      
      if (absLine1End != null && absLine2End != null) {
        handleCenter = Offset(
          (absPoint1.dx + absLine1End.dx + absPoint2.dx + absLine2End.dx) / 4,
          (absPoint1.dy + absLine1End.dy + absPoint2.dy + absLine2End.dy) / 4,
        );
      } else {
        return false;
      }
    } else {
      // Для обычного угла используем вершину
      handleCenter = angle.getAbsoluteVertex(canvasSize);
    }
    
    // Увеличенный хитбокс для лучшего UX
    final dragHandleSize = 50.0;
    final dragHandleX = handleCenter.dx - dragHandleSize / 2;
    final dragHandleY = handleCenter.dy - dragHandleSize - 5;
    final dragHandleRect = Rect.fromLTWH(dragHandleX, dragHandleY, dragHandleSize, dragHandleSize);
    
    return dragHandleRect.contains(point);
  }
  
  // Вычисляет расстояние от точки до линии
  double _pointToLineDistance(Offset point, Offset lineStart, Offset lineEnd) {
    final A = point.dx - lineStart.dx;
    final B = point.dy - lineStart.dy;
    final C = lineEnd.dx - lineStart.dx;
    final D = lineEnd.dy - lineStart.dy;
    
    final dot = A * C + B * D;
    final lenSq = C * C + D * D;
    if (lenSq == 0) return (point - lineStart).distance;
    
    final param = dot / lenSq;
    
    Offset closest;
    if (param < 0) {
      closest = lineStart;
    } else if (param > 1) {
      closest = lineEnd;
    } else {
      closest = Offset(lineStart.dx + param * C, lineStart.dy + param * D);
    }
    
    return (point - closest).distance;
  }

  void _handleTap(TapDownDetails details) {
    // Получаем координаты клика в системе изображения
    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
      _matrixCacheValid = true;
    }
    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, details.localPosition);
    
    // ПРИОРИТЕТ: Проверяем, не кликнули ли на drag handle выделенного измерения
    // Если да, то не создаем новую точку, позволим перетаскиванию обработать
    if (_rulerPoints.isEmpty && _anglePoints.isEmpty && _arrowPoints.isEmpty) {
      // Проверяем drag handles только для выделенных измерений
      if (_selectedRulerIndex != null && 
          _selectedRulerIndex! >= 0 && 
          _selectedRulerIndex! < _completedRulerLines.length &&
          _isPointOnRulerDragHandle(sceneOffset, _selectedRulerIndex!)) {
        // Клик на drag handle - не создаем новую точку, позволим перетаскиванию обработать
        return;
      }
      if (_selectedAngleIndex != null && 
          _selectedAngleIndex! >= 0 && 
          _selectedAngleIndex! < _completedAngles.length &&
          _isPointOnAngleDragHandle(sceneOffset, _selectedAngleIndex!)) {
        // Клик на drag handle - не создаем новую точку
        return;
      }
      
      // Проверяем, не кликнули ли на саму выделенную линейку (не на drag handle, а на саму линию)
      // Это нужно для начала перетаскивания при клике на линию
      if (_selectedRulerIndex != null && 
          _selectedRulerIndex! >= 0 && 
          _selectedRulerIndex! < _completedRulerLines.length) {
        final canvasSize = _getCanvasSize();
        final line = _completedRulerLines[_selectedRulerIndex!];
        final absStart = line.getAbsoluteStart(canvasSize);
        final absEnd = line.getAbsoluteEnd(canvasSize);
        final distToLine = _pointToLineDistance(sceneOffset, absStart, absEnd);
        // Если клик близко к выделенной линейке, не создаем новую точку
        if (distToLine <= 30.0) {
          return;
        }
      }
      
      // Проверяем, не кликнули ли на сам выделенный угол
      if (_selectedAngleIndex != null && 
          _selectedAngleIndex! >= 0 && 
          _selectedAngleIndex! < _completedAngles.length) {
        final canvasSize = _getCanvasSize();
        final angle = _completedAngles[_selectedAngleIndex!];
        
        if (angle.type == AngleType.cobb) {
          // Для угла Кобба проверяем попадание на обе линии
          final absPoint1 = angle.getAbsolutePoint1(canvasSize);
          final absLine1End = angle.getAbsoluteLine1End(canvasSize);
          final absPoint2 = angle.getAbsolutePoint2(canvasSize);
          final absLine2End = angle.getAbsoluteLine2End(canvasSize);
          
          if (absLine1End != null && absLine2End != null) {
            final distToLine1Start = (sceneOffset - absPoint1).distance;
            final distToLine1End = (sceneOffset - absLine1End).distance;
            final distToLine2Start = (sceneOffset - absPoint2).distance;
            final distToLine2End = (sceneOffset - absLine2End).distance;
            final distToLine1 = _pointToLineDistance(sceneOffset, absPoint1, absLine1End);
            final distToLine2 = _pointToLineDistance(sceneOffset, absPoint2, absLine2End);
            
            // Если клик близко к выделенному углу Кобба, не создаем новую точку
            if (distToLine1Start <= 30.0 || distToLine1End <= 30.0 || 
                distToLine2Start <= 30.0 || distToLine2End <= 30.0 ||
                distToLine1 <= 30.0 || distToLine2 <= 30.0) {
              return;
            }
          }
        } else {
          // Для обычного угла проверяем вершину и лучи
          final absVertex = angle.getAbsoluteVertex(canvasSize);
          final absPoint1 = angle.getAbsolutePoint1(canvasSize);
          final absPoint2 = angle.getAbsolutePoint2(canvasSize);
          final distToVertex = (sceneOffset - absVertex).distance;
          final distToPoint1 = (sceneOffset - absPoint1).distance;
          final distToPoint2 = (sceneOffset - absPoint2).distance;
          final distToRay1 = _pointToLineDistance(sceneOffset, absVertex, absPoint1);
          final distToRay2 = _pointToLineDistance(sceneOffset, absVertex, absPoint2);
          
          // Если клик близко к выделенному углу, не создаем новую точку
          if (distToVertex <= 30.0 || distToPoint1 <= 30.0 || distToPoint2 <= 30.0 || 
              distToRay1 <= 30.0 || distToRay2 <= 30.0) {
            return;
          }
        }
      }
    }
    
    // Обрабатываем клик для инструмента угла (максимально быстро)
    if (_currentTool == ToolMode.angle) {
      final int currentLength = _anglePoints.length;
      final int requiredPoints = _currentAngleType == AngleType.normal ? 3 : 4;
      final bool willComplete = currentLength == requiredPoints - 1;
      final List<Offset> pointsToComplete = willComplete ? List.from(_anglePoints) : [];
      
      // Немедленно обновляем точки
      setState(() {
        if (currentLength < requiredPoints) {
          _anglePoints.add(sceneOffset);
        } else {
          _anglePoints = [sceneOffset];
        }
      });
      
      // Завершаем угол через микротаск для минимальной задержки
      if (willComplete) {
        scheduleMicrotask(() {
          final canvasSize = _getCanvasSize();
          AngleMeasurement completedAngle;
          
          if (_currentAngleType == AngleType.normal) {
            // Обычный угол: 3 точки (точка1, вершина, точка2)
            completedAngle = AngleMeasurement(
              vertex: _sceneToRelativeCoordinates(pointsToComplete[1], canvasSize),
              point1: _sceneToRelativeCoordinates(pointsToComplete[0], canvasSize),
              point2: _sceneToRelativeCoordinates(sceneOffset, canvasSize),
              type: AngleType.normal,
            );
          } else {
            // Угол Кобба: 4 точки (начало линии1, конец линии1, начало линии2, конец линии2)
            completedAngle = AngleMeasurement(
              vertex: Offset.zero, // Не используется для угла Кобба
              point1: _sceneToRelativeCoordinates(pointsToComplete[0], canvasSize),
              point2: _sceneToRelativeCoordinates(pointsToComplete[2], canvasSize),
              type: AngleType.cobb,
              line1End: _sceneToRelativeCoordinates(pointsToComplete[1], canvasSize),
              line2End: _sceneToRelativeCoordinates(sceneOffset, canvasSize),
            );
          }
          
          setState(() {
            _completedAngles = List.of(_completedAngles)..add(completedAngle);
            _addToHistory(ActionType.angleAdded, null);
            _anglePoints = [];
          });
        });
      }
      return;
    }
    
    // Обрабатываем клик только если активен инструмент линейки
    if (_currentTool != ToolMode.ruler) {
      // Проверки на существующие элементы только если не создаем новые
      if (_rulerPoints.isEmpty && _anglePoints.isEmpty && _arrowPoints.isEmpty) {
        scheduleMicrotask(() {
          _handleTapOnExistingMeasurements(sceneOffset);
        });
      }
      return;
    }
    
    // Режим калибровки - быстрая обработка
    if (_isCalibrationMode) {
      setState(() {
        if (_calibrationPoints.length == 0) {
          _calibrationPoints.add(sceneOffset);
        } else if (_calibrationPoints.length == 1) {
          _calibrationPoints.add(sceneOffset);
          scheduleMicrotask(() {
            _showCalibrationInputDialog();
          });
        } else {
          _calibrationPoints = [sceneOffset];
        }
      });
      return;
    }
    
    // Обрабатываем линейку - максимально быстро
    _handleRulerTap(sceneOffset);
    
    // Проверки на существующие элементы только если не создаем новые
    if (_rulerPoints.isEmpty) {
      scheduleMicrotask(() {
        _handleTapOnExistingMeasurements(sceneOffset);
      });
    }
  }
  
  void _handleTapOnExistingMeasurements(Offset sceneOffset) {
    // Проверяем клик на существующие линии/углы
    final rulerIndex = _getRulerLineAtPoint(sceneOffset, 15.0);
    if (rulerIndex != null) {
      setState(() {
        if (_selectedRulerIndex != rulerIndex) {
          _selectedRulerIndex = rulerIndex;
          _selectedAngleIndex = null;
          _selectedTextIndex = null;
          _selectedArrowIndex = null;
        }
      });
      return;
    }
    
    final angleIndex = _getAngleAtPoint(sceneOffset, 20.0);
    if (angleIndex != null) {
      setState(() {
        if (_selectedAngleIndex != angleIndex) {
          _selectedAngleIndex = angleIndex;
          _selectedRulerIndex = null;
          _selectedTextIndex = null;
          _selectedArrowIndex = null;
        }
      });
      return;
    }
    
    final textIndex = _getTextAnnotationAtPoint(sceneOffset, 50.0);
    if (textIndex != null) {
      setState(() {
        if (_selectedTextIndex != textIndex) {
          _selectedTextIndex = textIndex;
          _selectedRulerIndex = null;
          _selectedAngleIndex = null;
          _selectedArrowIndex = null;
        }
      });
      return;
    }
    
    final arrowIndex = _getArrowAnnotationAtPoint(sceneOffset, 30.0);
    if (arrowIndex != null) {
      setState(() {
        if (_selectedArrowIndex != arrowIndex) {
          _selectedArrowIndex = arrowIndex;
          _selectedRulerIndex = null;
          _selectedAngleIndex = null;
          _selectedTextIndex = null;
        }
      });
      return;
    }
    
    // Снимаем выделение если клик не на элемент
    setState(() {
      _selectedRulerIndex = null;
      _selectedAngleIndex = null;
      _selectedTextIndex = null;
      _selectedArrowIndex = null;
    });
  }
  
  void _handleRulerTap(Offset sceneOffset) {
    // Определяем, зажат ли Ctrl в момент клика
    final bool ctrlPressed = RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.controlLeft) ||
                             RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.controlRight);

    // Сохраняем состояние до обновления
    final int currentLength = _rulerPoints.length;
    final bool willCompleteLine = currentLength == 1;
    final Offset? firstPoint = willCompleteLine && _rulerPoints.isNotEmpty ? _rulerPoints[0] : null;
    final bool shouldClearLines = !ctrlPressed && _completedRulerLines.isNotEmpty && currentLength == 0;

    // Немедленно обновляем точки для мгновенного отображения
    setState(() {
      if (ctrlPressed) {
        if (currentLength == 1) {
          _rulerPoints = [];
        } else if (currentLength == 0) {
          _rulerPoints.add(sceneOffset);
        } else {
          _rulerPoints = [sceneOffset];
        }
      } else {
        if (shouldClearLines) {
          _completedRulerLines = [];
        }
        if (currentLength == 0) {
          _rulerPoints.add(sceneOffset);
        } else if (currentLength == 1) {
          _rulerPoints = [];
        } else {
          _rulerPoints = [sceneOffset];
        }
      }
    });
    
    // Завершаем линию через микротаск для минимальной задержки
    if (willCompleteLine && firstPoint != null) {
      scheduleMicrotask(() {
        final canvasSize = _getCanvasSize();
        final completedLine = RulerLine(
          start: _sceneToRelativeCoordinates(firstPoint, canvasSize),
          end: _sceneToRelativeCoordinates(sceneOffset, canvasSize),
          pixelSpacing: _pixelSpacingRow,
        );
        setState(() {
          _completedRulerLines = List.of(_completedRulerLines)..add(completedLine);
          _addToHistory(ActionType.rulerAdded, null);
        });
      });
    }
  }

  void _handleDoubleTap() {
    // Двойной клик больше не используется для калибровки
  }
  
  void _showCalibrationInputDialog() {
    if (_calibrationPoints.length != 2) return;
    
    // Вычисляем расстояние в пикселях изображения
    final imageSize = _decodedImage != null 
        ? Size(_decodedImage!.width.toDouble(), _decodedImage!.height.toDouble())
        : _getCanvasSize();
    
    // Преобразуем точки в относительные координаты и вычисляем расстояние
    final canvasSize = _getCanvasSize();
    final relPoint1 = _sceneToRelativeCoordinates(_calibrationPoints[0], canvasSize);
    final relPoint2 = _sceneToRelativeCoordinates(_calibrationPoints[1], canvasSize);
    final absPoint1 = Offset(relPoint1.dx * imageSize.width, relPoint1.dy * imageSize.height);
    final absPoint2 = Offset(relPoint2.dx * imageSize.width, relPoint2.dy * imageSize.height);
    final pixelDistance = (absPoint2 - absPoint1).distance;
    
    final realSizeController = TextEditingController();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Калибровка линейки'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Измеренное расстояние: ${pixelDistance.toStringAsFixed(1)} пикселей'),
              const SizedBox(height: 16),
              const Text('Введите реальный размер между точками (в мм):'),
              const SizedBox(height: 8),
              TextField(
                controller: realSizeController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  hintText: 'Например: 60 (для 6 см)',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                setState(() {
                  _calibrationPoints = [];
                });
              },
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                final realSizeText = realSizeController.text.trim();
                if (realSizeText.isNotEmpty) {
                  final realSizeMm = double.tryParse(realSizeText);
                  if (realSizeMm != null && realSizeMm > 0 && pixelDistance > 0) {
                    // Вычисляем новый PixelSpacing
                    final newPixelSpacing = realSizeMm / pixelDistance;
                    
                    // Сохраняем в SharedPreferences
                    _savePixelSpacing(newPixelSpacing);
                    
                    Navigator.of(ctx).pop();
                    
                    // Выходим из режима калибровки
                    setState(() {
                      _isCalibrationMode = false;
                      _calibrationPoints = [];
                    });
                    
                    // Показываем уведомление
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Калибровка выполнена: ${newPixelSpacing.toStringAsFixed(3)} мм/пиксель'),
                        duration: const Duration(seconds: 2),
                        backgroundColor: Colors.green,
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Введите корректное положительное число'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: const Text('Принять'),
            ),
          ],
        );
      },
    );
  }
  
  Future<void> _savePixelSpacing(double pixelSpacing) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('pixel_spacing_row', pixelSpacing);
      await _updatePixelSpacingFromSettings(pixelSpacing);
    } catch (e) {
      print('Ошибка при сохранении pixelSpacing: $e');
    }
  }
  
  Future<void> _updatePixelSpacingFromSettings(double pixelSpacing) async {
    setState(() {
      _pixelSpacingRow = pixelSpacing;
      
      // Обновляем PixelSpacing для всех линеек
      _completedRulerLines = _completedRulerLines.map((l) {
        return RulerLine(
          start: l.start,
          end: l.end,
          pixelSpacing: pixelSpacing,
        );
      }).toList();
      
      // Обновляем тег PixelSpacing если он есть
      if (_dicomTags.containsKey('PixelSpacing')) {
        _dicomTags['PixelSpacing'] = "${pixelSpacing.toStringAsFixed(3)} мм/пиксель (откалибровано вручную)";
        if (_tagControllers.containsKey('PixelSpacing')) {
          _tagControllers['PixelSpacing']?.dispose();
          _tagControllers['PixelSpacing'] = TextEditingController(text: _dicomTags['PixelSpacing']!);
        }
      } else {
        // Если тега нет, создаем его
        _dicomTags['PixelSpacing'] = "${pixelSpacing.toStringAsFixed(3)} мм/пиксель (откалибровано вручную)";
        _tagControllers['PixelSpacing'] = TextEditingController(text: _dicomTags['PixelSpacing']!);
      }
    });
  }

  void _handleTapUp(TapUpDetails details) {
    // Используем кэшированную матрицу для производительности
    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
      _matrixCacheValid = true;
    }
    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, details.localPosition);
    
    // Обрабатываем инструмент стрелки
    if (_currentTool == ToolMode.arrow) {
      if (_isDragging) return;
      
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
        _lastTapPosition = sceneOffset;
      }
      return;
    }
    
    // Обрабатываем инструмент текста
    if (_currentTool == ToolMode.text) {
      if (_isDragging) return;
      // Показываем диалог для ввода текста
      _showTextInputDialog(sceneOffset);
      return;
    }
  }
  
  // Проверяет, есть ли измерение рядом с указателем (для раннего отключения pan)
  bool _checkMeasurementNearPointer(Offset localPosition) {
    if (_rulerPoints.isNotEmpty || _anglePoints.isNotEmpty || _arrowPoints.isNotEmpty) {
      return false; // Если создаются новые измерения, не блокируем pan
    }
    
    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
      _matrixCacheValid = true;
    }
    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, localPosition);
    
    // Проверяем drag handles
    if (_selectedRulerIndex != null && 
        _selectedRulerIndex! >= 0 && 
        _selectedRulerIndex! < _completedRulerLines.length &&
        _isPointOnRulerDragHandle(sceneOffset, _selectedRulerIndex!)) {
      return true;
    }
    if (_selectedAngleIndex != null && _isPointOnAngleDragHandle(sceneOffset, _selectedAngleIndex!)) {
      return true;
    }
    if (_selectedTextIndex != null && _isPointOnTextDragHandle(sceneOffset, _selectedTextIndex!)) {
      return true;
    }
    if (_selectedArrowIndex != null && _isPointOnArrowDragHandle(sceneOffset, _selectedArrowIndex!)) {
      return true;
    }
    
    // Проверяем наличие линеек и углов рядом
    if (_getRulerLineAtPoint(sceneOffset, 15.0) != null) {
      return true;
    }
    if (_getAngleAtPoint(sceneOffset, 30.0) != null) {
      return true;
    }
    
    // Проверяем наличие текстовых аннотаций и стрелок рядом
    if (_getTextAnnotationAtPoint(sceneOffset, 50.0) != null) {
      return true;
    }
    if (_getArrowAnnotationAtPoint(sceneOffset, 30.0) != null) {
      return true;
    }
    
    return false;
  }

  void _handlePanStart(DragStartDetails details) {
    // Используем кэшированную матрицу для производительности
    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
      _matrixCacheValid = true;
    }
    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, details.localPosition);
    
    // ПРИОРИТЕТ 0: Обрабатываем начало перетаскивания для инструмента яркости (высший приоритет)
    if (_currentTool == ToolMode.brightness) {
      setState(() {
        _brightnessDragStart = details.localPosition;
        _brightnessAtDragStart = _brightness;
        _contrastAtDragStart = _contrast;
        // Сохраняем предыдущее значение в историю только при начале перетаскивания
        _addToHistory(ActionType.brightnessChanged, _brightness);
      });
      return;
    }
    
    // ПРИОРИТЕТ 1: Проверяем перетаскивание измерений (линеек и углов) в любом режиме
    // Это должно быть в самом начале, чтобы перетаскивание измерений имело приоритет над стандартным pan
    // Работает независимо от режима инструмента, но только если не создаются новые измерения
    if (_rulerPoints.isEmpty && _anglePoints.isEmpty && _arrowPoints.isEmpty) {
      // Проверяем индикатор перетаскивания текстовой аннотации
      if (_selectedTextIndex != null && _isPointOnTextDragHandle(sceneOffset, _selectedTextIndex!)) {
        setState(() {
          _isDraggingText = true;
          _dragOffset = sceneOffset;
        });
        return;
      }
      
      // Проверяем индикатор перетаскивания стрелки
      if (_selectedArrowIndex != null && _isPointOnArrowDragHandle(sceneOffset, _selectedArrowIndex!)) {
        setState(() {
          _isDraggingArrow = true;
          _dragOffset = sceneOffset;
        });
        return;
      }
      
      // Проверяем индикатор перетаскивания линейки
      if (_selectedRulerIndex != null && 
          _selectedRulerIndex! >= 0 && 
          _selectedRulerIndex! < _completedRulerLines.length &&
          _isPointOnRulerDragHandle(sceneOffset, _selectedRulerIndex!)) {
        setState(() {
          _isDraggingRuler = true;
          _dragOffset = sceneOffset;
          _hasMeasurementNearPointer = true; // Блокируем pan
        });
        return;
      }
      
      // Проверяем индикатор перетаскивания угла
      if (_selectedAngleIndex != null && _isPointOnAngleDragHandle(sceneOffset, _selectedAngleIndex!)) {
        setState(() {
          _isDraggingAngle = true;
          _dragOffset = sceneOffset;
          _hasMeasurementNearPointer = true; // Блокируем pan
        });
        return;
      }
    }
    
    // ПРИОРИТЕТ 2: Если не создаются новые измерения, проверяем возможность перетаскивания существующих
    // Перетаскивание работает в ЛЮБОМ режиме инструмента (включая pan), кроме режима создания новых измерений
    // Это гарантирует, что перетаскивание измерений имеет приоритет над стандартным перетаскиванием изображения
    if (_rulerPoints.isEmpty && _anglePoints.isEmpty && _arrowPoints.isEmpty) {
      // Сначала проверяем перетаскивание линеек (даже если не выбраны)
      // Если линейка уже выбрана, проверяем её
      if (_selectedRulerIndex != null && 
          _selectedRulerIndex! >= 0 && 
          _selectedRulerIndex! < _completedRulerLines.length) {
        final canvasSize = _getCanvasSize();
        final line = _completedRulerLines[_selectedRulerIndex!];
        final absStart = line.getAbsoluteStart(canvasSize);
        final absEnd = line.getAbsoluteEnd(canvasSize);
        final distToLine = _pointToLineDistance(sceneOffset, absStart, absEnd);
        // Уменьшенный threshold для более точного перетаскивания
        if (distToLine <= 15.0) {
          setState(() {
            _isDraggingRuler = true;
            _dragOffset = sceneOffset;
            _hasMeasurementNearPointer = true; // Блокируем pan
          });
          return;
        }
      }
      
      // Ищем ближайшую линейку, если ничего не выбрано (уменьшенный хитбокс)
      final rulerIndex = _getRulerLineAtPoint(sceneOffset, 15.0);
      if (rulerIndex != null) {
        setState(() {
          _selectedRulerIndex = rulerIndex;
          _selectedAngleIndex = null;
          _selectedTextIndex = null;
          _selectedArrowIndex = null;
          _isDraggingRuler = true;
          _dragOffset = sceneOffset;
          _hasMeasurementNearPointer = true; // Блокируем pan
        });
        return;
      }
      
      // Проверяем перетаскивание углов (даже если не выбраны)
      // Если угол уже выбран, проверяем его (увеличенный хитбокс)
      if (_selectedAngleIndex != null) {
        final canvasSize = _getCanvasSize();
        final angle = _completedAngles[_selectedAngleIndex!];
        final absVertex = angle.getAbsoluteVertex(canvasSize);
        final absPoint1 = angle.getAbsolutePoint1(canvasSize);
        final absPoint2 = angle.getAbsolutePoint2(canvasSize);
        final distToVertex = (sceneOffset - absVertex).distance;
        final distToPoint1 = (sceneOffset - absPoint1).distance;
        final distToPoint2 = (sceneOffset - absPoint2).distance;
        final distToRay1 = _pointToLineDistance(sceneOffset, absVertex, absPoint1);
        final distToRay2 = _pointToLineDistance(sceneOffset, absVertex, absPoint2);
        
        // Уменьшенный threshold для более точного перетаскивания
        if (distToVertex <= 30.0 || distToPoint1 <= 30.0 || distToPoint2 <= 30.0 || 
            distToRay1 <= 30.0 || distToRay2 <= 30.0) {
          setState(() {
            _isDraggingAngle = true;
            _dragOffset = sceneOffset;
            _hasMeasurementNearPointer = true; // Блокируем pan
          });
          return;
        }
      }
      
      // Ищем ближайший угол, если ничего не выбрано (уменьшенный хитбокс)
      final angleIndex = _getAngleAtPoint(sceneOffset, 30.0);
      if (angleIndex != null) {
        setState(() {
          _selectedAngleIndex = angleIndex;
          _selectedRulerIndex = null;
          _selectedTextIndex = null;
          _selectedArrowIndex = null;
          _isDraggingAngle = true;
          _dragOffset = sceneOffset;
          _hasMeasurementNearPointer = true; // Блокируем pan
        });
        return;
      }
      
      // Проверяем перетаскивание текстовых аннотаций (увеличенный хитбокс)
      final textIndex = _getTextAnnotationAtPoint(sceneOffset, 50.0);
      if (textIndex != null) {
        setState(() {
          _selectedTextIndex = textIndex;
          _selectedRulerIndex = null;
          _selectedAngleIndex = null;
          _selectedArrowIndex = null;
          _isDraggingText = true;
          _dragOffset = sceneOffset;
        });
        return;
      }
      
      // Проверяем перетаскивание стрелок (увеличенный хитбокс)
      final arrowIndex = _getArrowAnnotationAtPoint(sceneOffset, 30.0);
      if (arrowIndex != null) {
        setState(() {
          _selectedArrowIndex = arrowIndex;
          _selectedRulerIndex = null;
          _selectedAngleIndex = null;
          _selectedTextIndex = null;
          _isDraggingArrow = true;
          _dragOffset = sceneOffset;
        });
        return;
      }
    }
    
    // Проверяем перетаскивание линеек (старая логика для обратной совместимости)
    if (_currentTool == ToolMode.ruler && 
        _selectedRulerIndex != null && 
        _selectedRulerIndex! >= 0 && 
        _selectedRulerIndex! < _completedRulerLines.length &&
        _rulerPoints.isEmpty) {
      final canvasSize = _getCanvasSize();
      final line = _completedRulerLines[_selectedRulerIndex!];
      final absStart = line.getAbsoluteStart(canvasSize);
      final absEnd = line.getAbsoluteEnd(canvasSize);
      final distToLine = _pointToLineDistance(sceneOffset, absStart, absEnd);
      
      if (distToLine <= 10.0) {
        setState(() {
          _isDraggingRuler = true;
          _dragOffset = sceneOffset;
        });
        return;
      }
    }
    
    // Проверяем перетаскивание углов (старая логика для обратной совместимости)
    if (_currentTool == ToolMode.angle && _selectedAngleIndex != null && _anglePoints.isEmpty) {
      final canvasSize = _getCanvasSize();
      final angle = _completedAngles[_selectedAngleIndex!];
      final absVertex = angle.getAbsoluteVertex(canvasSize);
      final absPoint1 = angle.getAbsolutePoint1(canvasSize);
      final absPoint2 = angle.getAbsolutePoint2(canvasSize);
      final distToVertex = (sceneOffset - absVertex).distance;
      final distToPoint1 = (sceneOffset - absPoint1).distance;
      final distToPoint2 = (sceneOffset - absPoint2).distance;
      
      if (distToVertex <= 15.0 || distToPoint1 <= 15.0 || distToPoint2 <= 15.0) {
        setState(() {
          _isDraggingAngle = true;
          _dragOffset = sceneOffset;
        });
        return;
      }
    }
    
    // Обрабатываем начало перетаскивания для инструмента стрелки
    if (_currentTool == ToolMode.arrow) {
      setState(() {
        _isDragging = true; // Устанавливаем флаг перетаскивания
        _arrowPoints.clear(); // Очищаем предыдущие точки
        _arrowPoints.add(sceneOffset); // Добавляем начальную точку
      });
      return;
    }
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    // ПРИОРИТЕТ 0: Обрабатываем перетаскивание для инструмента яркости (высший приоритет)
    if (_currentTool == ToolMode.brightness && 
        _brightnessDragStart != null && 
        _brightnessAtDragStart != null && 
        _contrastAtDragStart != null) {
      final delta = details.localPosition - _brightnessDragStart!;
      // Горизонтальное движение - контраст, вертикальное - яркость
      // Используем чувствительность: 1 пиксель = 0.01 изменения
      final contrastDelta = delta.dx * 0.01;
      final brightnessDelta = -delta.dy * 0.01; // Инвертируем, чтобы вверх = больше яркости
      
      double newContrast = (_contrastAtDragStart! + contrastDelta).clamp(0.1, 3.0);
      double newBrightness = (_brightnessAtDragStart! + brightnessDelta).clamp(0.1, 3.0);
      
      setState(() {
        _contrast = newContrast;
        _brightness = newBrightness;
      });
      return;
    }
    
    // Используем кэшированную матрицу для производительности
    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
      _matrixCacheValid = true;
    }
    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, details.localPosition);
    
    // Обрабатываем перетаскивание линеек
    if (_isDraggingRuler && 
        _selectedRulerIndex != null && 
        _selectedRulerIndex! >= 0 && 
        _selectedRulerIndex! < _completedRulerLines.length &&
        _dragOffset != null) {
      final canvasSize = _getCanvasSize();
      // Преобразуем delta из scene coordinates в относительные координаты
      final deltaScene = sceneOffset - _dragOffset!;
      final deltaRelative = Offset(
        deltaScene.dx / canvasSize.width,
        deltaScene.dy / canvasSize.height,
      );
      setState(() {
        final line = _completedRulerLines[_selectedRulerIndex!];
        _completedRulerLines[_selectedRulerIndex!] = RulerLine(
          start: Offset(line.start.dx + deltaRelative.dx, line.start.dy + deltaRelative.dy),
          end: Offset(line.end.dx + deltaRelative.dx, line.end.dy + deltaRelative.dy),
          pixelSpacing: line.pixelSpacing,
        );
        _dragOffset = sceneOffset;
      });
      return;
    }
    
    // Обрабатываем перетаскивание углов
    if (_isDraggingAngle && _selectedAngleIndex != null && _dragOffset != null) {
      final canvasSize = _getCanvasSize();
      // Преобразуем delta из scene coordinates в относительные координаты
      final deltaScene = sceneOffset - _dragOffset!;
      final deltaRelative = Offset(
        deltaScene.dx / canvasSize.width,
        deltaScene.dy / canvasSize.height,
      );
      setState(() {
        final angle = _completedAngles[_selectedAngleIndex!];
        
        if (angle.type == AngleType.cobb) {
          // Для угла Кобба перемещаем все 4 точки
          _completedAngles[_selectedAngleIndex!] = AngleMeasurement(
            vertex: Offset(angle.vertex.dx + deltaRelative.dx, angle.vertex.dy + deltaRelative.dy),
            point1: Offset(angle.point1.dx + deltaRelative.dx, angle.point1.dy + deltaRelative.dy),
            point2: Offset(angle.point2.dx + deltaRelative.dx, angle.point2.dy + deltaRelative.dy),
            type: AngleType.cobb,
            line1End: angle.line1End != null 
                ? Offset(angle.line1End!.dx + deltaRelative.dx, angle.line1End!.dy + deltaRelative.dy)
                : null,
            line2End: angle.line2End != null
                ? Offset(angle.line2End!.dx + deltaRelative.dx, angle.line2End!.dy + deltaRelative.dy)
                : null,
          );
        } else {
          // Для обычного угла перемещаем 3 точки
          _completedAngles[_selectedAngleIndex!] = AngleMeasurement(
            vertex: Offset(angle.vertex.dx + deltaRelative.dx, angle.vertex.dy + deltaRelative.dy),
            point1: Offset(angle.point1.dx + deltaRelative.dx, angle.point1.dy + deltaRelative.dy),
            point2: Offset(angle.point2.dx + deltaRelative.dx, angle.point2.dy + deltaRelative.dy),
            type: AngleType.normal,
          );
        }
        
        _dragOffset = sceneOffset;
      });
      return;
    }
    
    // Обрабатываем перетаскивание текстовых аннотаций
    if (_isDraggingText && _selectedTextIndex != null && _dragOffset != null) {
      final deltaScene = sceneOffset - _dragOffset!;
      setState(() {
        final annotation = _textAnnotations[_selectedTextIndex!];
        _textAnnotations[_selectedTextIndex!] = TextAnnotation(
          position: Offset(annotation.position.dx + deltaScene.dx, annotation.position.dy + deltaScene.dy),
          text: annotation.text,
          color: annotation.color,
          fontSize: annotation.fontSize,
        );
        _dragOffset = sceneOffset;
      });
      return;
    }
    
    // Обрабатываем перетаскивание стрелок
    if (_isDraggingArrow && _selectedArrowIndex != null && _dragOffset != null) {
      final deltaScene = sceneOffset - _dragOffset!;
      setState(() {
        final arrow = _arrowAnnotations[_selectedArrowIndex!];
        _arrowAnnotations[_selectedArrowIndex!] = ArrowAnnotation(
          start: Offset(arrow.start.dx + deltaScene.dx, arrow.start.dy + deltaScene.dy),
          end: Offset(arrow.end.dx + deltaScene.dx, arrow.end.dy + deltaScene.dy),
          color: arrow.color,
          strokeWidth: arrow.strokeWidth,
        );
        _dragOffset = sceneOffset;
      });
      return;
    }
    
    // Обрабатываем обновление перетаскивания для инструмента стрелки
    if (_currentTool == ToolMode.arrow) {
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
      return;
    }
  }

  void _handlePanEnd(DragEndDetails details) {
    // Сбрасываем флаги перетаскивания линеек, углов, текстовых аннотаций и стрелок
    if (_isDraggingRuler || _isDraggingAngle || _isDraggingText || _isDraggingArrow) {
      setState(() {
        _isDraggingRuler = false;
        _isDraggingAngle = false;
        _isDraggingText = false;
        _isDraggingArrow = false;
        _dragOffset = null;
        _hasMeasurementNearPointer = false;
      });
      return;
    }
    
    // Сбрасываем переменные перетаскивания яркости/контраста
    if (_currentTool == ToolMode.brightness && _brightnessDragStart != null) {
      setState(() {
        _brightnessDragStart = null;
        _brightnessAtDragStart = null;
        _contrastAtDragStart = null;
      });
      return;
    }
    
    // Обрабатываем завершение перетаскивания для инструмента стрелки
    if (_currentTool != ToolMode.arrow || _arrowPoints.isEmpty) return;
    
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
        
        // Декодируем изображение для лупы
        ui.Image? decodedImage;
        try {
          final codec = await ui.instantiateImageCodec(newImageBytes);
          final frame = await codec.getNextFrame();
          decodedImage = frame.image;
        } catch (e) {
          print("Ошибка при декодировании изображения для лупы при обновлении W/L: $e");
        }
        
        setState(() {
          _imageBytes = newImageBytes;
          _decodedImage?.dispose(); // Освобождаем старое изображение
          _decodedImage = decodedImage; // Сохраняем новое декодированное изображение
        });
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
      // Сохраняем все теги из контроллеров, а не только те, что есть в _dicomTags
      _dicomTags = Map.fromEntries(_tagControllers.entries.map((e) => MapEntry(e.key, e.value.text.trim())));
      
      // Обновляем _patientName если изменился тег PatientName
      if (_dicomTags.containsKey('PatientName')) {
        final newPatientName = _dicomTags['PatientName']!.trim();
        if (newPatientName.isNotEmpty && newPatientName != _patientName) {
          setState(() {
            _patientName = newPatientName;
          });
        }
      }

      final dir = await getApplicationDocumentsDirectory();
      final metaDir = Directory('${dir.path}/dicom_metadata');
      if (!await metaDir.exists()) {
        await metaDir.create(recursive: true);
      }
      final baseName = (_currentFileName ?? 'session').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${metaDir.path}/$baseName.metadata.json');
      // Подготовка данных аннотаций для сохранения
      // Сохраняем в относительных координатах для линеек и углов (независимость от размера экрана)
      // Для текстовых аннотаций и стрелок сохраняем абсолютные координаты (scene coordinates)
      final canvasSize = _getCanvasSize();
      final rulers = _completedRulerLines.map((line) {
        // Сохраняем относительные координаты (0.0-1.0)
        return {
          'startX': line.start.dx,
          'startY': line.start.dy,
          'endX': line.end.dx,
          'endY': line.end.dy,
          'pixelSpacing': line.pixelSpacing,
        };
      }).toList();
      
      final angles = _completedAngles.map((angle) {
        // Сохраняем относительные координаты (0.0-1.0)
        return {
          'vertexX': angle.vertex.dx,
          'vertexY': angle.vertex.dy,
          'point1X': angle.point1.dx,
          'point1Y': angle.point1.dy,
          'point2X': angle.point2.dx,
          'point2Y': angle.point2.dy,
        };
      }).toList();
      
      // Преобразуем текстовые аннотации в относительные координаты
      final texts = _textAnnotations.map((text) => <String, dynamic>{
        // Преобразуем абсолютные координаты (scene coordinates) в относительные (0.0-1.0)
        'x': canvasSize.width > 0 ? text.position.dx / canvasSize.width : 0.0,
        'y': canvasSize.height > 0 ? text.position.dy / canvasSize.height : 0.0,
        'text': text.text,
        'color': text.color.value,
        'fontSize': text.fontSize,
      }).toList();
      
      // Преобразуем стрелки в относительные координаты
      final arrows = _arrowAnnotations.map((arrow) => <String, dynamic>{
        // Преобразуем абсолютные координаты (scene coordinates) в относительные (0.0-1.0)
        'x1': canvasSize.width > 0 ? arrow.start.dx / canvasSize.width : 0.0,
        'y1': canvasSize.height > 0 ? arrow.start.dy / canvasSize.height : 0.0,
        'x2': canvasSize.width > 0 ? arrow.end.dx / canvasSize.width : 0.0,
        'y2': canvasSize.height > 0 ? arrow.end.dy / canvasSize.height : 0.0,
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
          'contrast': _contrast,
          'inverted': _isInverted,
          'rotation_deg': _rotationAngle,
        },
        'updated_at': DateTime.now().toIso8601String(),
      };
      print("Сохраняем аннотации: rulers=${rulers.length}, angles=${angles.length}, texts=${texts.length}, arrows=${arrows.length}");
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      print("Метаданные сохранены в файл: ${file.path}");
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

  Future<void> _loadMetadata() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final metaDir = Directory('${dir.path}/dicom_metadata');
      if (!await metaDir.exists()) {
        return; // Нет директории с метаданными
      }
      
      // Убираем суффикс _edited.dcm если есть, чтобы найти оригинальные метаданные
      String baseName = (_currentFileName ?? 'session').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      // Если файл заканчивается на _edited.dcm, убираем _edited
      if (baseName.endsWith('_edited.dcm')) {
        baseName = baseName.replaceAll('_edited.dcm', '.dcm');
      }
      // Убираем расширение .dcm если есть
      baseName = baseName.replaceAll('.dcm', '');
      final file = File('${metaDir.path}/$baseName.metadata.json');
      print("Ищем метаданные для файла: $baseName (исходное имя: ${_currentFileName})");
      
      if (!await file.exists()) {
        print("Файл метаданных не найден: ${file.path}");
        return; // Нет сохраненных метаданных для этого файла
      }
      
      final jsonString = await file.readAsString();
      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      
      setState(() {
        // Загружаем сохраненные метаданные
        if (data.containsKey('patient_name') && data['patient_name'] != null) {
          _patientName = data['patient_name'].toString();
        }
        if (data.containsKey('report') && data['report'] != null) {
          _dicomReport = data['report'].toString();
          _reportController.text = _dicomReport ?? '';
        }
        if (data.containsKey('tags') && data['tags'] is Map) {
          final savedTags = (data['tags'] as Map).map((key, value) => MapEntry(key.toString(), value.toString()));
          // Объединяем сохраненные теги с тегами из DICOM (сохраненные имеют приоритет)
          savedTags.forEach((key, value) {
            _dicomTags[key] = value;
            _tagControllers[key] = TextEditingController(text: value);
          });
        }
        
        // Загружаем аннотации
        if (data.containsKey('annotations') && data['annotations'] is Map) {
          final annotations = data['annotations'] as Map<String, dynamic>;
          print("Загружаем аннотации: ${annotations.keys.toList()}");
          print("Содержимое аннотаций: rulers=${annotations['rulers']?.length ?? 0}, angles=${annotations['angles']?.length ?? 0}, texts=${annotations['texts']?.length ?? 0}, arrows=${annotations['arrows']?.length ?? 0}");
          
          // Загружаем линейки (относительные координаты)
          if (annotations.containsKey('rulers') && annotations['rulers'] is List) {
            print("Загружаем ${(annotations['rulers'] as List).length} линеек");
            _completedRulerLines = (annotations['rulers'] as List).map((ruler) {
              return RulerLine(
                start: Offset(
                  (ruler['startX'] ?? ruler['x1'] ?? 0.0).toDouble(),
                  (ruler['startY'] ?? ruler['y1'] ?? 0.0).toDouble(),
                ),
                end: Offset(
                  (ruler['endX'] ?? ruler['x2'] ?? 0.0).toDouble(),
                  (ruler['endY'] ?? ruler['y2'] ?? 0.0).toDouble(),
                ),
                pixelSpacing: (ruler['pixelSpacing'] ?? _pixelSpacingRow).toDouble(),
              );
            }).toList();
          }
          
          // Загружаем углы (относительные координаты)
          if (annotations.containsKey('angles') && annotations['angles'] is List) {
            final anglesList = annotations['angles'] as List;
            print("Загружаем ${anglesList.length} углов");
            _completedAngles = anglesList.map((angle) {
              return AngleMeasurement(
                vertex: Offset(
                  (angle['vertexX'] ?? 0.0).toDouble(),
                  (angle['vertexY'] ?? 0.0).toDouble(),
                ),
                point1: Offset(
                  (angle['point1X'] ?? 0.0).toDouble(),
                  (angle['point1Y'] ?? 0.0).toDouble(),
                ),
                point2: Offset(
                  (angle['point2X'] ?? 0.0).toDouble(),
                  (angle['point2Y'] ?? 0.0).toDouble(),
                ),
              );
            }).toList();
          }
          
          // Загружаем текстовые аннотации (преобразуем из относительных координат в абсолютные)
          if (annotations.containsKey('texts') && annotations['texts'] is List) {
            final textsList = annotations['texts'] as List;
            print("Загружаем ${textsList.length} текстовых аннотаций");
            final canvasSize = _getCanvasSize();
            // Если canvas еще не готов, используем размер изображения
            final size = canvasSize.width > 0 && canvasSize.height > 0 
                ? canvasSize 
                : (_decodedImage != null 
                    ? Size(_decodedImage!.width.toDouble(), _decodedImage!.height.toDouble())
                    : const Size(1000, 1000)); // Fallback размер
            print("Размер для преобразования координат: ${size.width}x${size.height}");
            
            _textAnnotations = textsList.map((text) {
              // Проверяем, сохранены ли координаты в относительном формате (0.0-1.0) или абсолютном
              final x = (text['x'] ?? 0.0).toDouble();
              final y = (text['y'] ?? 0.0).toDouble();
              // Если координаты больше 1.0, значит они в абсолютном формате (старый формат)
              // Иначе преобразуем из относительных в абсолютные
              final absX = x > 1.0 ? x : x * size.width;
              final absY = y > 1.0 ? y : y * size.height;
              
              return TextAnnotation(
                position: Offset(absX, absY),
                text: text['text'] ?? '',
                color: Color(text['color'] ?? Colors.yellow.value),
                fontSize: (text['fontSize'] ?? 16.0).toDouble(),
              );
            }).toList();
          }
          
          // Загружаем стрелки (преобразуем из относительных координат в абсолютные)
          if (annotations.containsKey('arrows') && annotations['arrows'] is List) {
            final arrowsList = annotations['arrows'] as List;
            print("Загружаем ${arrowsList.length} стрелок");
            final canvasSize = _getCanvasSize();
            // Если canvas еще не готов, используем размер изображения
            final size = canvasSize.width > 0 && canvasSize.height > 0 
                ? canvasSize 
                : (_decodedImage != null 
                    ? Size(_decodedImage!.width.toDouble(), _decodedImage!.height.toDouble())
                    : const Size(1000, 1000)); // Fallback размер
            print("Размер для преобразования координат стрелок: ${size.width}x${size.height}");
            
            _arrowAnnotations = arrowsList.map((arrow) {
              // Проверяем, сохранены ли координаты в относительном формате (0.0-1.0) или абсолютном
              final x1 = (arrow['x1'] ?? 0.0).toDouble();
              final y1 = (arrow['y1'] ?? 0.0).toDouble();
              final x2 = (arrow['x2'] ?? 0.0).toDouble();
              final y2 = (arrow['y2'] ?? 0.0).toDouble();
              // Если координаты больше 1.0, значит они в абсолютном формате (старый формат)
              // Иначе преобразуем из относительных в абсолютные
              final absX1 = x1 > 1.0 ? x1 : x1 * size.width;
              final absY1 = y1 > 1.0 ? y1 : y1 * size.height;
              final absX2 = x2 > 1.0 ? x2 : x2 * size.width;
              final absY2 = y2 > 1.0 ? y2 : y2 * size.height;
              
              return ArrowAnnotation(
                start: Offset(absX1, absY1),
                end: Offset(absX2, absY2),
                color: Color(arrow['color'] ?? Colors.red.value),
                strokeWidth: (arrow['strokeWidth'] ?? 3.0).toDouble(),
              );
            }).toList();
          }
        }
        
        // Загружаем настройки вида
        if (data.containsKey('view_settings') && data['view_settings'] is Map) {
          final viewSettings = data['view_settings'] as Map<String, dynamic>;
          if (viewSettings.containsKey('brightness')) {
            _brightness = (viewSettings['brightness'] ?? 1.0).toDouble();
            _initialBrightness = _brightness;
          }
          if (viewSettings.containsKey('contrast')) {
            _contrast = (viewSettings['contrast'] ?? 1.0).toDouble();
            _initialContrast = _contrast;
          }
          if (viewSettings.containsKey('inverted')) {
            _isInverted = viewSettings['inverted'] ?? false;
            _initialInverted = _isInverted;
          }
          if (viewSettings.containsKey('rotation_deg')) {
            _rotationAngle = (viewSettings['rotation_deg'] ?? 0.0).toDouble();
            _initialRotationAngle = _rotationAngle;
          }
        }
      });
      
      print("Метаданные и аннотации загружены из файла: ${file.path}");
      print("Загружено линеек: ${_completedRulerLines.length}, углов: ${_completedAngles.length}, текстов: ${_textAnnotations.length}, стрелок: ${_arrowAnnotations.length}");
    } catch (e) {
      print("Ошибка при загрузке метаданных: $e");
      // Не показываем ошибку пользователю, так как это не критично
    }
  }

  void _showCalibrateRulerDialog(int rulerIndex) {
    if (rulerIndex < 0 || rulerIndex >= _completedRulerLines.length) return;
    
    final line = _completedRulerLines[rulerIndex];
    
    // Используем размер изображения для вычисления расстояния
    final imageSize = _decodedImage != null 
        ? Size(_decodedImage!.width.toDouble(), _decodedImage!.height.toDouble())
        : _getCanvasSize();
    
    // Вычисляем расстояние в пикселях изображения
    final pixelDistance = line.getDistance(imageSize);
    
    // Текущее значение в мм с текущим PixelSpacing
    final currentRealDistanceMm = pixelDistance * line.pixelSpacing;
    
    final realSizeController = TextEditingController(
      text: currentRealDistanceMm.toStringAsFixed(1),
    );
    
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Калибровка линейки'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Измеренное расстояние: ${pixelDistance.toStringAsFixed(1)} пикселей'),
              Text('Текущее значение: ${currentRealDistanceMm.toStringAsFixed(2)} мм'),
              const SizedBox(height: 16),
              const Text('Введите реальный размер объекта (в мм):'),
              const SizedBox(height: 8),
              TextField(
                controller: realSizeController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  hintText: 'Например: 60 (для 6 см)',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 8),
              const Text(
                'После калибровки все линейки будут пересчитаны с новым PixelSpacing',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                final realSizeText = realSizeController.text.trim();
                if (realSizeText.isNotEmpty) {
                  final realSizeMm = double.tryParse(realSizeText);
                  if (realSizeMm != null && realSizeMm > 0 && pixelDistance > 0) {
                    // Вычисляем новый PixelSpacing
                    // Формула: PixelSpacing (мм/пиксель) = Реальный размер (мм) / Пиксельное расстояние (пиксели)
                    final newPixelSpacing = realSizeMm / pixelDistance;
                    
                    setState(() {
                      // Обновляем PixelSpacing для всех линеек
                      _pixelSpacingRow = newPixelSpacing;
                      _completedRulerLines = _completedRulerLines.map((l) {
                        return RulerLine(
                          start: l.start,
                          end: l.end,
                          pixelSpacing: newPixelSpacing,
                        );
                      }).toList();
                      
                      // Обновляем тег PixelSpacing если он есть
                      if (_dicomTags.containsKey('PixelSpacing')) {
                        _dicomTags['PixelSpacing'] = "${newPixelSpacing.toStringAsFixed(3)} мм/пиксель (откалибровано вручную)";
                        if (_tagControllers.containsKey('PixelSpacing')) {
                          _tagControllers['PixelSpacing']?.dispose();
                          _tagControllers['PixelSpacing'] = TextEditingController(text: _dicomTags['PixelSpacing']!);
                        }
                      }
                    });
                    
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Калибровка выполнена: PixelSpacing = ${newPixelSpacing.toStringAsFixed(3)} мм/пиксель'),
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Введите корректное положительное число'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: const Text('Калибровать'),
            ),
          ],
        );
      },
    );
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
      // Обновляем теги из контроллеров перед экспортом
      final currentTags = Map.fromEntries(_tagControllers.entries.map((e) => MapEntry(e.key, e.value.text.trim())));
      final meta = jsonEncode({'tags': currentTags, 'report': _reportController.text.trim()});
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

      final canvasSize = _getCanvasSize();
      final rulers = <Map<String, dynamic>>[];
      for (int i = 0; i < _completedRulerLines.length; i++) {
        final line = _completedRulerLines[i];
        final absStart = line.getAbsoluteStart(canvasSize);
        final absEnd = line.getAbsoluteEnd(canvasSize);
        final pixelDistance = line.getDistance(canvasSize);
        final realDistanceMm = line.getRealDistanceMm(canvasSize);
        final label = 'L${i + 1}: ${realDistanceMm.toStringAsFixed(2)} mm (${pixelDistance.toStringAsFixed(1)} px)';
        rulers.add({
          'x1': absStart.dx,
          'y1': absStart.dy,
          'x2': absEnd.dx,
          'y2': absEnd.dy,
          'label': label,
        });
      }

      final angles = <Map<String, dynamic>>[];
      for (int i = 0; i < _completedAngles.length; i++) {
        final angle = _completedAngles[i];
        final absVertex = angle.getAbsoluteVertex(canvasSize);
        final absPoint1 = angle.getAbsolutePoint1(canvasSize);
        final absPoint2 = angle.getAbsolutePoint2(canvasSize);
        final angleDeg = angle.getAngleDegrees(canvasSize);
        final label = '∠${i + 1}: ${angleDeg.toStringAsFixed(1)}°';
        angles.add({
          'vertexX': absVertex.dx,
          'vertexY': absVertex.dy,
          'point1X': absPoint1.dx,
          'point1Y': absPoint1.dy,
          'point2X': absPoint2.dx,
          'point2Y': absPoint2.dy,
          'angle': angleDeg,
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
        'contrast': _contrast,
      });
      // НЕ отправляем аннотации на сервер - они остаются отдельным редактируемым слоем
      // Аннотации сохраняются только в JSON файл локально
      // request.fields['annotations'] = annotations; // Закомментировано - аннотации не встраиваются в DICOM

      // Сохраняем метаданные и аннотации в JSON перед экспортом DICOM
      // Аннотации сохраняются отдельно в JSON и не встраиваются в DICOM
      await _saveMetadata();
      
      // НЕ отправляем render с аннотациями - аннотации остаются отдельным редактируемым слоем
      // DICOM экспортируется БЕЗ аннотаций, аннотации загружаются отдельно из JSON при открытии файла
      
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
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _transformationController.dispose();
    EmbeddedServerService.stopServer();
    _reportController.dispose();
    for (final c in _tagControllers.values) { c.dispose(); }
    _decodedImage?.dispose(); // Освобождаем декодированное изображение
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
          } else if (HotkeyService.isKeyForTool(keyString, 'magnifier', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ MAGNIFIER hotkey matched');
            toolChanged = true;
            toolName = 'Лупа';
            _switchTool(ToolMode.magnifier);
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
            toolName = 'Стрелка';
            _switchTool(ToolMode.arrow);
          } else if (HotkeyService.isKeyForTool(keyString, 'text', ctrl: ctrlPressed, alt: altPressed, shift: shiftPressed)) {
            print('✓ TEXT hotkey matched');
            toolChanged = true;
            toolName = 'Текст';
            _switchTool(ToolMode.text);
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
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SettingsScreen()),
                  );
                  // Перезагружаем настройки после возврата из экрана настроек
                  await HotkeyService.reloadSettings();
                  print('Настройки перезагружены: ${HotkeyService.hotkeySettings.toJson()}');
                  
                  // Если вернулись с запросом на калибровку, активируем режим калибровки
                  if (result == true) {
                    setState(() {
                      _isCalibrationMode = true;
                      _currentTool = ToolMode.ruler;
                      _calibrationPoints = [];
                    });
                    
                    // Показываем подсказку
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Режим калибровки: выберите две точки на изображении'),
                          duration: Duration(seconds: 3),
                          backgroundColor: Colors.blue,
                        ),
                      );
                    }
                  } else if (result != null && result is double) {
                    // Если вернулись с новым значением pixelSpacing (из галочки), обновляем теги
                    await _updatePixelSpacingFromSettings(result);
                  }
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
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Панель инструментов
                          Container(
                            width: 60, 
                            color: Colors.grey[900],
                            child: SingleChildScrollView(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
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
                                GestureDetector(
                                  onSecondaryTapDown: (details) {
                                    // Показываем меню выбора типа угла при ПКМ
                                    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
                                    showMenu<AngleType>(
                                      context: context,
                                      position: RelativeRect.fromRect(
                                        details.globalPosition & const Size(40, 40),
                                        Offset.zero & overlay.size,
                                      ),
                                      items: [
                                        PopupMenuItem<AngleType>(
                                          value: AngleType.normal,
                                          child: Row(
                                            children: [
                                              Icon(
                                                _currentAngleType == AngleType.normal ? Icons.check : Icons.check_box_outline_blank,
                                                size: 20,
                                                color: _currentAngleType == AngleType.normal ? Colors.blue : Colors.grey,
                                              ),
                                              const SizedBox(width: 10),
                                              const Text('Обычный угол (3 клика)'),
                                            ],
                                          ),
                                        ),
                                        PopupMenuItem<AngleType>(
                                          value: AngleType.cobb,
                                          child: Row(
                                            children: [
                                              Icon(
                                                _currentAngleType == AngleType.cobb ? Icons.check : Icons.check_box_outline_blank,
                                                size: 20,
                                                color: _currentAngleType == AngleType.cobb ? Colors.blue : Colors.grey,
                                              ),
                                              const SizedBox(width: 10),
                                              const Text('Угол Кобба (4 клика)'),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ).then((AngleType? selectedType) {
                                      if (selectedType != null && selectedType != _currentAngleType) {
                                        setState(() {
                                          _currentAngleType = selectedType;
                                          // Очищаем текущие точки при смене типа
                                          _anglePoints = [];
                                        });
                                        // Показываем подсказку о выбранном режиме
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(selectedType == AngleType.cobb 
                                                ? 'Выбран: Угол Кобба (4 клика)' 
                                                : 'Выбран: Обычный угол (3 клика)'),
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    });
                                  },
                                  child: Tooltip(
                                    message: _currentAngleType == AngleType.normal 
                                        ? 'Измерение угла (3 клика)\nПКМ: выбрать тип угла' 
                                        : 'Угол Кобба (4 клика)\nПКМ: выбрать тип угла',
                                    child: IconButton(
                                      icon: const Icon(Icons.alt_route), 
                                      color: _currentTool == ToolMode.angle ? Colors.lightBlueAccent : Colors.white, 
                                      onPressed: () => _switchTool(ToolMode.angle),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.zoom_in), 
                                  color: _currentTool == ToolMode.magnifier ? Colors.lightBlueAccent : Colors.white, 
                                  onPressed: () => _switchTool(ToolMode.magnifier),
                                  tooltip: 'Лупа',
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
                                  icon: const Icon(Icons.arrow_forward), 
                                  color: _currentTool == ToolMode.arrow ? Colors.lightBlueAccent : Colors.white, 
                                  tooltip: 'Стрелка',
                                  onPressed: () => _switchTool(ToolMode.arrow)
                                ),
                                const SizedBox(height: 15),
                                IconButton(
                                  icon: const Icon(Icons.text_fields), 
                                  color: _currentTool == ToolMode.text ? Colors.lightBlueAccent : Colors.white, 
                                  tooltip: 'Текст',
                                  onPressed: () => _switchTool(ToolMode.text)
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
                                      _contrast = _initialContrast;
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
                            ),
                          ),
                          // Область просмотра
                          Expanded(
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        "W/L: ${_windowCenter?.round()}/${_windowWidth?.round()} | ${(_pixelSpacingRow * 100).toStringAsFixed(1)}% ${_isInverted ? '| Инвертировано' : ''} ${_rotationAngle != 0.0 ? '| Поворот: ${_rotationAngle.round()}°' : ''}${_currentTool == ToolMode.brightness ? ' | Ярк: ${_brightness.toStringAsFixed(1)} | Контр: ${_contrast.toStringAsFixed(1)}' : ''}",
                                        style: const TextStyle(color: Colors.white, fontSize: 16),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 2,
                                        softWrap: true,
                                      ),
                                      if (_currentTool == ToolMode.brightness) ...[
                                        const SizedBox(height: 5),
                                        const Text("Зажмите ЛКМ и двигайте: ↔ контраст, ↕ яркость", 
                                            style: TextStyle(color: Colors.grey, fontSize: 12)),
                                      ],
                                    ],
                                  ),
                                ),
                                        Expanded(
                                          child: MouseRegion(
                                            onExit: _currentTool == ToolMode.magnifier ? (PointerEvent event) {
                                              _handlePointerExit(event);
                                            } : null,
                                            child: Listener(
                                              onPointerDown: (PointerDownEvent event) {
                                                // Ранний перехват для проверки измерений и блокировки pan
                                                if (_currentTool == ToolMode.magnifier) {
                                                  _handlePointerDown(event);
                                                } else if (_currentTool == ToolMode.brightness && event.buttons == 1) {
                                                  // Обрабатываем начало перетаскивания для инструмента яркости (ЛКМ)
                                                  setState(() {
                                                    _brightnessDragStart = event.localPosition;
                                                    _brightnessAtDragStart = _brightness;
                                                    _contrastAtDragStart = _contrast;
                                                    _addToHistory(ActionType.brightnessChanged, _brightness);
                                                  });
                                                } else if (_currentTool == ToolMode.brightness && event.buttons == 2) {
                                                  // Обрабатываем зажатие ПКМ для pan
                                                  setState(() {
                                                    _isRightButtonPressed = true;
                                                  });
                                                } else {
                                                  // Проверяем наличие измерений рядом с указателем
                                                  final hasMeasurement = _checkMeasurementNearPointer(event.localPosition);
                                                  if (hasMeasurement != _hasMeasurementNearPointer) {
                                                    setState(() {
                                                      _hasMeasurementNearPointer = hasMeasurement;
                                                    });
                                                  }
                                                  
                                                  // Если есть измерение рядом, начинаем перетаскивание напрямую через Listener
                                                  if (hasMeasurement && _rulerPoints.isEmpty && _anglePoints.isEmpty && _arrowPoints.isEmpty) {
                                                    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
                                                      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
                                                      _matrixCacheValid = true;
                                                    }
                                                    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, event.localPosition);
                                                    
                                                    // Проверяем и начинаем перетаскивание линеек
                                                    if (_selectedRulerIndex != null && 
                                                        _selectedRulerIndex! >= 0 && 
                                                        _selectedRulerIndex! < _completedRulerLines.length &&
                                                        _isPointOnRulerDragHandle(sceneOffset, _selectedRulerIndex!)) {
                                                      setState(() {
                                                        _isDraggingRuler = true;
                                                        _dragOffset = sceneOffset;
                                                        _hasMeasurementNearPointer = true;
                                                      });
                                                      return;
                                                    }
                                                    
                                                    final rulerIndex = _getRulerLineAtPoint(sceneOffset, 15.0);
                                                    if (rulerIndex != null) {
                                                      setState(() {
                                                        _selectedRulerIndex = rulerIndex;
                                                        _selectedAngleIndex = null;
                                                        _selectedTextIndex = null;
                                                        _selectedArrowIndex = null;
                                                        _isDraggingRuler = true;
                                                        _dragOffset = sceneOffset;
                                                        _hasMeasurementNearPointer = true;
                                                      });
                                                      return;
                                                    }
                                                    
                                                    // Проверяем и начинаем перетаскивание углов
                                                    if (_selectedAngleIndex != null && _isPointOnAngleDragHandle(sceneOffset, _selectedAngleIndex!)) {
                                                      setState(() {
                                                        _isDraggingAngle = true;
                                                        _dragOffset = sceneOffset;
                                                        _hasMeasurementNearPointer = true;
                                                      });
                                                      return;
                                                    }
                                                    
                                                    final angleIndex = _getAngleAtPoint(sceneOffset, 30.0);
                                                    if (angleIndex != null) {
                                                      setState(() {
                                                        _selectedAngleIndex = angleIndex;
                                                        _selectedRulerIndex = null;
                                                        _selectedTextIndex = null;
                                                        _selectedArrowIndex = null;
                                                        _isDraggingAngle = true;
                                                        _dragOffset = sceneOffset;
                                                        _hasMeasurementNearPointer = true;
                                                      });
                                                      return;
                                                    }
                                                    
                                                    // Проверяем выбранную линейку по расстоянию до линии
                                                    if (_selectedRulerIndex != null) {
                                                      final canvasSize = _getCanvasSize();
                                                      final line = _completedRulerLines[_selectedRulerIndex!];
                                                      final absStart = line.getAbsoluteStart(canvasSize);
                                                      final absEnd = line.getAbsoluteEnd(canvasSize);
                                                      final distToLine = _pointToLineDistance(sceneOffset, absStart, absEnd);
                                                      if (distToLine <= 15.0) {
                                                        setState(() {
                                                          _isDraggingRuler = true;
                                                          _dragOffset = sceneOffset;
                                                          _hasMeasurementNearPointer = true;
                                                        });
                                                        return;
                                                      }
                                                    }
                                                    
                                                    // Проверяем выбранный угол по расстоянию
                                                    if (_selectedAngleIndex != null) {
                                                      final canvasSize = _getCanvasSize();
                                                      final angle = _completedAngles[_selectedAngleIndex!];
                                                      final absVertex = angle.getAbsoluteVertex(canvasSize);
                                                      final absPoint1 = angle.getAbsolutePoint1(canvasSize);
                                                      final absPoint2 = angle.getAbsolutePoint2(canvasSize);
                                                      final distToVertex = (sceneOffset - absVertex).distance;
                                                      final distToPoint1 = (sceneOffset - absPoint1).distance;
                                                      final distToPoint2 = (sceneOffset - absPoint2).distance;
                                                      final distToRay1 = _pointToLineDistance(sceneOffset, absVertex, absPoint1);
                                                      final distToRay2 = _pointToLineDistance(sceneOffset, absVertex, absPoint2);
                                                      
                                                      if (distToVertex <= 30.0 || distToPoint1 <= 30.0 || distToPoint2 <= 30.0 || 
                                                          distToRay1 <= 30.0 || distToRay2 <= 30.0) {
                                                        setState(() {
                                                          _isDraggingAngle = true;
                                                          _dragOffset = sceneOffset;
                                                          _hasMeasurementNearPointer = true;
                                                        });
                                                        return;
                                                      }
                                                    }
                                                    
                                                    // Проверяем и начинаем перетаскивание текстовых аннотаций
                                                    if (_selectedTextIndex != null && _isPointOnTextDragHandle(sceneOffset, _selectedTextIndex!)) {
                                                      setState(() {
                                                        _isDraggingText = true;
                                                        _dragOffset = sceneOffset;
                                                        _hasMeasurementNearPointer = true;
                                                      });
                                                      return;
                                                    }
                                                    
                                                    final textIndex = _getTextAnnotationAtPoint(sceneOffset, 50.0);
                                                    if (textIndex != null) {
                                                      setState(() {
                                                        _selectedTextIndex = textIndex;
                                                        _selectedRulerIndex = null;
                                                        _selectedAngleIndex = null;
                                                        _selectedArrowIndex = null;
                                                        _isDraggingText = true;
                                                        _dragOffset = sceneOffset;
                                                        _hasMeasurementNearPointer = true;
                                                      });
                                                      return;
                                                    }
                                                    
                                                    // Проверяем и начинаем перетаскивание стрелок
                                                    if (_selectedArrowIndex != null && _isPointOnArrowDragHandle(sceneOffset, _selectedArrowIndex!)) {
                                                      setState(() {
                                                        _isDraggingArrow = true;
                                                        _dragOffset = sceneOffset;
                                                        _hasMeasurementNearPointer = true;
                                                      });
                                                      return;
                                                    }
                                                    
                                                    final arrowIndex = _getArrowAnnotationAtPoint(sceneOffset, 30.0);
                                                    if (arrowIndex != null) {
                                                      setState(() {
                                                        _selectedArrowIndex = arrowIndex;
                                                        _selectedRulerIndex = null;
                                                        _selectedAngleIndex = null;
                                                        _selectedTextIndex = null;
                                                        _isDraggingArrow = true;
                                                        _dragOffset = sceneOffset;
                                                        _hasMeasurementNearPointer = true;
                                                      });
                                                      return;
                                                    }
                                                  }
                                                }
                                              },
                                              onPointerUp: (PointerUpEvent event) {
                                                if (_currentTool == ToolMode.magnifier) {
                                                  _handlePointerUp(event);
                                                } else if (_currentTool == ToolMode.brightness && _brightnessDragStart != null) {
                                                  // Завершаем перетаскивание яркости/контраста
                                                  setState(() {
                                                    _brightnessDragStart = null;
                                                    _brightnessAtDragStart = null;
                                                    _contrastAtDragStart = null;
                                                  });
                                                } else if (_currentTool == ToolMode.brightness && _isRightButtonPressed) {
                                                  // Завершаем pan при отпускании ПКМ
                                                  setState(() {
                                                    _isRightButtonPressed = false;
                                                  });
                                                } else if (_isDraggingRuler || _isDraggingAngle || _isDraggingText || _isDraggingArrow) {
                                                  // Завершаем перетаскивание
                                                  setState(() {
                                                    _isDraggingRuler = false;
                                                    _isDraggingAngle = false;
                                                    _isDraggingText = false;
                                                    _isDraggingArrow = false;
                                                    _dragOffset = null;
                                                    _hasMeasurementNearPointer = false;
                                                  });
                                                }
                                              },
                                              onPointerMove: (PointerMoveEvent event) {
                                                if (_currentTool == ToolMode.magnifier) {
                                                  _handlePointerMove(event);
                                                } else if (_currentTool == ToolMode.brightness && 
                                                    _brightnessDragStart != null && 
                                                    _brightnessAtDragStart != null && 
                                                    _contrastAtDragStart != null) {
                                                  // Обрабатываем перетаскивание для инструмента яркости
                                                  final delta = event.localPosition - _brightnessDragStart!;
                                                  final contrastDelta = delta.dx * 0.01;
                                                  final brightnessDelta = -delta.dy * 0.01;
                                                  
                                                  double newContrast = (_contrastAtDragStart! + contrastDelta).clamp(0.1, 3.0);
                                                  double newBrightness = (_brightnessAtDragStart! + brightnessDelta).clamp(0.1, 3.0);
                                                  
                                                  setState(() {
                                                    _contrast = newContrast;
                                                    _brightness = newBrightness;
                                                  });
                                                } else if (_currentTool == ToolMode.brightness && event.buttons == 2) {
                                                  // Обновляем состояние ПКМ при движении для pan
                                                  if (!_isRightButtonPressed) {
                                                    setState(() {
                                                      _isRightButtonPressed = true;
                                                    });
                                                  }
                                                } else {
                                                  // Обновляем флаг при движении указателя
                                                  final hasMeasurement = _checkMeasurementNearPointer(event.localPosition);
                                                  if (hasMeasurement != _hasMeasurementNearPointer && !_isDraggingRuler && !_isDraggingAngle && !_isDraggingText && !_isDraggingArrow) {
                                                    setState(() {
                                                      _hasMeasurementNearPointer = hasMeasurement;
                                                    });
                                                  }
                                                  
                                                  // Обрабатываем перетаскивание напрямую через Listener
                                                  if (_isDraggingRuler && 
                                                      _selectedRulerIndex != null && 
                                                      _selectedRulerIndex! >= 0 && 
                                                      _selectedRulerIndex! < _completedRulerLines.length &&
                                                      _dragOffset != null) {
                                                    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
                                                      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
                                                      _matrixCacheValid = true;
                                                    }
                                                    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, event.localPosition);
                                                    final canvasSize = _getCanvasSize();
                                                    final deltaScene = sceneOffset - _dragOffset!;
                                                    final deltaRelative = Offset(
                                                      deltaScene.dx / canvasSize.width,
                                                      deltaScene.dy / canvasSize.height,
                                                    );
                                                    setState(() {
                                                      final line = _completedRulerLines[_selectedRulerIndex!];
                                                      _completedRulerLines[_selectedRulerIndex!] = RulerLine(
                                                        start: Offset(line.start.dx + deltaRelative.dx, line.start.dy + deltaRelative.dy),
                                                        end: Offset(line.end.dx + deltaRelative.dx, line.end.dy + deltaRelative.dy),
                                                        pixelSpacing: line.pixelSpacing,
                                                      );
                                                      _dragOffset = sceneOffset;
                                                    });
                                                    return;
                                                  }
                                                  
                                                  if (_isDraggingAngle && _selectedAngleIndex != null && _dragOffset != null) {
                                                    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
                                                      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
                                                      _matrixCacheValid = true;
                                                    }
                                                    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, event.localPosition);
                                                    final canvasSize = _getCanvasSize();
                                                    final deltaScene = sceneOffset - _dragOffset!;
                                                    final deltaRelative = Offset(
                                                      deltaScene.dx / canvasSize.width,
                                                      deltaScene.dy / canvasSize.height,
                                                    );
                                                    setState(() {
                                                      final angle = _completedAngles[_selectedAngleIndex!];
                                                      
                                                      if (angle.type == AngleType.cobb) {
                                                        // Для угла Кобба перемещаем все 4 точки
                                                        _completedAngles[_selectedAngleIndex!] = AngleMeasurement(
                                                          vertex: Offset(angle.vertex.dx + deltaRelative.dx, angle.vertex.dy + deltaRelative.dy),
                                                          point1: Offset(angle.point1.dx + deltaRelative.dx, angle.point1.dy + deltaRelative.dy),
                                                          point2: Offset(angle.point2.dx + deltaRelative.dx, angle.point2.dy + deltaRelative.dy),
                                                          type: AngleType.cobb,
                                                          line1End: angle.line1End != null 
                                                              ? Offset(angle.line1End!.dx + deltaRelative.dx, angle.line1End!.dy + deltaRelative.dy)
                                                              : null,
                                                          line2End: angle.line2End != null
                                                              ? Offset(angle.line2End!.dx + deltaRelative.dx, angle.line2End!.dy + deltaRelative.dy)
                                                              : null,
                                                        );
                                                      } else {
                                                        // Для обычного угла перемещаем 3 точки
                                                        _completedAngles[_selectedAngleIndex!] = AngleMeasurement(
                                                          vertex: Offset(angle.vertex.dx + deltaRelative.dx, angle.vertex.dy + deltaRelative.dy),
                                                          point1: Offset(angle.point1.dx + deltaRelative.dx, angle.point1.dy + deltaRelative.dy),
                                                          point2: Offset(angle.point2.dx + deltaRelative.dx, angle.point2.dy + deltaRelative.dy),
                                                          type: AngleType.normal,
                                                        );
                                                      }
                                                      
                                                      _dragOffset = sceneOffset;
                                                    });
                                                    return;
                                                  }
                                                  
                                                  // Обрабатываем перетаскивание текстовых аннотаций
                                                  if (_isDraggingText && _selectedTextIndex != null && _dragOffset != null) {
                                                    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
                                                      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
                                                      _matrixCacheValid = true;
                                                    }
                                                    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, event.localPosition);
                                                    final deltaScene = sceneOffset - _dragOffset!;
                                                    setState(() {
                                                      final annotation = _textAnnotations[_selectedTextIndex!];
                                                      _textAnnotations[_selectedTextIndex!] = TextAnnotation(
                                                        position: Offset(annotation.position.dx + deltaScene.dx, annotation.position.dy + deltaScene.dy),
                                                        text: annotation.text,
                                                        color: annotation.color,
                                                        fontSize: annotation.fontSize,
                                                      );
                                                      _dragOffset = sceneOffset;
                                                    });
                                                    return;
                                                  }
                                                  
                                                  // Обрабатываем перетаскивание стрелок
                                                  if (_isDraggingArrow && _selectedArrowIndex != null && _dragOffset != null) {
                                                    if (!_matrixCacheValid || _cachedInvertedMatrix == null) {
                                                      _cachedInvertedMatrix = Matrix4.inverted(_transformationController.value);
                                                      _matrixCacheValid = true;
                                                    }
                                                    final Offset sceneOffset = MatrixUtils.transformPoint(_cachedInvertedMatrix!, event.localPosition);
                                                    final deltaScene = sceneOffset - _dragOffset!;
                                                    setState(() {
                                                      final arrow = _arrowAnnotations[_selectedArrowIndex!];
                                                      _arrowAnnotations[_selectedArrowIndex!] = ArrowAnnotation(
                                                        start: Offset(arrow.start.dx + deltaScene.dx, arrow.start.dy + deltaScene.dy),
                                                        end: Offset(arrow.end.dx + deltaScene.dx, arrow.end.dy + deltaScene.dy),
                                                        color: arrow.color,
                                                        strokeWidth: arrow.strokeWidth,
                                                      );
                                                      _dragOffset = sceneOffset;
                                                    });
                                                    return;
                                                  }
                                                }
                                              },
                                              onPointerSignal: (PointerSignalEvent event) {
                                                // Колесико мыши теперь работает для масштабирования через InteractiveViewer
                                              },
                                              child: GestureDetector(
                                              behavior: HitTestBehavior.opaque,
                                              onTapDown: _handleTap,
                                              onTapUp: _handleTapUp,
                                              onDoubleTap: _handleDoubleTap,
                                              onPanStart: _handlePanStart,
                                              onPanUpdate: _handlePanUpdate,
                                              onPanEnd: _handlePanEnd,
                                              child: AbsorbPointer(
                                                absorbing: _isDraggingRuler || _isDraggingAngle || _isDraggingText || _isDraggingArrow,
                                                child: InteractiveViewer(
                                                  transformationController: _transformationController,
                                                  panEnabled: (_currentTool == ToolMode.pan || (_currentTool == ToolMode.brightness && _isRightButtonPressed)) && !_isDraggingRuler && !_isDraggingAngle && !_isDraggingText && !_isDraggingArrow && !_hasMeasurementNearPointer && _brightnessDragStart == null,
                                                  scaleEnabled: (_currentTool == ToolMode.pan || _currentTool == ToolMode.brightness) && !_isDraggingRuler && !_isDraggingAngle && !_isDraggingText && !_isDraggingArrow && !_hasMeasurementNearPointer && _brightnessDragStart == null,
                                                minScale: 0.1, maxScale: 8.0,
                                                child: RepaintBoundary(
                                                  key: _captureKey,
                                                  child: Stack(
                                                  key: _canvasSizeKey,
                                                  fit: StackFit.expand,
                                                  children: [
                                                    // Базовый чёрный слой, чтобы фон всегда оставался чёрным
                                                    Container(color: Colors.black),
                                                    // Применяем яркость, инверсию и поворот прямо во Flutter
                                                    ClipRect(
                                                      child: Transform.rotate(
                                                      angle: _rotationAngle * 3.14159 / 180, // Конвертируем градусы в радианы
                                                      child: ColorFiltered(
                                                        // Применяем контраст: (pixel - 128) * contrast + 128
                                                        colorFilter: ColorFilter.matrix([
                                                          _contrast, 0, 0, 0, 128 * (1 - _contrast),  // Red
                                                          0, _contrast, 0, 0, 128 * (1 - _contrast),  // Green
                                                          0, 0, _contrast, 0, 128 * (1 - _contrast),  // Blue
                                                          0, 0, 0, 1, 0,                              // Alpha
                                                        ]),
                                                        child: ColorFiltered(
                                                          // Применяем яркость после контраста
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
                                                    ),
                                                  ), // Закрываем Transform.rotate
                                                  ), // Закрываем ClipRect
                                                  CustomPaint(
                                                    painter: RulerPainter(
                                                      currentPoints: _isCalibrationMode ? List.of(_calibrationPoints) : List.of(_rulerPoints), 
                                                      completedLines: List.of(_completedRulerLines),
                                                      pixelSpacing: _pixelSpacingRow,
                                                      selectedIndex: _selectedRulerIndex,
                                                      imageSize: _decodedImage != null 
                                                        ? Size(_decodedImage!.width.toDouble(), _decodedImage!.height.toDouble())
                                                        : null,
                                                      rotationAngle: _rotationAngle,
                                                    ),
                                                    child: Container(), // Пустой контейнер для предотвращения ошибок
                                                  ),
                                                  CustomPaint(
                                                    painter: AnglePainter(
                                                      currentPoints: List.of(_anglePoints),
                                                      completedAngles: List.of(_completedAngles),
                                                      selectedIndex: _selectedAngleIndex,
                                                      imageSize: _decodedImage != null 
                                                        ? Size(_decodedImage!.width.toDouble(), _decodedImage!.height.toDouble())
                                                        : null,
                                                      rotationAngle: _rotationAngle,
                                                      currentAngleType: _currentAngleType,
                                                    ),
                                                    child: Container(), // Пустой контейнер для предотвращения ошибок
                                                  ),
                                                  CustomPaint(
                                                    painter: AnnotationPainter(
                                                      textAnnotations: _textAnnotations,
                                                      arrowAnnotations: _arrowAnnotations,
                                                      arrowPoints: _arrowPoints,
                                                      selectedTextIndex: _selectedTextIndex,
                                                      selectedArrowIndex: _selectedArrowIndex,
                                                    ),
                                                    child: Container(), // Пустой контейнер для предотвращения ошибок
                                                  ),
                                                  CustomPaint(
                                                    painter: MagnifierPainter(
                                                      position: _magnifierPosition,
                                                      size: _magnifierSize,
                                                      zoom: _magnifierZoom,
                                                      transformMatrix: _transformationController.value,
                                                      decodedImage: _decodedImage,
                                                      pixelSpacing: _pixelSpacingRow,
                                                      brightness: _brightness,
                                                      isInverted: _isInverted,
                                                      rotationAngle: _rotationAngle,
                                                    ),
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