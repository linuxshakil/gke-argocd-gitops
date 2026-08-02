import os
from flask import Flask, jsonify

app = Flask(__name__)

ENVIRONMENT = os.environ.get("ENVIRONMENT", "unknown")
APP_VERSION = os.environ.get("APP_VERSION", "dev")


@app.route("/")
def index():
    return jsonify(
        message="Hello from Shakil's demo-app final!",
        environment=ENVIRONMENT,
        version=APP_VERSION,
    )


@app.route("/healthz")
def healthz():
    # Liveness/readiness probe target — keep this cheap and dependency-free
    return jsonify(status="ok"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
# trigger
# trigger
### trigger
