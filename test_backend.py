import requests
import json

def test_backend():
    """Тестирует доступность backend сервера."""
    try:
        # Проверяем health check
        response = requests.get('http://127.0.0.1:8000/', timeout=5)
        print(f"Health check: {response.status_code}")
        print(f"Response: {response.json()}")
        
        # Проверяем, что сервер отвечает на process_dicom endpoint
        response = requests.post('http://127.0.0.1:8000/process_dicom/', timeout=5)
        print(f"Process DICOM endpoint: {response.status_code}")
        
        return True
    except Exception as e:
        print(f"Backend недоступен: {e}")
        return False

if __name__ == "__main__":
    test_backend()

