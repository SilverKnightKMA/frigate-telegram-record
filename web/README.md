# Frigate Web Dashboard

## Cách sử dụng Dashboard

Dashboard web đơn giản để theo dõi thống kê camera và lịch sử ghi hình từ database.

### Khởi động với Docker Compose

```bash
docker-compose up -d frigate-web-dashboard
```

### Truy cập Dashboard

Mở trình duyệt và truy cập: `http://localhost:8080`

### Tính năng

Dashboard hiển thị:

1. **Thống kê tổng quan:**
   - Tổng số camera
   - Số lượng video ghi thành công
   - Số lượng timelapse
   - Số lượng lỗi/thất bại
   - Hoạt động trong 24h qua

2. **Bảng thống kê chi tiết theo camera:**
   - Tên camera
   - Số video thành công
   - Số timelapse
   - Số lỗi
   - Tổng thời lượng ghi
   - Thời gian ghi đầu tiên và gần nhất

3. **Danh sách hoạt động gần đây:**
   - 100 hoạt động gần nhất
   - Bao gồm records thành công, timelapse, và lỗi
   - Thông tin chi tiết về từng hoạt động

### Cấu hình

Có thể thay đổi port trong `docker-compose.yml`:

```yaml
environment:
  - WEB_PORT=8080  # Thay đổi port nếu cần
ports:
  - "8080:8080"    # Thay đổi port bên trái
```

### Chạy standalone (không dùng Docker)

```bash
# Cài đặt dependencies
pip install -r requirements-web.txt

# Chạy app
export DB_FILE=./data/video_history.sqlite
python web_dashboard.py
```

Dashboard sẽ tự động làm mới mỗi 30 giây.
