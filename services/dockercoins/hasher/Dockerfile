FROM python:3.12-slim
RUN pip install --no-cache-dir Flask
COPY hasher.py /
CMD ["python", "hasher.py"]
EXPOSE 80
HEALTHCHECK \
  --interval=1s --timeout=2s --retries=3 --start-period=1s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost/')" || exit 1
