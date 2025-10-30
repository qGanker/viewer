from fastapi import FastAPI, UploadFile, File
from fastapi.responses import JSONResponse
from pydantic import BaseModel
import pydicom
import numpy as np
import io
from PIL import Image
import base64
from pydicom.pixel_data_handlers.util import apply_voi_lut

app = FastAPI()

# --- Кэш для хранения сырых данных последнего файла ---
dicom_cache = {}

@app.get("/")
async def health_check():
    """Простая проверка доступности сервера."""
    return {"status": "ok", "message": "DICOM Viewer Backend is running"}

# --- Модель для получения данных от Flutter ---
class WindowLevelRequest(BaseModel):
    window_center: float
    window_width: float
    brightness: float = 1.0
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
    tags['Rows'] = _safe_str(getattr(ds, 'Rows', ''))
    tags['Columns'] = _safe_str(getattr(ds, 'Columns', ''))
    ps = getattr(ds, 'PixelSpacing', None)
    if ps is not None:
        try:
            tags['PixelSpacing'] = f"{float(ps[0])} \\ {float(ps[1])}"
        except Exception:
            tags['PixelSpacing'] = _safe_str(ps)
    for name in ['SliceThickness', 'KVP', 'ExposureTime', 'XRayTubeCurrent', 'Exposure']:
        if hasattr(ds, name):
            tags[name] = _safe_str(getattr(ds, name))
    return tags

def extract_report(ds):
    # Пробуем ряд стандартных текстовых полей, где часто встречается заключение
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


def render_pixels_to_base64(pixels, photometric_interpretation):
    """Вспомогательная функция, которая рендерит 8-битную картинку."""
    if photometric_interpretation == "MONOCHROME1":
        pixels = np.amax(pixels) - pixels
    
    pixels_8bit = pixels - np.min(pixels)
    max_val = np.max(pixels_8bit)
    if max_val > 0:
        pixels_8bit = pixels_8bit / max_val
    
    pixels_8bit = (pixels_8bit * 255).astype(np.uint8)

    image = Image.fromarray(pixels_8bit)
    img_buffer = io.BytesIO()
    image.save(img_buffer, format="PNG")
    return base64.b64encode(img_buffer.getvalue()).decode('utf-8')

@app.post("/process_dicom/")
async def process_dicom_file(file: UploadFile = File(...)):
    """Первоначальная загрузка файла."""
    try:
        print(f"Получен файл: {file.filename}, размер: {file.size} байт")
        contents = await file.read()
        print(f"Файл прочитан, размер содержимого: {len(contents)} байт")
        
        # Проверяем размер файла
        if len(contents) > 100 * 1024 * 1024:  # 100MB
            return JSONResponse(status_code=400, content={"message": f"Файл слишком большой: {len(contents) / 1024 / 1024:.1f} MB. Максимальный размер: 100 MB"})
        
        # Пытаемся прочитать как DICOM файл
        try:
            print("Пытаемся прочитать файл как DICOM...")
            # Принудительно читаем как DICOM файл, игнорируя расширение
            dicom_file = pydicom.dcmread(io.BytesIO(contents), force=True)
            print(f"DICOM файл успешно прочитан. SOP Class: {getattr(dicom_file, 'SOPClassUID', 'Unknown')}")
            
            # Проверяем, что файл содержит пиксельные данные
            if not hasattr(dicom_file, 'pixel_array'):
                raise Exception("Файл не содержит пиксельных данных")
                
            print(f"Размер пиксельного массива: {dicom_file.pixel_array.shape}")
            
        except Exception as dicom_error:
            print(f"Ошибка при чтении DICOM файла: {dicom_error}")
            return JSONResponse(status_code=400, content={"message": f"Не удалось прочитать DICOM файл: {str(dicom_error)}"})
        
        print("Обрабатываем пиксельные данные...")
        
        # Применяем Rescale Slope/Intercept
        slope = float(getattr(dicom_file, 'RescaleSlope', 1.0))
        intercept = float(getattr(dicom_file, 'RescaleIntercept', 0.0))
        print(f"Rescale Slope: {slope}, Intercept: {intercept}")
        
        raw_pixels = dicom_file.pixel_array
        if slope != 1.0 or intercept != 0.0:
            print("Применяем Rescale Slope/Intercept...")
            raw_pixels = raw_pixels.astype(np.float64) * slope + intercept
            
        print(f"Обработанные пиксели: min={np.min(raw_pixels)}, max={np.max(raw_pixels)}")
            
        # Сохраняем СЫРЫЕ пиксели и метаданные в кэш
        dicom_cache['raw_pixels'] = raw_pixels
        dicom_cache['photometric_interpretation'] = dicom_file.PhotometricInterpretation
        dicom_cache['initial_wc'] = float(getattr(dicom_file, 'WindowCenter', 50))
        dicom_cache['initial_ww'] = float(getattr(dicom_file, 'WindowWidth', 400))
        
        print("Применяем VOI LUT...")
        # Применяем стандартный VOI LUT для первого отображения
        pixels_to_render = apply_voi_lut(dicom_file.pixel_array, dicom_file)
        
        print("Рендерим изображение...")
        img_base64 = render_pixels_to_base64(pixels_to_render, dicom_file.PhotometricInterpretation)
        
        pixel_spacing = getattr(dicom_file, 'PixelSpacing', [1.0, 1.0])
        
        print("Подготавливаем ответ...")
        tags = extract_basic_tags(dicom_file)
        report = extract_report(dicom_file)
        result = {
            "patient_name": str(getattr(dicom_file, 'PatientName', 'N/A')),
            "image_base64": img_base64,
            "window_center": float(getattr(dicom_file, 'WindowCenter', 50)),
            "window_width": float(getattr(dicom_file, 'WindowWidth', 400)),
            "pixel_spacing_row": float(pixel_spacing[0]),
            "pixel_spacing_col": float(pixel_spacing[1]),
            "tags": tags,
            "report": report,
        }
        
        print(f"Ответ подготовлен. Размер base64: {len(img_base64)} символов")
        return result
        
    except Exception as e:
        print(f"PYTHON ERROR on initial processing: {e}")
        print(f"Тип ошибки: {type(e).__name__}")
        import traceback
        print(f"Полная трассировка: {traceback.format_exc()}")
        return JSONResponse(status_code=500, content={"message": f"An error occurred: {str(e)}"})

