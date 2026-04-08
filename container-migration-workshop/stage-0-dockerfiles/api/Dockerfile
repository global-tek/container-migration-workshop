# syntax=docker/dockerfile:1

# ── Stage 1: builder ──────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /app

# Install dependencies in a separate layer so they're cached
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

# Copy only installed packages from builder (keeps final image small)
COPY --from=builder /install /usr/local

COPY app.py .

# Document the port our process listens on (informational, does not publish it)
EXPOSE 5000

# Run as non-root for security
RUN useradd --no-create-home appuser
USER appuser

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
