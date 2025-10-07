import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'dart:convert';

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

  Future<void> _openAndProcessFile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _imageBytes = null;
      _patientName = null;
    });

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      if (result != null && result.files.single.bytes != null) {
        var request = http.MultipartRequest('POST', Uri.parse('http://127.0.0.1:8000/process_dicom/'));
        request.files.add(http.MultipartFile.fromBytes('file', result.files.single.bytes!, filename: result.files.single.name));
        
        var streamedResponse = await request.send();
        
        if (streamedResponse.statusCode == 200) {
          final responseBody = await streamedResponse.stream.bytesToString();
          final data = jsonDecode(responseBody);
          setState(() {
            _imageBytes = base64Decode(data['image_base64']);
            _patientName = data['patient_name'];
            _isLoading = false;
          });
        } else {
          final errorBody = await streamedResponse.stream.bytesToString();
          setState(() {
            _errorMessage = 'Ошибка сервера: ${streamedResponse.statusCode}\n$errorBody';
            _isLoading = false;
          });
        }
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Произошла ошибка во Flutter: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DICOM Viewer')),
      backgroundColor: Colors.black,
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator()
            : _errorMessage.isNotEmpty
                ? Padding(padding: const EdgeInsets.all(16.0), child: Text(_errorMessage, style: const TextStyle(color: Colors.red, fontSize: 16)))
                : _imageBytes != null
                    ? Column(
                        children: [
                          if (_patientName != null)
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Text("Пациент: $_patientName", style: const TextStyle(color: Colors.white, fontSize: 16)),
                            ),
                          Expanded(
                            child: InteractiveViewer( // Зум и панорамирование оставляем, они работают
                              panEnabled: true,
                              minScale: 0.5,
                              maxScale: 4.0,
                              child: Image.memory(_imageBytes!),
                            ),
                          ),
                        ],
                      )
                    : ElevatedButton.icon(
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Открыть DICOM файл'),
                        onPressed: _openAndProcessFile,
                      ),
      ),
    );
  }
}