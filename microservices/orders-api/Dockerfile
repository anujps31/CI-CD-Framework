FROM python:3.12-slim

# Use a small runtime image and run the application as a non-root user.
# Keep the container quiet and deterministic for CI and Kubernetes logs.
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
USER 10001
EXPOSE 8080
# Kubernetes calls /healthz for readiness and liveness checks.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
