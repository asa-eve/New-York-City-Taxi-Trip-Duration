#!/bin/bash

echo "🧠 Starting Python Model Trainer container..."
docker-compose -p model_trainer -f docker/model_trainer/docker-compose.yml up -d

echo "⏳ Waiting for the container to be ready..."
until docker exec model_trainer_container_name python --version &> /dev/null; do
    sleep 2
    echo "Still waiting..."
done

echo "🚀 Running Python training script..."
docker exec model_trainer_container_name python /app/train_model.py

echo "✅ Model training complete."