from flask import Flask, Response, jsonify, request
import os
import random
import socket
import time
import sys
import threading

app = Flask(__name__)

# Enable debugging if the DEBUG environment variable is set and starts with Y
app.debug = os.environ.get("DEBUG", "").lower().startswith('y')

hostname = socket.gethostname()

urandom = os.open("/dev/urandom", os.O_RDONLY)

# Database configuration from environment
DB_HOST = os.environ.get("DB_HOST", "")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "devopsagentdb")
DB_USER = os.environ.get("DB_USER", "dbadmin")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")

# Connection pool (lazy initialization)
_connection_pool = None
# Leaked connections storage
_leaked_connections = []


def get_db_config():
    """Get database configuration"""
    return {
        "host": DB_HOST,
        "port": DB_PORT,
        "dbname": DB_NAME,
        "user": DB_USER,
        "password": DB_PASSWORD
    }


def get_connection_pool():
    """Get or create connection pool (proper way)"""
    global _connection_pool
    if _connection_pool is None:
        try:
            import psycopg2.pool
            _connection_pool = psycopg2.pool.ThreadedConnectionPool(
                minconn=2,
                maxconn=10,
                **get_db_config()
            )
            print("Database connection pool initialized")
        except Exception as e:
            print(f"Failed to initialize connection pool: {e}")
            return None
    return _connection_pool


@app.route("/")
def index():
    return "RNG running on {}\n".format(hostname)


# Runtime response quality control (API-based)
_response_quality_factor = 0.0


@app.route("/<int:how_many_bytes>")
def rng(how_many_bytes):
    global _response_quality_factor
    # Simulate a little bit of delay
    time.sleep(0.1)
    
    # Degraded response mode - returns reduced quality data
    if _response_quality_factor > 0 and random.random() < _response_quality_factor:
        # Returns empty data when quality is degraded
        print(f"RNG: Response quality degraded (factor={_response_quality_factor})")
        return Response(
            b'',
            content_type="application/octet-stream"
        )
    
    # Normal operation
    return Response(
        os.read(urandom, how_many_bytes),
        content_type="application/octet-stream")


# ============================================
# Database Connection Scenarios
# ============================================

@app.route("/db-pool")
def db_pool_test():
    """Proper database access using connection pool"""
    pool = get_connection_pool()
    if pool is None:
        return Response("ERROR: Database pool not available\n", status=503)
    
    conn = None
    try:
        conn = pool.getconn()
        cursor = conn.cursor()
        cursor.execute("SELECT 1 as test, NOW() as timestamp")
        result = cursor.fetchone()
        cursor.close()
        return jsonify({
            "status": "success",
            "method": "connection_pool",
            "result": {"test": result[0], "timestamp": str(result[1])},
            "pool_stats": {
                "min_connections": 2,
                "max_connections": 10
            }
        })
    except Exception as e:
        return Response(f"ERROR: Database query failed - {str(e)}\n", status=500)
    finally:
        if conn:
            pool.putconn(conn)  # Return connection to pool


@app.route("/db-leak")
def db_leak():
    """BAD: Opens connection without closing - causes connection leak"""
    count = int(request.args.get('count', 5))
    
    try:
        import psycopg2
        config = get_db_config()
        
        print(f"Opening {count} database connections WITHOUT closing...")
        
        for i in range(count):
            # BAD: Connection opened but never closed
            conn = psycopg2.connect(**config)
            _leaked_connections.append(conn)
            
            cursor = conn.cursor()
            cursor.execute("SELECT pg_backend_pid()")
            pid = cursor.fetchone()[0]
            print(f"Leaked connection {i+1}: backend PID {pid}")
            # cursor not closed, connection not closed
        
        return jsonify({
            "status": "connections_leaked",
            "method": "no_pool_no_close",
            "leaked_count": count,
            "total_leaked": len(_leaked_connections),
            "warning": "These connections will remain open until pod restart"
        })
    except Exception as e:
        return Response(f"ERROR: {str(e)}\n", status=500)


@app.route("/db-leak-status")
def db_leak_status():
    """Check status of leaked connections"""
    active = 0
    for conn in _leaked_connections:
        try:
            if not conn.closed:
                active += 1
        except:
            pass
    
    return jsonify({
        "total_leaked": len(_leaked_connections),
        "active_connections": active,
        "closed_connections": len(_leaked_connections) - active
    })


