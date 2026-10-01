# Unison

Nghe nhạc YouTube cùng nhau, cùng một nhịp, ở mọi nơi.

App Android và iPhone cho nhóm nhỏ bạn bè. Mỗi điện thoại tự lấy luồng nhạc ngay trên máy, còn server miễn phí (Cloudflare Workers) chỉ giữ phòng và giữ nhịp đồng bộ, không chứa nhạc.

## Có gì

- Nghe nhạc như một app thường: tìm kiếm, hàng đợi cá nhân, phát nền, điều khiển ở màn hình khóa.
- Room: tạo phòng hoặc vào bằng mã, mọi người nghe cùng một bài, cùng một nhịp, ai cũng thêm bài và điều khiển được.
- Cập nhật app qua mạng (OTA), giao diện tiếng Anh và tiếng Việt, chế độ tiết kiệm pin và nhiệt.

## Cấu trúc

| Thư mục | Nội dung |
|---|---|
| [app/](app/README.md) | App Flutter (giao diện) và dịch vụ phát nhạc Kotlin (Media3) |
| [app/packages/unison_native/](app/packages/unison_native/) | Phần native của iOS bằng Swift: trình phát, phòng, YouTube, thư viện; có test chạy trên Linux |
| [native/](native/) | Thư viện Kotlin thuần: lấy luồng YouTube, đồng bộ phòng; có test JVM |
| [server/](server/README.md) | Server phòng trên Cloudflare Workers và Durable Objects |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | Giao thức đồng bộ giữa app và server |

## Tự chạy thử

Cần Flutter, JDK 17, Android SDK và một tài khoản Cloudflare miễn phí. Khóa phòng và khóa ký app là của riêng bạn, không nằm trong Git. Cách dựng server, đặt khóa và build app: xem [server/README.md](server/README.md) và [app/README.md](app/README.md).

## iPhone

Bản iOS dùng chung giao diện Flutter với bản Android; phần native viết lại bằng Swift (AVFoundation) và nói cùng giao thức phòng với server. Apple không cho cài app ngoài App Store miễn phí và lâu dài, nên bản này chỉ để dùng cá nhân:

- GitHub Actions dựng một tệp IPA chưa ký ([.github/workflows/ios.yml](.github/workflows/ios.yml)); bạn tải về và ký bằng Apple ID của riêng mình qua [SideStore](https://sidestore.io) (chứng chỉ miễn phí hết hạn sau 7 ngày, SideStore tự gia hạn khi máy ở cùng Wi-Fi).
- Địa chỉ server và khóa phòng không nằm trong app. Cách dễ nhất: trên điện thoại Android đã dùng được, mở Cài đặt > Cài đặt cho máy khác để hiện mã QR, rồi quét bằng Camera của iPhone (hoặc sao chép liên kết `unison://setup?…` và dán ở Cài đặt > Máy chủ); app hỏi lại trước khi dùng. Cũng nhập tay được ở Cài đặt > Máy chủ.
- Chưa có cập nhật qua mạng (SideStore lo), chưa đo pin, và chưa thử trên nhiều máy.

## Lưu ý

Đây là dự án cá nhân, viết để nghe nhạc cùng bạn bè trong nhóm nhỏ, không có mục đích thương mại. Việc lấy luồng từ YouTube bằng client bên thứ ba không nằm trong điều khoản dịch vụ của YouTube, nên hãy tự cân nhắc trước khi dùng, và không dùng để lưu hay phân phối lại nhạc.
