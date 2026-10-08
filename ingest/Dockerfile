FROM python:3.12-slim
# Non-root with a numeric UID so the pod passes the "restricted" Pod Security level.
RUN useradd --uid 10001 --create-home ingest
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY schema.sql analytics.sql ./
COPY pipeline ./pipeline
USER 10001
ENTRYPOINT ["python", "-m", "pipeline"]