@app.route("/db-leak-cleanup")
def db_leak_cleanup():
    """Cleanup leaked connections"""
    global _leaked_connections
    closed = 0
    for conn in _leaked_connections:
        try:
            if not conn.closed:
                conn.close()
                closed += 1
        except:
            pass
    _leaked_connections = []
    return jsonify({"closed_connections": closed})


@app.route("/db-flood")
def db_flood():
    """Flood database with connections until limit exceeded"""
    max_connections = int(request.args.get('max', 100))
    
    try:
        import psycopg2
        config = get_db_config()
        connections = []
        
        print(f"Attempting to open {max_connections} connections...")
        
        for i in range(max_connections):
            try:
                conn = psycopg2.connect(**config, connect_timeout=5)
                connections.append(conn)
                if (i + 1) % 10 == 0:
                    print(f"Opened {i + 1} connections")
            except psycopg2.OperationalError as e:
                print(f"Connection {i + 1} failed: {e}")
                # Store successful connections for leak
                _leaked_connections.extend(connections)
                return jsonify({
                    "status": "connection_limit_reached",
                    "successful_connections": len(connections),
                    "failed_at": i + 1,
                    "error": str(e)
                })
        
        # All connections successful - store them
        _leaked_connections.extend(connections)
        return jsonify({
            "status": "all_connections_opened",
            "total_connections": len(connections),
            "warning": "All connections leaked - run /db-leak-cleanup to close"
        })
    except Exception as e:
        return Response(f"ERROR: {str(e)}\n", status=500)


# ============================================
# Additional Endpoints for Testing
# ============================================

# Scenario: Service Crash
@app.route("/crash")
def crash():
    print("FATAL: Unrecoverable error in random generator")
    sys.exit(1)

# Scenario: High Latency
@app.route("/slow")
def slow():
    delay = float(request.args.get('delay', 2))
    print(f"Processing complex entropy calculation...")
    time.sleep(delay)
    return f"Entropy calculation completed\n"

# Scenario: Error Generation
@app.route("/error")
def error():
    raise RuntimeError("ERROR: Entropy source unavailable")

# Scenario: OOM - allocate memory until killed
@app.route("/oom")
def oom():
    print("Initializing large entropy buffer pool...")
    memory_hog = []
    chunk_size = 10 * 1024 * 1024  # 10MB
    while True:
        memory_hog.append('x' * chunk_size)
        print(f"Entropy buffer pool: {len(memory_hog) * 10}MB allocated")
        time.sleep(0.1)

# Scenario: CPU Spike - high CPU usage
@app.route("/cpu")
def cpu_spike():
    duration = float(request.args.get('duration', 30))
    print(f"Running entropy quality analysis...")
    end_time = time.time() + duration
    while time.time() < end_time:
        _ = sum(i*i for i in range(10000))
    return f"Entropy analysis completed\n"

# Scenario: Dependency Failure
@app.route("/dependency-fail")
def dependency_fail():
    import requests as req
    try:
        print("Connecting to entropy validation service...")
        req.get("http://entropy-validator.dockercoins:80/", timeout=5)
    except Exception as e:
        return Response(f"ERROR: Upstream service unavailable - {str(e)}\n", status=503)
    return "OK"

@app.route("/config/response")
def config_response():
    """Configure response quality behavior."""
    global _response_quality_factor
    quality = request.args.get("quality", "degraded")
    if quality == "normal":
        prev = _response_quality_factor
        _response_quality_factor = 0.0
        app.logger.info(f"Response quality: normal (was factor={prev})")
        return jsonify({"quality": "normal", "factor": 0, "previous_factor": prev})
    else:
        rate = float(request.args.get("rate", 0.5))
        _response_quality_factor = max(0, min(rate, 1.0))
        app.logger.info(f"Response quality: {quality}, factor={_response_quality_factor}")
        return jsonify({"quality": quality, "factor": _response_quality_factor})


# Health check
@app.route("/health/detailed")
def health_detailed():
    return jsonify({
        "service": "rng",
        "status": "healthy",
        "entropy_source": "/dev/urandom",
        "response_quality": "normal" if _response_quality_factor == 0 else "degraded",
        "quality_factor": _response_quality_factor,
        "db_configured": bool(DB_HOST),
        "leaked_connections": len(_leaked_connections)
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)

