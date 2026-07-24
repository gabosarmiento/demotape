# Minimal reference TTS shim for DemoTape. Runs on Intel + Apple Silicon (CPU only).
FROM python:3.12-slim

# espeak-ng = the out-of-the-box (robotic) voice; ffmpeg = WAV->MP3. Swap synth_wav() for a real model.
RUN apt-get update && apt-get install -y --no-install-recommends \
        espeak-ng ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
