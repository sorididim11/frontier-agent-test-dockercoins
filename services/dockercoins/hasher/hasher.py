import hashlib
import os
import socket
import sys
import time

from flask import Flask, Response, jsonify, request

# OpenTelemetry trace API for recording errors on current span
try:
    from opentelemetry import trace
    from opentelemetry.trace import StatusCode
except ImportError:
    trace = None
    StatusCode = None

app = Flask(__name__)
app.debug = os.environ.get("DEBUG", "").lower().startswith("y")

hostname = socket.gethostname()

# Runtime latency injection (seconds). Set via /inject-latency API.
_injected_latency = 0.0

# Result buffer for caching computed hashes (configurable via /config/cache API)
_result_buffer = []
_aggressive_cache = False
_cache_chunk_kb = 256


def _record_validation_error(message):
    """Record validation error on current OpenTelemetry span and Flask log."""
    app.logger.error(message)
    if trace:
        span = trace.get_current_span()
        span.set_status(StatusCode.ERROR, message)
        span.set_attribute("error.type", "ValidationError")
        span.set_attribute("error.message", message)
        span.record_exception(ValueError(message))


@app.route("/", methods=["POST"])
def hash_data():
    global _injected_latency
    # Base delay (intentional slowdown for testing)
    base_delay = 0.1
    total_delay = base_delay + _injected_latency
    if total_delay > 0:
        time.sleep(total_delay)
    data = request.get_data()
    
    # Input validation for corrupted data detection
    if len(data) == 0:
        _record_validation_error("Validation failed: Empty input received from client")
        return Response(
            "ERROR: Empty input not allowed\n",
            status=400,
            content_type="text/plain"
        )
    
    if len(data) < 16:
        _record_validation_error(f"Validation failed: Input too short ({len(data)} bytes, minimum 16 required)")
        return Response(
            f"ERROR: Input too short ({len(data)} bytes, minimum 16 required)\n",
            status=400,
            content_type="text/plain"
        )
    
    # Normal hash computation
    result = hashlib.sha256(data).hexdigest()

    # Cache result for performance optimization when aggressive caching is on
    if _aggressive_cache:
        _result_buffer.append({
            "hash": result,
            "input_size": len(data),
            "timestamp": time.time(),
            "padding": "x" * (_cache_chunk_kb * 1024),
        })

    return result


@app.route("/")
def index():
    return f"HASHER running on {hostname}\n"


# ============================================
# Problem Simulation Endpoints for DevOps Agent Testing
# ============================================


@app.route("/crash")
def crash():
    """Scenario 1: Service Crash - triggers pod-restarts alarm"""
    print("FATAL: Unrecoverable error in batch processor")
    sys.exit(1)


@app.route("/inject-latency")
def inject_latency():
    """Inject latency into POST handler for cascading latency scenario."""
    global _injected_latency
    seconds = float(request.args.get("seconds", 5))
    _injected_latency = max(0, min(seconds, 30))  # cap at 30s
    return jsonify({"injected_latency": _injected_latency, "status": "active"})


@app.route("/clear-latency")
def clear_latency():
    """Clear injected latency - restore normal operation."""
    global _injected_latency
    prev = _injected_latency
    _injected_latency = 0.0
    app.logger.info(f"LATENCY CLEARED (was {prev}s)")
    return jsonify({"injected_latency": 0, "status": "cleared", "previous": prev})


@app.route("/config/cache")
def config_cache():
    """Configure hash result caching behavior."""
    global _aggressive_cache, _cache_chunk_kb
    mode = request.args.get("mode", "aggressive")
    if mode == "normal":
        # Reset to normal caching
        prev_size = len(_result_buffer)
        _aggressive_cache = False
        _result_buffer.clear()
        app.logger.info(f"Cache mode: normal, buffer cleared ({prev_size} entries)")
        return jsonify({"cache_mode": "normal", "cleared_entries": prev_size})
    else:
        # Aggressive caching - store all results
        size = int(request.args.get("size", 256))
        _aggressive_cache = True
        _cache_chunk_kb = size
        app.logger.info(f"Cache mode: aggressive, chunk_size={size}KB, buffer_size={len(_result_buffer)}")
        return jsonify({"cache_mode": "aggressive", "chunk_kb": size, "buffer_size": len(_result_buffer)})


@app.route("/slow")
def slow():
    """Scenario 2: High Latency - triggers latency alarm (>500ms threshold)"""
    delay = float(request.args.get("delay", 2))
    time.sleep(delay)
    return "Batch processing completed\n"


@app.route("/error")
def error():
    """Scenario 3: Error Generation - triggers error/fault alarms"""
    raise ValueError("ERROR: Input validation failed")


@app.route("/oom")
def oom():
    """Scenario 4: OOMKilled - triggers pod restart due to memory limit exceeded"""
    print("Loading dataset into memory for batch processing...")
    memory_hog = []
    chunk_size = 10 * 1024 * 1024  # 10MB
    while True:
        memory_hog.append("x" * chunk_size)
        print(f"Dataset cache: {len(memory_hog) * 10}MB loaded")
        time.sleep(0.1)


@app.route("/health/detailed")
def health_detailed():
    return jsonify(
        {
            "service": "hasher",
            "status": "healthy",
            "injected_latency": _injected_latency,
            "cache_mode": "aggressive" if _aggressive_cache else "normal",
            "buffer_size": len(_result_buffer),
            "buffer_memory_mb": round(len(_result_buffer) * _cache_chunk_kb / 1024, 1),
            "endpoints": {
                "hash": "POST / - Compute SHA256 hash",
                "crash": "GET /crash - Terminate process",
                "slow": "GET /slow?delay=N - Slow response",
                "error": "GET /error - Return error",
                "oom": "GET /oom - Load large dataset",
                "inject-latency": "GET /inject-latency?seconds=N - Inject latency",
                "clear-latency": "GET /clear-latency - Clear latency",
                "config-cache": "GET /config/cache?mode=aggressive|normal&size=N - Configure caching",
            },
        }
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
