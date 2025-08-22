#!/bin/bash

echo "Building and starting the Python Model Trainer container..."

docker-compose -f docker/model_training/docker-compose.yml up --build

echo "Model training complete."

echo "========================="
echo "========================="
echo "========================="
echo ""
echo ""
echo ""

echo "Cleaning up containers..."
docker-compose -f docker/model_training/docker-compose.yml down

echo "All cleaned up!"
sleep 10