@app.post("/update_wl/")
async def update_window_level(request: WindowLevelRequest):
    """Новый эндпоинт для перерисовки с новыми W/L и яркостью."""
    if 'raw_pixels' not in dicom_cache:
        return JSONResponse(status_code=404, content={"message": "No DICOM data in cache."})
    try:
        raw_pixels = dicom_cache['raw_pixels']
        wc, ww, brightness = request.window_center, request.window_width, request.brightness
        
        # Применяем Window/Level
        min_val, max_val = wc - ww / 2, wc + ww / 2
        pixels_clipped = np.clip(raw_pixels, min_val, max_val)
        
        # Нормализуем к 0-1 диапазону
        if max_val > min_val:
            pixels_normalized = (pixels_clipped - min_val) / (max_val - min_val)
        else:
            pixels_normalized = np.zeros_like(pixels_clipped)
        
        # Применяем яркость БЕЗОПАСНЫМ способом
        if brightness != 1.0:
            # Используем более мягкую корректировку яркости
            if brightness < 1.0:
                # Затемнение: применяем квадратный корень
                pixels_normalized = np.power(pixels_normalized, 1.0 / (2.0 - brightness))
            else:
                # Осветление: применяем квадрат
                pixels_normalized = np.power(pixels_normalized, 1.0 / brightness)
        
        pixels_normalized = np.clip(pixels_normalized, 0, 1)
        
        # Конвертируем в 8-битное изображение
        pixels_8bit = (pixels_normalized * 255).astype(np.uint8)
        
        # Применяем photometric interpretation
        if dicom_cache['photometric_interpretation'] == "MONOCHROME1":
            pixels_8bit = 255 - pixels_8bit
        
        image = Image.fromarray(pixels_8bit)
        img_buffer = io.BytesIO()
        image.save(img_buffer, format="PNG")
        img_base64 = base64.b64encode(img_buffer.getvalue()).decode('utf-8')
        
        return {"image_base64": img_base64}
    except Exception as e:
        print(f"PYTHON ERROR on W/L/Brightness update: {e}")
        return JSONResponse(status_code=500, content={"message": f"An error occurred: {str(e)}"})

@app.post("/update_brightness/")
async def update_brightness_only(brightness: float):
    """Простой эндпоинт только для яркости без W/L."""
    if 'raw_pixels' not in dicom_cache:
        return JSONResponse(status_code=404, content={"message": "No DICOM data in cache."})
    try:
        raw_pixels = dicom_cache['raw_pixels']
        
        # Используем начальные значения W/L
        wc = dicom_cache.get('initial_wc', 50)
        ww = dicom_cache.get('initial_ww', 400)
        
        # Применяем Window/Level
        min_val, max_val = wc - ww / 2, wc + ww / 2
        pixels_clipped = np.clip(raw_pixels, min_val, max_val)
        
        # Нормализуем к 0-1 диапазону
        if max_val > min_val:
            pixels_normalized = (pixels_clipped - min_val) / (max_val - min_val)
        else:
            pixels_normalized = np.zeros_like(pixels_clipped)
        
        # Применяем яркость очень осторожно
        if brightness != 1.0:
            pixels_normalized = np.power(pixels_normalized, 1.0 / brightness)
        
        pixels_normalized = np.clip(pixels_normalized, 0, 1)
        
        # Конвертируем в 8-битное изображение
        pixels_8bit = (pixels_normalized * 255).astype(np.uint8)
        
        # Применяем photometric interpretation
        if dicom_cache['photometric_interpretation'] == "MONOCHROME1":
            pixels_8bit = 255 - pixels_8bit
        
        image = Image.fromarray(pixels_8bit)
        img_buffer = io.BytesIO()
        image.save(img_buffer, format="PNG")
        img_base64 = base64.b64encode(img_buffer.getvalue()).decode('utf-8')
        
        return {"image_base64": img_base64}
    except Exception as e:
        print(f"PYTHON ERROR on brightness update: {e}")
        return JSONResponse(status_code=500, content={"message": f"An error occurred: {str(e)}"})

if __name__ == "__main__":
    import uvicorn
    print("Запуск сервера на http://127.0.0.1:8000")
    uvicorn.run(app, host="127.0.0.1", port=8000)