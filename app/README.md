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

`tool/soak.sh` chạy một buổi nghe với màn hình tắt trên các máy đã vào cùng phòng (âm lượng phải để 0 từ trước) và in số lần chuyển bài, tua lại, lỗi, độ lệch.

## Mời bạn bè

Nút chia sẻ trong phòng gửi mã 6 ký tự và liên kết `unison://join/MÃ`. Mở liên kết trên máy đã cài app sẽ điền sẵn mã (hoặc hỏi có đổi phòng không nếu đang ở phòng khác). Ứng dụng chat thường không bấm được liên kết kiểu này, nên mã là đường chính.
