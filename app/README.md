# Unison (app Flutter)

Giao diện Flutter, còn phát nhạc và đồng bộ phòng nằm ở phần Kotlin trong `android/` (xem [docs/PLAN.md](../docs/PLAN.md)).

```
lib/
  theme/     bảng màu hồng nhạt (sáng và tối) và ThemeData
  data/      mô hình, cầu nối tới Kotlin (backend.dart), RoomController
  ui/        các màn hình và widget
  strings.dart   toàn bộ chữ hiển thị
android/app/src/main/kotlin/app/unison/
  UnisonBridge.kt   MethodChannel + EventChannel giữa Flutter và native
  PlaybackService.kt, GroupController.kt, ExoPlayerPort.kt   phát nhạc và vào phòng
../native/{core,sync}   tách luồng YouTube và engine đồng bộ, dùng chung với spike
```

## Chạy thử

```bash
export PATH=$HOME/.local/share/flutter/bin:$PATH
# khóa dùng chung với server (không commit): tạo android/unison.properties với dòng
#   unison.roomKey=<khóa>
# và tùy chọn unison.serverUrl=<địa chỉ server>
flutter pub get
flutter run            # hoặc: flutter build apk --debug
```

Đổi khóa server thì build và cài lại app cho cả nhóm (xem [server/README.md](../server/README.md)).

## Kiểm thử

```bash
flutter analyze && flutter test        # giao diện, bộ điều khiển, hợp đồng kênh
cd android && ./gradlew :core:test :sync:test   # phân tích link, engine đồng bộ
```

`tool/soak.sh` chạy một buổi nghe với màn hình tắt trên các máy đã vào cùng phòng (âm lượng phải để 0 từ trước) và in số lần chuyển bài, tua lại, lỗi, độ lệch. `tool/battery.sh` đo thời gian CPU, khung hình và số lần nối lại của app trong một khoảng, để so hai bản trên cùng một máy. Cả hai tắt màn hình bằng phím nguồn: máy có khoá màn hình sẽ bị khoá lại và chỉ mở được bằng tay.

## Mời bạn bè

Tờ "Room" trong phòng có mã 6 ký tự, mã QR và liên kết `https://<server>/join/MÃ`; nút chia sẻ gửi mã kèm liên kết đó (bấm được trong Zalo, Messenger). Với app đã cài, Android xác minh địa chỉ server qua `/.well-known/assetlinks.json` (dấu vân tay khoá ký nằm ở `server/src/join-page.ts`; đổi khoá ký thì sửa ở đó) và mở thẳng app; chưa xác minh thì trang trên server thử mở app rồi hiện mã để gõ. Liên kết `unison://join/MÃ` cũ vẫn dùng được. Mở liên kết khi đang ngoài phòng sẽ mở tờ Room với mã điền sẵn, đang trong phòng khác thì hỏi có đổi phòng không.

## Nghe ngoài phòng

Mở app là vào hàng đợi cá nhân (lưu trong `files/local_queue.json`, trở lại sau khi khởi động lại ở trạng thái tạm dừng). Nút "Room" ở đầu trang dẫn tới tờ để tạo, vào bằng mã, hoặc vào lại một phòng gần đây. Kế hoạch cho playlist, yêu thích, lịch sử, gợi ý và tải về: [docs/LIBRARY.md](../docs/LIBRARY.md).
