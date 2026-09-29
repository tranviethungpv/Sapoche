# Unison: Giao thức đồng bộ (bản nháp v0)

Kết nối: WebSocket tới `wss://<worker>/room/<CODE>`. Mỗi phòng là một Durable Object. Tin nhắn là JSON, có trường `t` (type).

## 1. Trạng thái phòng (nguồn sự thật nằm ở server)

```json
{
  "queue": [{ "id": "q1", "videoId": "dQw4w9WgXcQ", "title": "...", "artist": "...", "thumb": "...", "durMs": 213000, "addedBy": "u2" }],
  "index": 0,
  "phase": "idle | preparing | playing | paused",
  "startedAt": 1759140000000,
  "positionMs": 0,
  "epoch": 17,
  "members": [{ "id": "u1", "name": "Ann", "ready": true }]
}
```

- `phase=playing`: vị trí hiện tại = `serverNow - startedAt`.
- `phase=paused`: vị trí = `positionMs`.
- `epoch` tăng mỗi khi có thay đổi làm mất hiệu lực trạng thái cũ (đổi bài, seek, play/pause). Client bỏ qua tin có `epoch` cũ.

## 2. Đo độ lệch đồng hồ (NTP đơn giản)

Client gửi `{t:"ping", c0}` (c0 = giờ máy client). Server trả `{t:"pong", c0, s1}` (s1 = giờ server). Client nhận lúc c2:
- `rtt = c2 - c0`
- `offset = s1 - (c0 + rtt/2)` (giờ server ≈ giờ máy + offset)

Đo 8 lần lúc vào phòng, lấy mẫu có `rtt` nhỏ nhất. Đo lại mỗi 30 giây khi màn hình sáng, mỗi vài phút khi nền.

## 3. Tin nhắn client → server

| `t` | Trường | Ý nghĩa |
|---|---|---|
| `join` | `name`, `clientId` | Vào phòng; server trả `state` |
| `ping` | `c0` | Đo đồng hồ |
| `queue.add` | `videoId`, metadata | Thêm bài |
| `queue.remove` | `id` | Xóa bài |
| `queue.move` | `id`, `toIndex` | Đổi vị trí |
| `play` / `pause` | | Điều khiển |
| `seek` | `positionMs` | Tua |
| `next` / `prev` | | Chuyển bài |
| `ready` | `epoch` | Máy đã resolve xong và nạp đệm đủ, sẵn sàng phát |
| `report` | `epoch`, `posMs`, `bufferMs` | Báo vị trí định kỳ (chỉ dùng chẩn đoán, 10 giây một lần) |
| `resolveFailed` | `epoch`, `reason` | Máy không lấy được luồng |
| `ended` | `epoch` | Bài phát hết mà không còn bài nạp trước (bài cuối, hoặc nạp trước thất bại) |
| `advanced` | `epoch`, `itemId`, `startedAt` | Máy đã tự chuyển sang bài kế đã nạp trước; `startedAt` là giờ server lúc nghe thấy vị trí 0 của bài mới |

## 4. Tin nhắn server → client

| `t` | Trường | Ý nghĩa |
|---|---|---|
| `state` | toàn bộ trạng thái | Gửi khi vào phòng và khi thay đổi lớn |
| `prepare` | `epoch`, bài, `seekToMs` | Chuẩn bị bài: resolve, nạp đệm, rồi gửi `ready` |
| `start` | `epoch`, `startAt` (giờ server) | Bắt đầu phát tại thời điểm này |
| `pause` | `epoch`, `positionMs` | Dừng tại vị trí |
| `advance` | `epoch`, `index`, `startedAt` | Cả phòng sang bài kế không qua barrier, vị trí 0 nghe thấy lúc `startedAt` |
| `pong` | `c0`, `s1` | Trả lời ping |
| `member` | thêm, bớt, đổi tên | Cập nhật thành viên |

## 5. Luồng đổi bài (barrier)

1. Một máy gửi `next` (hoặc bài hiện tại hết).
2. Server tăng `epoch`, đặt `phase=preparing`, gửi `prepare` cho mọi máy.
3. Mỗi máy resolve URL, nạp đệm khoảng 3 giây, gửi `ready`.
4. Khi mọi máy `ready` (hoặc quá 8 giây thì bỏ qua máy chậm), server đặt `startedAt = serverNow + 1500ms`, `phase=playing`, gửi `start`.
5. Mỗi máy đổi `startAt` sang giờ máy (trừ `offset`) và bắt đầu phát đúng thời điểm.
6. Máy bị bỏ qua khi ready muộn: tự seek đến vị trí hiện tại rồi phát.
7. Trong lúc phát, mỗi máy resolve và nạp trước bài kế tiếp để chuyển bài liền mạch.

### Chuyển bài liền mạch (gapless)

Chuyển bài tự nhiên không đi qua barrier, để không có khoảng lặng:

