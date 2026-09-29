# Unison

Nghe nhạc YouTube cùng nhau, cùng một nhịp, ở mọi nơi.

App Android cho nhóm nhỏ. Mỗi điện thoại tự lấy luồng nhạc, còn server miễn phí chỉ giữ phòng và giữ nhịp đồng bộ.

- Kế hoạch triển khai: [docs/PLAN.md](docs/PLAN.md)
- Giao thức đồng bộ: [docs/PROTOCOL.md](docs/PROTOCOL.md)
- Nghe nhạc như app bình thường (playlist, yêu thích, lịch sử, gợi ý, tải về): [docs/LIBRARY.md](docs/LIBRARY.md)

## Trạng thái

App Flutter chạy được trên máy thật: nghe nhạc như app thường (hàng đợi cá nhân), và vào Room để nghe cùng nhau, cùng nhịp; xem [app/](app/README.md) để chạy thử, [server/](server/README.md) cho server phòng. Tiến độ chi tiết ở [docs/PLAN.md](docs/PLAN.md). Các prototype cũ nằm ở [spikes/](spikes/).

## Lưu ý

Dự án dùng cho mục đích cá nhân, nhóm riêng tư. Việc lấy luồng từ YouTube bằng client bên thứ ba vi phạm điều khoản dịch vụ của YouTube. Đừng phát hành công khai.
