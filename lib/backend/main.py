from fastapi import FastAPI, UploadFile, File, Form
from typing import Optional
from fastapi.responses import JSONResponse
from pydantic import BaseModel
import pydicom
import json
import numpy as np
import io
from PIL import Image, ImageDraw, ImageFont
from pydicom.uid import ExplicitVRLittleEndian
import base64
from pydicom.pixel_data_handlers.util import apply_voi_lut
from pydicom.datadict import tag_for_keyword, dictionary_VR

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

@app.post("/export_dicom/")
async def export_dicom(
    file: UploadFile = File(...),
    metadata: Optional[str] = Form(None),
    annotations: Optional[str] = Form(None),
    render: Optional[UploadFile] = File(None),  # PNG с уже «сожжёнными» аннотациями с клиента
):
    """Принимает исходный DICOM и опциональные metadata (tags/report), возвращает изменённый DICOM base64."""
    try:
        contents = await file.read()
        ds = pydicom.dcmread(io.BytesIO(contents), force=True)

        meta = {}
        if metadata:
            try:
                meta = json.loads(metadata)
            except Exception:
                meta = {}

        # Применяем текст отчёта, если есть
        report = meta.get('report') if isinstance(meta, dict) else None
        if report is not None:
            try:
                ds.ImageComments = str(report)
            except Exception:
                pass

        # Применяем теги по словарю {keyword: value}
        # Безопасность: не изменяем структурные пиксельные поля
        forbidden_keywords = {
            'Rows', 'Columns', 'BitsAllocated', 'BitsStored', 'HighBit',
            'SamplesPerPixel', 'PhotometricInterpretation', 'PixelRepresentation',
            'NumberOfFrames', 'PixelData'
        }

        def coerce_value_to_vr(v, vr):
            # Разбираем множественные значения: "a\\b" или "a,b"
            def split_multi(x):
                if isinstance(x, str):
                    if '\\' in x:
                        return [i for i in x.split('\\') if i != '']
                    if ',' in x:
                        return [i for i in x.split(',') if i != '']
                return x

            v = split_multi(v)
            def convert_one(x):
                if vr in ('US', 'UL', 'SS', 'SL'):  # целые
                    return int(x)
                if vr in ('FL', 'FD'):  # float
                    return float(x)
                if vr == 'IS':  # Integer String
                    return str(int(x))
                if vr == 'DS':  # Decimal String
                    return str(float(x))
                # Остальные VR — оставляем как есть (строки и т.п.)
                return x

            if isinstance(v, (list, tuple)):
                return [convert_one(x) for x in v]
            return convert_one(v)

        tags = meta.get('tags', {}) if isinstance(meta, dict) else {}
        if isinstance(tags, dict):
            for key, value in tags.items():
                if key in forbidden_keywords:
                    continue
                try:
                    tag = tag_for_keyword(key)
                    if tag is None:
                        continue
                    vr = dictionary_VR(tag) or ''
                    safe_value = coerce_value_to_vr(value, vr)
                    setattr(ds, key, safe_value)
                except Exception:
                    # Игнорируем неподдерживаемые/некорректные ключи или значения
                    pass

        # Ветка 1: если клиент прислал готовый рендер (PNG) — используем его БЕЗ доп. конвертаций
        if render is not None:
            try:
                png_bytes = await render.read()
                img = Image.open(io.BytesIO(png_bytes)).convert('RGB')
                arr = np.array(img, dtype=np.uint8)
                # Записываем RGB 8-bit как PixelData, чтобы картинка совпадала 1:1
                ds.Rows = int(arr.shape[0])
                ds.Columns = int(arr.shape[1])
                ds.PhotometricInterpretation = 'RGB'
                ds.SamplesPerPixel = 3
                ds.PlanarConfiguration = 0
                ds.BitsAllocated = 8
                ds.BitsStored = 8
                ds.HighBit = 7
                ds.PixelRepresentation = 0
                # Чистим потенциальные конфликтующие поля
                for k in [
                    'PaletteColorLookupTableUID', 'RedPaletteColorLookupTableData',
                    'GreenPaletteColorLookupTableData', 'BluePaletteColorLookupTableData',
                    'SmallestImagePixelValue', 'LargestImagePixelValue',
                    'VOILUTSequence', 'ModalityLUTSequence',
                ]:
                    if hasattr(ds, k):
                        try:
                            delattr(ds, k)
                        except Exception:
                            pass
                # Meta + флаги
                try:
                    if not hasattr(ds, 'file_meta') or ds.file_meta is None:
                        from pydicom.dataset import Dataset
                        ds.file_meta = Dataset()
                    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
                except Exception:
                    pass
                ds.is_little_endian = True
                ds.is_implicit_VR = False
                ds.PixelData = arr.tobytes()
            except Exception as e:
                return JSONResponse(status_code=500, content={"message": f"Failed to use client render: {str(e)}"})

        # Ветка 2: если рендера нет — пробуем сжечь аннотации на сервере (как раньше)
        elif annotations:
            try:
                ann = json.loads(annotations)
            except Exception:
                ann = None
            if isinstance(ann, dict):
                try:
                    src_pixels = ds.pixel_array
                    photometric = getattr(ds, 'PhotometricInterpretation', 'MONOCHROME2')
                    height, width = (src_pixels.shape[0], src_pixels.shape[1]) if src_pixels.ndim >= 2 else (ds.Rows, ds.Columns)
                    # Создаем базовое изображение только для вычисления координат/отрисовки маски
                    if photometric.upper() == 'RGB' and src_pixels.ndim == 3 and src_pixels.dtype == np.uint8:
                        img = Image.fromarray(src_pixels, mode='RGB')
                    else:
                        img = Image.new('L', (width, height), 0)

                    draw = ImageDraw.Draw(img)
                    # Функция поворота точки вокруг центра изображения на угол, как в UI (по часовой стрелке)
                    try:
                        rotation_deg = float(ann.get('rotation_deg', 0.0))
                    except Exception:
                        rotation_deg = 0.0
                    import math
                    if abs(rotation_deg) % 360 != 0:
                        cx, cy = img.width / 2.0, img.height / 2.0
                        # Преобразуем экранные координаты (после поворота по часовой) обратно в координаты исходного изображения
                        # => вращаем точки на противоположный угол (CCW)
                        theta = math.radians(rotation_deg)
                        cos_t, sin_t = math.cos(theta), math.sin(theta)
                        def rot(x, y):
                            dx, dy = x - cx, y - cy
                            rx = cos_t * dx - sin_t * dy + cx
                            ry = sin_t * dx + cos_t * dy + cy
                            return rx, ry
                    else:
                        def rot(x, y):
                            return x, y
                    try:
                        font = ImageFont.load_default()
                    except Exception:
                        font = None

                    def parse_color(c, fallback=(255, 255, 0)):
                        if isinstance(c, str):
                            # Expect formats like #RRGGBB
                            c = c.strip()
                            if c.startswith('#') and len(c) == 7:
                                r = int(c[1:3], 16)
                                g = int(c[3:5], 16)
                                b = int(c[5:7], 16)
                                return (r, g, b)
                        return fallback

                    # Тексты
                    for t in ann.get('texts', []) or []:
                        try:
                            x = float(t.get('x', 0)); y = float(t.get('y', 0))
                            x, y = rot(x, y)
                            text = str(t.get('text', ''))
                            color = parse_color(t.get('color'))
                            # Фон
                            if photometric.upper() == 'RGB':
                                bg = (0, 0, 0)
                            else:
                                color = 255
                                bg = 0
                            if font:
                                w, h = draw.textsize(text, font=font)
                            else:
                                w, h = draw.textsize(text)
                            draw.rectangle([x - 5, y - 2, x - 5 + w + 10, y - 2 + h + 4], fill=bg)
                            draw.text((x, y), text, fill=color, font=font)
                        except Exception:
                            pass

                    # Стрелки
                    for a in ann.get('arrows', []) or []:
                        try:
                            x1 = float(a.get('x1', 0)); y1 = float(a.get('y1', 0))
                            x2 = float(a.get('x2', 0)); y2 = float(a.get('y2', 0))
                            x1, y1 = rot(x1, y1)
                            x2, y2 = rot(x2, y2)
                            width = float(a.get('strokeWidth', 3))
                            color = parse_color(a.get('color')) if photometric.upper() == 'RGB' else 255
                            draw.line([(x1, y1), (x2, y2)], fill=color, width=int(max(1, round(width))))
                            # наконечник стрелки
                            import math
                            dx = x2 - x1; dy = y2 - y1
                            length = math.hypot(dx, dy) or 1.0
                            ux, uy = dx / length, dy / length
                            arrow_len = 15.0
                            angle = 0.5
                            px1 = x2 - arrow_len * (ux * math.cos(angle) + uy * math.sin(angle))
                            py1 = y2 - arrow_len * (uy * math.cos(angle) - ux * math.sin(angle))
                            px2 = x2 - arrow_len * (ux * math.cos(-angle) + uy * math.sin(-angle))
                            py2 = y2 - arrow_len * (uy * math.cos(-angle) - ux * math.sin(-angle))
                            draw.line([(x2, y2), (px1, py1)], fill=color, width=int(max(1, round(width))))
                            draw.line([(x2, y2), (px2, py2)], fill=color, width=int(max(1, round(width))))
                        except Exception:
                            pass

                    # Линейки
                    for r in ann.get('rulers', []) or []:
                        try:
                            x1 = float(r.get('x1', 0)); y1 = float(r.get('y1', 0))
                            x2 = float(r.get('x2', 0)); y2 = float(r.get('y2', 0))
                            x1, y1 = rot(x1, y1)
                            x2, y2 = rot(x2, y2)
                            label = str(r.get('label', ''))
                            color = (255, 255, 0) if photometric.upper() == 'RGB' else 255
                            draw.line([(x1, y1), (x2, y2)], fill=color, width=3)
                            # перпендикуляры на концах
                            import math
                            dx = x2 - x1; dy = y2 - y1
                            length = math.hypot(dx, dy) or 1.0
                            px = -dy / length * 10; py = dx / length * 10
                            draw.line([(x1 - px, y1 - py), (x1 + px, y1 + py)], fill=color, width=2)
                            draw.line([(x2 - px, y2 - py), (x2 + px, y2 + py)], fill=color, width=2)
                            # подпись
                            if label:
                                mx = (x1 + x2) / 2 + 15
                                my = (y1 + y2) / 2
                                if photometric.upper() == 'RGB':
                                    text_color = (255, 255, 0); bg = (0, 0, 0)
                                else:
                                    text_color = 255; bg = 0
                                if font:
                                    w, h = draw.textsize(label, font=font)
                                else:
                                    w, h = draw.textsize(label)
                                draw.rectangle([mx - 5, my - h / 2 - 2, mx - 5 + w + 10, my - h / 2 + h + 4], fill=bg)
                                draw.text((mx, my - h / 2), label, fill=text_color, font=font)
                        except Exception:
                            pass

                    # Сжигаем аннотации непосредственно в исходные пиксели БЕЗ изменения размеров/битности
                    try:
                        if photometric.upper() == 'RGB' and src_pixels.ndim == 3 and src_pixels.dtype == np.uint8:
                            base = Image.fromarray(src_pixels, 'RGB')
                            overlay = img if img.mode == 'RGB' else img.convert('RGB')
                            # Используем режим lighter для яркого burn-in
                            base_np = np.array(base)
                            over_np = np.array(overlay)
                            base_np = np.maximum(base_np, over_np)
                            ds.PixelData = base_np.tobytes()
                        else:
                            # Монохромный случай: рисуем маску и ставим пиксели в максимальное (или минимальное для MONOCHROME1) значение
                            mask = img if img.mode == 'L' else img.convert('L')
                            mask_np = np.array(mask, dtype=np.uint8)
                            arr = np.array(src_pixels)  # сохранить dtype
                            if np.issubdtype(arr.dtype, np.integer):
                                info = np.iinfo(arr.dtype)
                                maxv = info.max
                                minv = info.min
                            else:
                                maxv, minv = 255, 0
                            target = maxv if photometric.upper() != 'MONOCHROME1' else minv
                            arr[mask_np > 0] = target
                            ds.PixelData = arr.tobytes()
                    except Exception:
                        pass
                except Exception:
                    # Не фейлим экспорт, просто пропускаем аннотации
                    pass

        out_buf = io.BytesIO()
        ds.save_as(out_buf, write_like_original=False)
        out_bytes = out_buf.getvalue()
        return {
            'dicom_base64': base64.b64encode(out_bytes).decode('utf-8'),
            'size': len(out_bytes)
        }
    except Exception as e:
        return JSONResponse(status_code=500, content={"message": str(e)})

if __name__ == "__main__":
    import uvicorn
    print("Запуск сервера на http://127.0.0.1:8000")
    uvicorn.run(app, host="127.0.0.1", port=8000)