1. Khi đang theo phòng, mỗi client đưa bài `queue[index+1]` cho trình phát làm bài kế (ExoPlayer nạp đệm và nối liền mạch). Danh sách thay đổi thì bài kế được thay theo.
2. Khi trình phát tự sang bài kế, client chờ khoảng 1 giây cho vị trí ổn định rồi gửi `advanced` với `startedAt = giờ server - vị trí đang nghe`.
3. Server nhận báo cáo hợp lệ đầu tiên (đúng `epoch`, đúng `itemId` là bài kế, mốc thời gian không quá 10 giây trước, bài hiện tại còn không quá 15 giây nữa là hết), tăng `epoch` và `index`, đặt `startedAt`, rồi gửi `advance` cho mọi máy. Báo cáo sau đó bị bỏ qua vì `epoch` đã cũ.
4. Máy đã chuyển bài thì nhận gốc thời gian mới và tiếp tục chỉnh lệch. Máy sắp chuyển thì chờ trình phát của mình (tối đa 4 giây). Máy không có bài nạp trước thì nạp như người vào muộn.
5. Nếu không máy nào báo `advanced`, đường cũ vẫn chạy: `ended` hoặc báo thức hết bài (thời lượng + 5 giây) dẫn tới `prepare` và barrier.

## 6. Chỉnh lệch khi đang phát

Mỗi 500ms, client tính `drift = playerPosition - expectedPosition`:

| `|drift|` | Hành động |
|---|---|
| < 40ms | Giữ tốc độ 1.0 |
| 40ms–400ms | Chỉnh tốc độ 0.97 hoặc 1.03 cho đến khi về gần 0 |
| > 400ms | `seekTo(expectedPosition)`; nếu seek liên tục thất bại thì báo lỗi |

Ngưỡng là giá trị khởi đầu, sẽ chỉnh sau khi đo ở Prototype 2.

Đo trên máy thật cho thấy vị trí ExoPlayer báo có nhiễu răng cưa khoảng 200ms chu kỳ 3–4 giây, nên quyết định không dựa trên từng mẫu mà dựa trên **trung bình cửa sổ 8 mẫu (4 giây)**, sau khi trừ phần đã chỉnh bằng đổi tốc độ. Cửa sổ được xóa sau mỗi lần seek và mỗi lần trình phát dừng hoặc đệm.

**Độ trễ khởi động.** Mỗi máy nghe chậm hơn yêu cầu khoảng 150–350ms sau `play()` hoặc seek (độ trễ đầu ra âm thanh). Máy tự học: sau mỗi lần khởi động thường, độ lệch còn lại trong cửa sổ đầy đầu tiên được cộng vào `startBias` (hệ số 0,8, giới hạn ±800ms, lưu vào bộ nhớ máy), và lần sau tua trước đúng lượng đó. Ngoài ra có `trim` do người dùng chỉnh tay cho thiết bị có độ trễ khác thường (loa Bluetooth).

## 7. Phục hồi

- Rớt WebSocket: client tự kết nối lại (backoff 1s, 2s, 4s tối đa 15s), vào lại bằng `join` với cùng `clientId`, nhận `state` mới và đồng bộ lại. Khi Android báo có mạng hoặc đổi mạng thì bỏ qua thời gian chờ và kết nối lại ngay.
- Vào lại phòng đang phát đúng bài đã nạp thì không nạp lại: chỉ căn lại theo gốc thời gian của phòng (và bấm phát nếu máy đang dừng).
- `prepare` lặp lại cùng `epoch` cho máy đã nạp xong: chỉ gửi lại `ready`.
- Mất mạng giữa bài: trình phát thử lại lỗi mạng tối đa khoảng 8 phút và phát tiếp từ bộ đệm; riêng URL bị từ chối (401, 403, 404, 410) báo lỗi ngay để nạp lại bằng URL mới. Nạp lại thất bại (chưa có mạng) thì thử lại mỗi 5 giây.
- Tiến trình bị hệ thống giết: app lưu mã phòng và tự vào lại khi service khởi động.
- Máy tự dừng (cuộc gọi, ứng dụng khác chiếm âm thanh) trong lúc phòng đang phát: nút phát chỉ tiếp tục trên máy đó, phòng không bị khởi động lại; drift lớn được xử lý bằng một lần seek.
- Server DO ngủ (Hibernation): trạng thái lưu trong storage, không mất khi tỉnh dậy.
- Tin nhắn có `epoch` cũ bị bỏ qua.

## 8. Điểm chưa chốt (kiểm chứng ở Prototype 2)

- Độ trễ bắt đầu 1500ms có đủ cho máy chậm không.
- Ngưỡng chỉnh lệch và mức chỉnh tốc độ có gây nghe méo tiếng không.
- Cách xử lý khi hai người bấm điều khiển cùng lúc (hiện tại: tin đến server trước thắng).
