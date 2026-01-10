# Build & Release Guide

## 🏗️ Build Process

Project này có 2 Docker images riêng biệt:

### 1. Record/Timelapse Image
- **Image name**: `ghcr.io/<owner>/frigate-telegram-record`
- **Source files**: `app.sh`, `Dockerfile`
- **Workflow**: `.github/workflows/build.yml`
- **Trigger tags**: `v*.*.*` (ví dụ: `v1.0.7`)

### 2. Web Dashboard Image
- **Image name**: `ghcr.io/<owner>/frigate-telegram-record-web`
- **Source files**: `web/` directory (contains: `web_dashboard.py`, `requirements.txt`, `templates/`, `Dockerfile`)
- **Workflow**: `.github/workflows/build-web.yml`
- **Trigger tags**: `web-*.*.*` (ví dụ: `web-1.0.0`)

## 🚀 Release Workflow

### Release Record/Timelapse version mới:

```bash
# Commit changes to app.sh or Dockerfile
git add app.sh Dockerfile
git commit -m "feat: add new feature to record"

# Tag với prefix v
git tag v1.0.7
git push origin v1.0.7

# GitHub Actions sẽ build và push:
# - ghcr.io/<owner>/frigate-telegram-record:v1.0.7
# - ghcr.io/<owner>/frigate-telegram-record:1.0.7
# - ghcr.io/<owner>/frigate-telegram-record:latest (nếu release)
```

### Release Web Dashboard version mới:

```bash
# Commit changes to web files
git add web/
git commit -m "feat: improve dashboard UI"

# Tag với prefix web-
git tag web-1.0.1
git push origin web-1.0.1

# GitHub Actions sẽ build và push:
# - ghcr.io/<owner>/frigate-telegram-record-web:1.0.1
# - ghcr.io/<owner>/frigate-telegram-record-web:latest (nếu release)
```

## 📦 Image Tags Explained

### Record Image Tags:
- `latest` - Latest stable release
- `dev` - Latest commit to main branch
- `v1.0.7` - Specific version with v prefix
- `1.0.7` - Specific version without v prefix
- `edge` - Pull request builds
- `<sha>` - Specific commit SHA

### Web Image Tags:
- `latest` - Latest stable release
- `dev` - Latest commit to main branch (web files changed)
- `1.0.1` - Specific version
- `edge` - Pull request builds
- `<sha>` - Specific commit SHA

## 🔄 Auto-build Triggers

### Record image builds khi:
- Push tag `v*.*.*`
- Push to `main` branch (files: `app.sh`, `Dockerfile`)
- Pull request thay đổi files trên
- Manual workflow dispatch

### Web image builds khi:
- Push tag `web-*.*.*`
- Push to `main` branch (any files in `web/` directory)
- Pull request thay đổi files trong `web/`
- Manual workflow dispatch

## 📋 Checklist trước khi release

### Record/Timelapse:
- [ ] Test app.sh locally
- [ ] Update version in README if needed
- [ ] Commit changes
- [ ] Create tag `v*.*.*`
- [ ] Push tag
- [ ] Verify GitHub Actions build successfully
- [ ] Update docker-compose.yml example version

### Web Dashboard:
- [ ] Test web_dashboard.py locally
- [ ] Update web/README.md if needed
- [ ] Commit changes to web/ directory
- [ ] Create tag `web-*.*.*`
- [ ] Push tag
- [ ] Verify GitHub Actions build successfully
- [ ] Update docker-compose.yml example version

## 🐳 Docker Hub/GHCR Usage

### Pull images:

```bash
# Record/Timelapse
docker pull ghcr.io/<owner>/frigate-telegram-record:latest
docker pull ghcr.io/<owner>/frigate-telegram-record:v1.0.7

# Web Dashboard
docker pull ghcr.io/<owner>/frigate-telegram-record-web:latest
docker pull ghcr.io/<owner>/frigate-telegram-record-web:1.0.1
```

### Use in docker-compose.yml:

```yaml
services:
  frigate-telegram-record:
    image: ghcr.io/<owner>/frigate-telegram-record:v1.0.7
    
  frigate-web-dashboard:
    image: ghcr.io/<owner>/frigate-telegram-record-web:1.0.1
```

## 🛠️ Local Build

```bash
# Build record image
docker build -f Dockerfile -t frigate-telegram-record:local .

# Build web image
docker build -f web/Dockerfile -t frigate-telegram-record-web:local ./web
```
