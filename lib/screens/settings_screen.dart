import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import '../utils/keyboard_utils.dart';
import 'home_screen.dart';

// Класс для хранения комбинации клавиш
class KeyCombination {
  final bool ctrl;
  final bool alt;
  final bool shift;
  final String key;

  const KeyCombination({
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    required this.key,
  });

  String get displayString {
    List<String> modifiers = [];
    if (ctrl) modifiers.add('Ctrl');
    if (alt) modifiers.add('Alt');
    if (shift) modifiers.add('Shift');
    
    if (modifiers.isEmpty) {
      return key;
    } else {
      return '${modifiers.join('+')}+$key';
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'ctrl': ctrl,
      'alt': alt,
      'shift': shift,
      'key': key,
    };
  }

  factory KeyCombination.fromJson(Map<String, dynamic> json) {
    return KeyCombination(
      ctrl: json['ctrl'] ?? false,
      alt: json['alt'] ?? false,
      shift: json['shift'] ?? false,
      key: json['key'] ?? '',
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KeyCombination &&
        other.ctrl == ctrl &&
        other.alt == alt &&
        other.shift == shift &&
        other.key == key;
  }

  @override
  int get hashCode {
    return ctrl.hashCode ^ alt.hashCode ^ shift.hashCode ^ key.hashCode;
  }
}

// Класс для хранения настроек горячих клавиш
class HotkeySettings {
  final KeyCombination panKey;
  final KeyCombination rulerKey;
  final KeyCombination angleKey;
  final KeyCombination magnifierKey;
  final KeyCombination brightnessKey;
  final KeyCombination invertKey;
  final KeyCombination rotateKey;
  final KeyCombination annotationKey;
  final KeyCombination undoKey;

  HotkeySettings({
    KeyCombination? panKey,
    KeyCombination? rulerKey,
    KeyCombination? angleKey,
    KeyCombination? magnifierKey,
    KeyCombination? brightnessKey,
    KeyCombination? invertKey,
    KeyCombination? rotateKey,
    KeyCombination? annotationKey,
    KeyCombination? undoKey,
  }) : panKey = panKey ?? const KeyCombination(key: 'P'),
       rulerKey = rulerKey ?? const KeyCombination(key: 'R'),
       angleKey = angleKey ?? const KeyCombination(key: 'G'),
       magnifierKey = magnifierKey ?? const KeyCombination(key: 'M'),
       brightnessKey = brightnessKey ?? const KeyCombination(key: 'B'),
       invertKey = invertKey ?? const KeyCombination(key: 'I'),
       rotateKey = rotateKey ?? const KeyCombination(key: 'O'),
       annotationKey = annotationKey ?? const KeyCombination(key: 'A'),
       undoKey = undoKey ?? const KeyCombination(key: 'Z');

  Map<String, dynamic> toJson() {
    return {
      'panKey': panKey.toJson(),
      'rulerKey': rulerKey.toJson(),
      'angleKey': angleKey.toJson(),
      'magnifierKey': magnifierKey.toJson(),
      'brightnessKey': brightnessKey.toJson(),
      'invertKey': invertKey.toJson(),
      'rotateKey': rotateKey.toJson(),
      'annotationKey': annotationKey.toJson(),
      'undoKey': undoKey.toJson(),
    };
  }

  factory HotkeySettings.fromJson(Map<String, dynamic> json) {
    return HotkeySettings(
      panKey: _parseKeyCombination(json['panKey'], 'P'),
      rulerKey: _parseKeyCombination(json['rulerKey'], 'R'),
      angleKey: _parseKeyCombination(json['angleKey'], 'G'), // Поддержка старых настроек без angleKey
      magnifierKey: _parseKeyCombination(json['magnifierKey'], 'M'), // Поддержка старых настроек без magnifierKey
      brightnessKey: _parseKeyCombination(json['brightnessKey'], 'B'),
      invertKey: _parseKeyCombination(json['invertKey'], 'I'),
      rotateKey: _parseKeyCombination(json['rotateKey'], 'O'),
      annotationKey: _parseKeyCombination(json['annotationKey'], 'A'),
      undoKey: _parseKeyCombination(json['undoKey'], 'Z'),
    );
  }

