from flask import Flask, jsonify
import os

# This small Flask service provides health and example endpoints for the AKS validation.
app = Flask(__name__)

@app.get("/healthz")
def healthz():
    # Kubernetes readiness and liveness probes call this endpoint.
    return jsonify({"status": "ok", "service": "orders-api"})

@app.get("/")
def root():
    # APP_ENV is injected by the Kubernetes deployment manifest.
    return jsonify({"service": "orders-api", "environment": os.getenv("APP_ENV", "unknown")})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
