from fastapi import FastAPI, UploadFile, File
from fastapi.responses import JSONResponse
import pydicom
import numpy as np
import io
from PIL import Image
import base64
from pydicom.pixel_data_handlers.util import apply_voi_lut

app = FastAPI()

@app.post("/process_dicom/")
async def process_dicom_file(file: UploadFile = File(...)):
    try:
        contents = await file.read()
        dicom_file = pydicom.dcmread(io.BytesIO(contents))
        
        # 1. Применяем VOI LUT или Window/Level из файла
        pixels = apply_voi_lut(dicom_file.pixel_array, dicom_file)

        # 2. Проверяем, нужно ли инвертировать изображение
        if dicom_file.PhotometricInterpretation == "MONOCHROME1":
            pixels = np.amax(pixels) - pixels
        
        # 3. Нормализуем пиксели в 8-битный диапазон (0-255)
        pixels = pixels - np.min(pixels)
        pixels = pixels / np.max(pixels)
        pixels = (pixels * 255).astype(np.uint8)

        # 4. Создаем изображение с помощью Pillow
        image = Image.fromarray(pixels)
        
        # 5. Сохраняем изображение в буфер памяти в формате PNG
        img_buffer = io.BytesIO()
        image.save(img_buffer, format="PNG")
        
        # 6. Кодируем байты PNG в текстовую строку Base64
        img_base64 = base64.b64encode(img_buffer.getvalue()).decode('utf-8')

        # 7. Отправляем простой JSON с готовой картинкой
        return {
            "patient_name": str(getattr(dicom_file, 'PatientName', 'N/A')),
            "image_base64": img_base64
        }

    except Exception as e:
        print(f"PYTHON ERROR: {e}")
        return JSONResponse(status_code=500, content={"message": f"An error occurred in Python: {str(e)}"})