  // Вспомогательный метод для парсинга KeyCombination с поддержкой старых форматов
  static KeyCombination _parseKeyCombination(dynamic value, String defaultKey) {
    if (value == null) {
      return KeyCombination(key: defaultKey);
    }
    
    // Если это строка (старый формат), создаем простую комбинацию
    if (value is String) {
      return KeyCombination(key: value);
    }
    
    // Если это Map (новый формат), парсим как KeyCombination
    if (value is Map<String, dynamic>) {
      return KeyCombination.fromJson(value);
    }
    
    // Fallback на значение по умолчанию
    return KeyCombination(key: defaultKey);
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Прямые поля вместо объекта
  KeyCombination _panKey = const KeyCombination(key: 'P');
  KeyCombination _rulerKey = const KeyCombination(key: 'R');
  KeyCombination _angleKey = const KeyCombination(key: 'G');
  KeyCombination _magnifierKey = const KeyCombination(key: 'M');
  KeyCombination _brightnessKey = const KeyCombination(key: 'B');
  KeyCombination _invertKey = const KeyCombination(key: 'I');
  KeyCombination _rotateKey = const KeyCombination(key: 'O');
  KeyCombination _annotationKey = const KeyCombination(key: 'A');
  KeyCombination _undoKey = const KeyCombination(key: 'Z');
  
  bool _isListening = false;
  String? _listeningFor;
  Timer? _listeningTimeout;
  
  // Переменные для калибровки
  final TextEditingController _calibrationController = TextEditingController();
  double _currentPixelSpacing = 1.0;
  
  final Map<String, String> _toolNames = {
    'panKey': 'Панорамирование',
    'rulerKey': 'Линейка',
    'angleKey': 'Угол',
    'magnifierKey': 'Лупа',
    'brightnessKey': 'Яркость',
    'invertKey': 'Инверсия',
    'rotateKey': 'Поворот',
    'annotationKey': 'Аннотации',
    'undoKey': 'Отмена',
  };

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadCalibrationSettings();
  }

  @override
  void dispose() {
    _listeningTimeout?.cancel();
    _calibrationController.dispose();
    super.dispose();
  }
  
