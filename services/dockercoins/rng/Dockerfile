FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir Flask requests psycopg2-binary
COPY rng.py /
CMD ["python", "rng.py"]
EXPOSE 80
