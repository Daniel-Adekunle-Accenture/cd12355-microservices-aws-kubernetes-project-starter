# Coworking analytics API image (Flask + Flask-SQLAlchemy + psycopg2 + APScheduler).
# Base: official Python 3.12 slim image on Debian bookworm, pinned to a patch release so every
# build starts from the same interpreter. psycopg2-binary ships its own libpq, so the image
# needs no compiler or libpq-dev packages. The image is pulled from the ECR Public mirror of the
# Docker Official Images, which avoids Docker Hub's anonymous pull limit on shared CodeBuild hosts.
FROM public.ecr.aws/docker/library/python:3.12.16-slim-bookworm

# PYTHONUNBUFFERED: log lines go straight to stdout/stderr, so Kubernetes and CloudWatch
# Container Insights receive them immediately. PYTHONDONTWRITEBYTECODE: no .pyc files.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    APP_PORT=5153

WORKDIR /app

# Install the pinned dependencies before copying the code, so this layer stays cached
# until requirements.txt changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application, then create an unprivileged system user (uid 10001) and switch to it.
COPY . .
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

# app.py listens on 0.0.0.0:${APP_PORT}. Database settings (DB_HOST, DB_PORT, DB_USERNAME,
# DB_NAME, DB_PASSWORD) come from the ConfigMap and Secret at runtime, never from the image.
EXPOSE 5153
CMD ["python", "app.py"]
