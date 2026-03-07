FROM nvidia/cuda:12.8.0-cudnn-runtime-ubuntu22.04

# Set working directory
WORKDIR /app

# Install system dependencies + Python
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    gcc \
    g++ \
    make \
    ffmpeg \
    libsm6 \
    libxext6 \
    libxrender-dev \
    wget \
    && ln -sf python3 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .

# Install PyTorch with CUDA 12.8 support first, then remaining dependencies
RUN pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
RUN grep -vE '^torch(vision|audio)?$' requirements.txt | pip install --no-cache-dir -r /dev/stdin && \
    pip install --no-cache-dir requests

# Copy the application code
COPY . .

# Create necessary directories
RUN mkdir -p /app/comfyui/models /app/comfyui/web /app/comfyui/temp /app/comfyui/extra_model_paths /app/custom_nodes

# Set up environment
ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app

# Expose ports
EXPOSE 8188

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8188/system_stats')"

# Run the application
CMD ["python", "main.py", "--listen", "0.0.0.0"]