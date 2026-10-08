FROM python:3.12-slim
RUN useradd --uid 10003 --create-home dash
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py architecture.svg ./
RUN python -m py_compile app.py
USER 10003
EXPOSE 8080
ENTRYPOINT ["python", "app.py"]
