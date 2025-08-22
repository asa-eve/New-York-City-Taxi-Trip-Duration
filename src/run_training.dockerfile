# Use official Python image
FROM python:3.10-bookworm

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /src

# Copy your training script and data
COPY . .

# Install dependencies
RUN pip install --no-cache-dir \
    numpy \
    pandas \
    IPython \
    scikit-learn \
    xgboost \
    lightgbm

# Run the training script
CMD ["python", "train_model.py"]
