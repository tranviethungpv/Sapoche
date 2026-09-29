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

## 4. Tin nhắn server → client

| `t` | Trường | Ý nghĩa |
|---|---|---|
| `state` | toàn bộ trạng thái | Gửi khi vào phòng và khi thay đổi lớn |
| `prepare` | `epoch`, bài, `seekToMs` | Chuẩn bị bài: resolve, nạp đệm, rồi gửi `ready` |
| `start` | `epoch`, `startAt` (giờ server) | Bắt đầu phát tại thời điểm này |
| `pause` | `epoch`, `positionMs` | Dừng tại vị trí |
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

## 6. Chỉnh lệch khi đang phát

Mỗi 500ms, client tính `drift = playerPosition - expectedPosition`:

| `|drift|` | Hành động |
|---|---|
| < 40ms | Giữ tốc độ 1.0 |
| 40ms–400ms | Chỉnh tốc độ 0.97 hoặc 1.03 cho đến khi về gần 0 |
| > 400ms | `seekTo(expectedPosition)`; nếu seek liên tục thất bại thì báo lỗi |

Ngưỡng là giá trị khởi đầu, sẽ chỉnh sau khi đo ở Prototype 2.

## 7. Phục hồi

- Rớt WebSocket: client tự kết nối lại (backoff 1s, 2s, 4s tối đa 15s), vào lại bằng `join` với cùng `clientId`, nhận `state` mới và đồng bộ lại.
- Server DO ngủ (Hibernation): trạng thái lưu trong storage, không mất khi tỉnh dậy.
- Tin nhắn có `epoch` cũ bị bỏ qua.

## 8. Điểm chưa chốt (kiểm chứng ở Prototype 2)

- Độ trễ bắt đầu 1500ms có đủ cho máy chậm không.
- Ngưỡng chỉnh lệch và mức chỉnh tốc độ có gây nghe méo tiếng không.
- Cách xử lý khi hai người bấm điều khiển cùng lúc (hiện tại: tin đến server trước thắng).
