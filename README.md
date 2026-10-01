# Unison

Nghe nhạc YouTube cùng nhau, cùng một nhịp, ở mọi nơi.

App Android cho nhóm nhỏ bạn bè. Mỗi điện thoại tự lấy luồng nhạc ngay trên máy, còn server miễn phí (Cloudflare Workers) chỉ giữ phòng và giữ nhịp đồng bộ, không chứa nhạc.

## Có gì

- Nghe nhạc như một app thường: tìm kiếm, hàng đợi cá nhân, phát nền, điều khiển ở màn hình khóa.
- Room: tạo phòng hoặc vào bằng mã, mọi người nghe cùng một bài, cùng một nhịp, ai cũng thêm bài và điều khiển được.
- Cập nhật app qua mạng (OTA), giao diện tiếng Anh và tiếng Việt, chế độ tiết kiệm pin và nhiệt.

## Cấu trúc

| Thư mục | Nội dung |
|---|---|
| [app/](app/README.md) | App Flutter (giao diện) và dịch vụ phát nhạc Kotlin (Media3) |
| [native/](native/) | Thư viện Kotlin thuần: lấy luồng YouTube, đồng bộ phòng; có test JVM |
| [server/](server/README.md) | Server phòng trên Cloudflare Workers và Durable Objects |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | Giao thức đồng bộ giữa app và server |

## Tự chạy thử

Cần Flutter, JDK 17, Android SDK và một tài khoản Cloudflare miễn phí. Khóa phòng và khóa ký app là của riêng bạn, không nằm trong Git. Cách dựng server, đặt khóa và build app: xem [server/README.md](server/README.md) và [app/README.md](app/README.md).

## Lưu ý

Đây là dự án cá nhân, viết để nghe nhạc cùng bạn bè trong nhóm nhỏ, không có mục đích thương mại. Việc lấy luồng từ YouTube bằng client bên thứ ba không nằm trong điều khoản dịch vụ của YouTube, nên hãy tự cân nhắc trước khi dùng, và không dùng để lưu hay phân phối lại nhạc.
