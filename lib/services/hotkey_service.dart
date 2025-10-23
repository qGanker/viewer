import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../screens/settings_screen.dart';

class HotkeyService {
  static HotkeySettings _hotkeySettings = HotkeySettings();
  static bool _isInitialized = false;

  // Инициализация сервиса
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('hotkey_settings');
    
    if (settingsJson != null) {
      try {
        _hotkeySettings = HotkeySettings.fromJson(jsonDecode(settingsJson));
      } catch (e) {
        _hotkeySettings = HotkeySettings();
      }
    } else {
      _hotkeySettings = HotkeySettings();
    }
    
    _isInitialized = true;
  }

  // Получение текущих настроек
  static HotkeySettings get hotkeySettings => _hotkeySettings;

  // Проверка, соответствует ли комбинация клавиш настройке
  static bool isKeyForTool(String keyString, String tool, {bool ctrl = false, bool alt = false, bool shift = false}) {
    print('HotkeyService.isKeyForTool called:');
    print('  tool: $tool');
    print('  keyString: $keyString');
    print('  modifiers: ctrl=$ctrl, alt=$alt, shift=$shift');
    
    KeyCombination expectedCombination;
    bool result = false;
    
    switch (tool) {
      case 'pan':
        expectedCombination = _hotkeySettings.panKey;
        break;
      case 'ruler':
        expectedCombination = _hotkeySettings.rulerKey;
        break;
      case 'brightness':
        expectedCombination = _hotkeySettings.brightnessKey;
        break;
      case 'invert':
        expectedCombination = _hotkeySettings.invertKey;
        break;
      case 'rotate':
        expectedCombination = _hotkeySettings.rotateKey;
        break;
      case 'annotation':
        expectedCombination = _hotkeySettings.annotationKey;
        break;
      case 'undo':
        expectedCombination = _hotkeySettings.undoKey;
        break;
      case 'reset':
        // Для сброса используем фиксированную клавишу F5, так как настройка удалена
        expectedCombination = const KeyCombination(key: 'F5');
        break;
      default:
        print('  ERROR: Unknown tool: $tool');
        return false;
    }
    
    print('  expected combination: ${expectedCombination.toJson()}');
    
    // Создаем комбинацию из нажатых клавиш
    KeyCombination pressedCombination = KeyCombination(
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      key: keyString,
    );
    
    print('  pressed combination: ${pressedCombination.toJson()}');
    
    result = expectedCombination == pressedCombination;
    
    print('  result: $result');
    print('  comparison: expected=${expectedCombination.toString()} == pressed=${pressedCombination.toString()}');
    
    return result;
  }

  // Получение названия инструмента по клавише
  static String? getToolNameForKey(String keyString) {
    if (_hotkeySettings.panKey == keyString) return 'Панорамирование';
    if (_hotkeySettings.rulerKey == keyString) return 'Линейка';
    if (_hotkeySettings.brightnessKey == keyString) return 'Яркость';
    if (_hotkeySettings.invertKey == keyString) return 'Инверсия';
    if (_hotkeySettings.rotateKey == keyString) return 'Поворот';
    if (_hotkeySettings.annotationKey == keyString) return 'Аннотации';
    if (_hotkeySettings.undoKey == keyString) return 'Отмена';
    // Для сброса проверяем фиксированную клавишу F5
    if (keyString == 'F5') return 'Сброс';
    return null;
  }

  // Обновление настроек
  static Future<void> updateSettings(HotkeySettings newSettings) async {
    _hotkeySettings = newSettings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('hotkey_settings', jsonEncode(_hotkeySettings.toJson()));
  }

  // Принудительная перезагрузка настроек
  static Future<void> reloadSettings() async {
    _isInitialized = false;
    await initialize();
  }

  // Сброс к значениям по умолчанию
  static Future<void> resetToDefaults() async {
    _hotkeySettings = HotkeySettings();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('hotkey_settings', jsonEncode(_hotkeySettings.toJson()));
  }
}