  Future<void> _loadCalibrationSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pixelSpacing = prefs.getDouble('pixel_spacing_row') ?? 1.0;
      setState(() {
        _currentPixelSpacing = pixelSpacing;
        _calibrationController.text = pixelSpacing.toStringAsFixed(3);
      });
    } catch (e) {
      print('Ошибка при загрузке настроек калибровки: $e');
    }
  }
  
  Future<void> _saveCalibrationSettings(double pixelSpacing) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('pixel_spacing_row', pixelSpacing);
      setState(() {
        _currentPixelSpacing = pixelSpacing;
        _calibrationController.text = pixelSpacing.toStringAsFixed(3);
      });
    } catch (e) {
      print('Ошибка при сохранении настроек калибровки: $e');
    }
  }
  
  Future<void> _startCalibration() async {
    // Возвращаемся на предыдущий экран (HomeScreen) и активируем режим калибровки
    Navigator.of(context).pop(true); // true означает, что нужно активировать режим калибровки
  }
  
  Future<void> _saveCalibrationFromInput() async {
    final value = _calibrationController.text.trim();
    if (value.isNotEmpty) {
      final parsed = double.tryParse(value);
      if (parsed != null && parsed > 0) {
        await _saveCalibrationSettings(parsed);
        // Возвращаем значение в HomeScreen для обновления тегов
        Navigator.of(context).pop(parsed);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Значение сохранено: ${parsed.toStringAsFixed(3)} мм/пиксель'),
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Введите корректное положительное число'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settingsJson = prefs.getString('hotkey_settings');
      
      if (settingsJson != null) {
        try {
          final decodedSettings = jsonDecode(settingsJson);
          if (decodedSettings != null && decodedSettings is Map && mounted) {
            final hotkeySettings = HotkeySettings.fromJson(Map<String, dynamic>.from(decodedSettings));
            setState(() {
            _panKey = hotkeySettings.panKey;
            _rulerKey = hotkeySettings.rulerKey;
            _angleKey = hotkeySettings.angleKey;
            _magnifierKey = hotkeySettings.magnifierKey;
            _brightnessKey = hotkeySettings.brightnessKey;
              _invertKey = hotkeySettings.invertKey;
              _rotateKey = hotkeySettings.rotateKey;
              _annotationKey = hotkeySettings.annotationKey;
              _undoKey = hotkeySettings.undoKey;
            });
          }
        } catch (parseError) {
          print('Ошибка при парсинге настроек: $parseError');
          // При ошибке парсинга используем значения по умолчанию
          // Они уже установлены в initState
        }
      }
    } catch (e) {
      print('Ошибка при загрузке настроек: $e');
      // При ошибке используем значения по умолчанию
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hotkeySettings = HotkeySettings(
        panKey: _panKey,
        rulerKey: _rulerKey,
        angleKey: _angleKey,
        magnifierKey: _magnifierKey,
        brightnessKey: _brightnessKey,
        invertKey: _invertKey,
        rotateKey: _rotateKey,
        annotationKey: _annotationKey,
        undoKey: _undoKey,
      );
      await prefs.setString('hotkey_settings', jsonEncode(hotkeySettings.toJson()));
      
      if (mounted) {
        setState(() {
          // Настройки загружены
        });
      }
    } catch (e) {
      print('Ошибка при сохранении настроек: $e');
    }
  }

  // Простая проверка на дублирующиеся клавиши
  bool _isDuplicateKey(KeyCombination keyCombination, String currentKeyName) {
    List<KeyCombination> allKeys = [
      _panKey,
      _rulerKey,
      _angleKey,
      _magnifierKey,
      _brightnessKey,
      _invertKey,
      _rotateKey,
      _annotationKey,
      _undoKey,
    ];
    
    List<String> keyNames = [
      'panKey', 'rulerKey', 'angleKey', 'magnifierKey', 'brightnessKey', 'invertKey',
      'rotateKey', 'annotationKey', 'undoKey'
    ];
    
    for (int i = 0; i < allKeys.length; i++) {
      if (keyNames[i] != currentKeyName && allKeys[i] == keyCombination) {
        return true;
      }
    }
    return false;
  }
  
  // Простое обновление настроек с прямым обновлением полей
  void _updateHotkeySetting(String keyName, KeyCombination combination) {
    setState(() {
      switch (keyName) {
        case 'panKey':
          _panKey = combination;
          break;
        case 'rulerKey':
          _rulerKey = combination;
          break;
        case 'angleKey':
          _angleKey = combination;
          break;
        case 'magnifierKey':
          _magnifierKey = combination;
          break;
        case 'brightnessKey':
          _brightnessKey = combination;
          break;
        case 'invertKey':
          _invertKey = combination;
          break;
        case 'rotateKey':
          _rotateKey = combination;
          break;
        case 'annotationKey':
          _annotationKey = combination;
          break;
        case 'undoKey':
          _undoKey = combination;
          break;
      }
    });
  }

  void _startListening(String key) {
    if (!mounted) return;
    
    // Отменяем предыдущий таймаут если есть
    _listeningTimeout?.cancel();
    
    setState(() {
      _isListening = true;
      _listeningFor = key;
    });
    
    // Устанавливаем таймаут на 10 секунд
    _listeningTimeout = Timer(const Duration(seconds: 10), () {
      if (_isListening && mounted) {
        _stopListening();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Время ожидания клавиши истекло'),
            duration: Duration(milliseconds: 1500),
            backgroundColor: Colors.orange,
          ),
        );
      }
    });
  }

  void _stopListening() {
    if (mounted) {
      _listeningTimeout?.cancel();
      setState(() {
        _isListening = false;
        _listeningFor = null;
      });
    }
  }

  // Кэш для предотвращения повторной обработки одной и той же клавиши
  String? _lastProcessedKey;
  DateTime? _lastKeyTime;
  
  void _handleKeyPress(LogicalKeyboardKey key) async {
    print('Settings: _handleKeyPress called');
    print('  key: ${key.debugName}');
    print('  _isListening: $_isListening');
    print('  _listeningFor: $_listeningFor');
    
    if (!_isListening || _listeningFor == null) {
      print('  ERROR: Not listening or no key specified');
      return;
    }

    // Получаем состояние модификаторов
    bool ctrlPressed = HardwareKeyboard.instance.isControlPressed;
    bool altPressed = HardwareKeyboard.instance.isAltPressed;
    bool shiftPressed = HardwareKeyboard.instance.isShiftPressed;
    
    print('  modifiers: ctrl=$ctrlPressed, alt=$altPressed, shift=$shiftPressed');
    
    // Проверяем, является ли нажатая клавиша модификатором
    bool isModifierKey = key == LogicalKeyboardKey.controlLeft ||
                        key == LogicalKeyboardKey.controlRight ||
                        key == LogicalKeyboardKey.altLeft ||
                        key == LogicalKeyboardKey.altRight ||
                        key == LogicalKeyboardKey.shiftLeft ||
                        key == LogicalKeyboardKey.shiftRight;
    
    // Если нажата только клавиша-модификатор, не сохраняем комбинацию
    if (isModifierKey) {
      print('  INFO: Modifier key pressed, ignoring');
      return;
    }
    
    // Создаем уникальный ключ для комбинации
    String keyCombination = '${ctrlPressed ? 'ctrl+' : ''}${altPressed ? 'alt+' : ''}${shiftPressed ? 'shift+' : ''}${key.debugName}';
    
    print('  keyCombination: $keyCombination');
    
    // Предотвращаем повторную обработку одной и той же клавиши в течение короткого времени
    DateTime now = DateTime.now();
    if (_lastProcessedKey == keyCombination && 
        _lastKeyTime != null && 
        now.difference(_lastKeyTime!).inMilliseconds < 50) {
      print('  INFO: Key ignored: duplicate within 50ms');
      return;
    }
    
    _lastProcessedKey = keyCombination;
    _lastKeyTime = now;
    
    // Безопасное получение строки клавиши
    String keyString;
    try {
      keyString = KeyboardUtils.normalizeKey(key);
      print('  normalized keyString: $keyString');
    } catch (e) {
      print('  ERROR: Failed to normalize key: $e');
      return;
    }
    
    // Если клавиша пустая или это только модификаторы без основной клавиши, игнорируем
    if (keyString.isEmpty || 
        keyString.contains('Control') || 
        keyString.contains('Alt') || 
        keyString.contains('Shift') ||
        keyString.contains('Meta') ||
        keyString.contains('Windows')) {
      print('  INFO: Empty or modifier-only key, ignoring');
      return;
    }
    
    // Создаем комбинацию клавиш
    KeyCombination combination = KeyCombination(
      ctrl: ctrlPressed,
      alt: altPressed,
      shift: shiftPressed,
      key: keyString,
    );
    
    print('  created combination: ${combination.toJson()}');
    
    // Оптимизированное обновление настроек без пересоздания всего объекта
    print('  updating hotkey setting for: $_listeningFor');
    if (_listeningFor != null) {
      _updateHotkeySetting(_listeningFor!, combination);
    }

    if (mounted) {
      setState(() {
        // Настройки обновлены
      });
    }
    _stopListening();
    
    // Автоматически сохраняем настройки
    await _saveSettings();
    
    // Показываем уведомление об установке клавиши
    if (mounted) {
      bool isDuplicate = false;
      if (_listeningFor != null) {
        isDuplicate = _isDuplicateKey(combination, _listeningFor!);
      }
      print('  isDuplicate: $isDuplicate');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isDuplicate 
              ? 'ВНИМАНИЕ: Клавиша $keyString уже используется!'
              : 'Клавиша для ${_listeningFor != null ? _toolNames[_listeningFor] ?? 'неизвестный инструмент' : 'неизвестный инструмент'} установлена: ${combination.displayString}'
          ),
          duration: const Duration(milliseconds: 2000),
          backgroundColor: isDuplicate ? Colors.red : Colors.green,
        ),
      );
    }
    
    print('Settings: _handleKeyPress completed');
  }


  Widget _buildHotkeyRow(String key, String toolName, KeyCombination currentKey) {
    bool isDuplicate = _isDuplicateKey(currentKey, key);
    bool isListening = _isListening && _listeningFor == key;
    
    return Container(
      height: 48,
      margin: const EdgeInsets.symmetric(vertical: 1),
      decoration: BoxDecoration(
        color: isListening 
            ? const Color(0xFF1A1A2E)
            : isDuplicate 
                ? const Color(0xFF2D1B1B)
                : Colors.transparent,
        border: Border(
          left: BorderSide(
            color: isListening 
                ? const Color(0xFF4A90E2)
                : isDuplicate 
                    ? const Color(0xFFE74C3C)
                    : const Color(0xFF2C2C2C),
            width: 3,
          ),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isListening ? null : () => _startListening(key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    toolName,
                    style: TextStyle(
                      color: isDuplicate ? const Color(0xFFE74C3C) : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDuplicate 
                        ? const Color(0xFFE74C3C).withOpacity(0.2)
                        : const Color(0xFF2C2C2C),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                      color: isDuplicate 
                          ? const Color(0xFFE74C3C)
                          : const Color(0xFF404040),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    currentKey.displayString,
                    style: TextStyle(
                      color: isDuplicate 
                          ? const Color(0xFFE74C3C)
                          : const Color(0xFFB0B0B0),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isListening 
                        ? const Color(0xFF4A90E2)
                        : const Color(0xFF404040),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isListening ? Icons.keyboard : Icons.edit,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text(
          'Горячие клавиши',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.5,
          ),
        ),
        backgroundColor: const Color(0xFF0F0F0F),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: RawKeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        onKey: (RawKeyEvent event) {
          if (event is RawKeyDownEvent && _isListening) {
            print('Settings: Key pressed: ${event.logicalKey.debugName}');
            _handleKeyPress(event.logicalKey);
          }
        },
        child: Column(
          children: [
            // Минималистичный индикатор прослушивания
            if (_isListening)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: const BoxDecoration(
                  color: Color(0xFF1A1A2E),
                  border: Border(
                    bottom: BorderSide(color: Color(0xFF4A90E2), width: 1),
                  ),
                ),
                child: Text(
                  'Нажмите клавишу для ${_listeningFor != null ? _toolNames[_listeningFor] ?? 'неизвестный инструмент' : 'неизвестный инструмент'}...',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF4A90E2),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            
            // Список горячих клавиш
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    // Раздел горячих клавиш
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF2C2C2C), width: 1),
                      ),
                      child: Column(
                        children: [
                          _buildHotkeyRow('panKey', _toolNames['panKey'] ?? 'Панорамирование', _panKey),
                          _buildHotkeyRow('rulerKey', _toolNames['rulerKey'] ?? 'Линейка', _rulerKey),
                          _buildHotkeyRow('angleKey', _toolNames['angleKey'] ?? 'Угол', _angleKey),
                          _buildHotkeyRow('magnifierKey', _toolNames['magnifierKey'] ?? 'Лупа', _magnifierKey),
                          _buildHotkeyRow('brightnessKey', _toolNames['brightnessKey'] ?? 'Яркость', _brightnessKey),
                          _buildHotkeyRow('invertKey', _toolNames['invertKey'] ?? 'Инверсия', _invertKey),
                          _buildHotkeyRow('rotateKey', _toolNames['rotateKey'] ?? 'Поворот', _rotateKey),
                          _buildHotkeyRow('annotationKey', _toolNames['annotationKey'] ?? 'Аннотации', _annotationKey),
                          _buildHotkeyRow('undoKey', _toolNames['undoKey'] ?? 'Отмена', _undoKey),
                        ],
                      ),
                    ),
                    // Раздел калибровки линейки
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF2C2C2C), width: 1),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Калибровка линейки',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _calibrationController,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    labelText: 'PixelSpacing (мм/пиксель)',
                                    labelStyle: const TextStyle(color: Color(0xFFB0B0B0)),
                                    hintText: 'Например: 0.1',
                                    hintStyle: const TextStyle(color: Color(0xFF606060)),
                                    filled: true,
                                    fillColor: const Color(0xFF2C2C2C),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(4),
                                      borderSide: const BorderSide(color: Color(0xFF404040)),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(4),
                                      borderSide: const BorderSide(color: Color(0xFF404040)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(4),
                                      borderSide: const BorderSide(color: Color(0xFF4A90E2)),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: _saveCalibrationFromInput,
                                icon: const Icon(Icons.check),
                                color: Colors.green,
                                tooltip: 'Сохранить значение',
                                style: IconButton.styleFrom(
                                  backgroundColor: const Color(0xFF2C2C2C),
                                  padding: const EdgeInsets.all(12),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _startCalibration,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF4A90E2),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                child: const Text('Откалибровать'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Текущее значение: ${_currentPixelSpacing.toStringAsFixed(3)} мм/пиксель',
                            style: const TextStyle(
                              color: Color(0xFFB0B0B0),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
