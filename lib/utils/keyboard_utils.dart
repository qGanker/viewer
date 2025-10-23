import 'package:flutter/services.dart';

class KeyboardUtils {
  // Маппинг русских клавиш на английские
  static const Map<String, String> _russianToEnglish = {
    'й': 'Q', 'ц': 'W', 'у': 'E', 'к': 'R', 'е': 'T', 'н': 'Y', 'г': 'U', 'ш': 'I', 'щ': 'O', 'з': 'P',
    'ф': 'A', 'ы': 'S', 'в': 'D', 'а': 'F', 'п': 'G', 'р': 'H', 'о': 'J', 'л': 'K', 'д': 'L',
    'я': 'Z', 'ч': 'X', 'с': 'C', 'м': 'V', 'и': 'B', 'т': 'N', 'ь': 'M',
    'ъ': 'B', 'э': 'E', 'ю': 'U', 'б': 'B', 'ё': 'E',
  };

  // Нормализация клавиши к английской букве
  static String normalizeKey(LogicalKeyboardKey key) {
    try {
      // Получаем строку клавиши из keyLabel (более надежно для букв)
      String keyString = key.keyLabel ?? '';
      
      // Если keyLabel пустой, используем debugName как fallback
      if (keyString.isEmpty) {
        keyString = key.debugName ?? '';
      }
      
      // Убираем префикс "Key " если есть
      if (keyString.startsWith('Key ')) {
        keyString = keyString.substring(4);
      }
      
      // Фильтруем модификаторы - они не должны обрабатываться как основные клавиши
      if (keyString.contains('Control') || 
          keyString.contains('Alt') || 
          keyString.contains('Shift') ||
          keyString.contains('Meta') ||
          keyString.contains('Windows')) {
        return ''; // Возвращаем пустую строку для модификаторов
      }
      
      // Если это русская буква, конвертируем в английскую
      if (_russianToEnglish.containsKey(keyString.toLowerCase())) {
        return _russianToEnglish[keyString.toLowerCase()]!;
      }
      
      // Если это уже английская буква, возвращаем как есть
      if (keyString.length == 1 && keyString.toUpperCase() != keyString.toLowerCase()) {
        return keyString.toUpperCase();
      }
      
      // Для специальных клавиш возвращаем как есть
      return keyString;
    } catch (e) {
      // Fallback на debugName если keyLabel вызывает проблемы
      return key.debugName ?? 'Unknown';
    }
  }

  // Получение строкового представления клавиши для отображения
  static String getKeyDisplayString(LogicalKeyboardKey key) {
    String keyString = key.keyLabel;
    
    // Специальные клавиши
    if (key == LogicalKeyboardKey.f1) return 'F1';
    if (key == LogicalKeyboardKey.f2) return 'F2';
    if (key == LogicalKeyboardKey.f3) return 'F3';
    if (key == LogicalKeyboardKey.f4) return 'F4';
    if (key == LogicalKeyboardKey.f5) return 'F5';
    if (key == LogicalKeyboardKey.f6) return 'F6';
    if (key == LogicalKeyboardKey.f7) return 'F7';
    if (key == LogicalKeyboardKey.f8) return 'F8';
    if (key == LogicalKeyboardKey.f9) return 'F9';
    if (key == LogicalKeyboardKey.f10) return 'F10';
    if (key == LogicalKeyboardKey.f11) return 'F11';
    if (key == LogicalKeyboardKey.f12) return 'F12';
    if (key == LogicalKeyboardKey.escape) return 'Escape';
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.enter) return 'Enter';
    if (key == LogicalKeyboardKey.tab) return 'Tab';
    if (key == LogicalKeyboardKey.backspace) return 'Backspace';
    if (key == LogicalKeyboardKey.delete) return 'Delete';
    if (key == LogicalKeyboardKey.home) return 'Home';
    if (key == LogicalKeyboardKey.end) return 'End';
    if (key == LogicalKeyboardKey.pageUp) return 'PageUp';
    if (key == LogicalKeyboardKey.pageDown) return 'PageDown';
    if (key == LogicalKeyboardKey.arrowUp) return 'ArrowUp';
    if (key == LogicalKeyboardKey.arrowDown) return 'ArrowDown';
    if (key == LogicalKeyboardKey.arrowLeft) return 'ArrowLeft';
    if (key == LogicalKeyboardKey.arrowRight) return 'ArrowRight';
    
    // Для буквенных клавиш показываем английскую букву
    if (keyString.length == 1 && keyString.toUpperCase() != keyString.toLowerCase()) {
      // Если это русская буква, показываем соответствующую английскую
      if (_russianToEnglish.containsKey(keyString.toLowerCase())) {
        return _russianToEnglish[keyString.toLowerCase()]!;
      }
      return keyString.toUpperCase();
    }
    
    return keyString;
  }

  // Проверка, является ли клавиша буквенной
  static bool isLetterKey(LogicalKeyboardKey key) {
    String keyString = key.keyLabel;
    return keyString.length == 1 && keyString.toUpperCase() != keyString.toLowerCase();
  }

  // Проверка, является ли клавиша F-клавишей
  static bool isFunctionKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.f1 ||
           key == LogicalKeyboardKey.f2 ||
           key == LogicalKeyboardKey.f3 ||
           key == LogicalKeyboardKey.f4 ||
           key == LogicalKeyboardKey.f5 ||
           key == LogicalKeyboardKey.f6 ||
           key == LogicalKeyboardKey.f7 ||
           key == LogicalKeyboardKey.f8 ||
           key == LogicalKeyboardKey.f9 ||
           key == LogicalKeyboardKey.f10 ||
           key == LogicalKeyboardKey.f11 ||
           key == LogicalKeyboardKey.f12;
  }
}
