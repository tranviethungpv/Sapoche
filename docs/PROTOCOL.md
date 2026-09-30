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
  "repeat": "off | all | one",
  "name": "Cả nhà",
  "ownerId": "u1",
  "guestControl": "all | add",
  "members": [{ "id": "u1", "name": "Ann", "ready": true, "solo": false, "away": false, "owner": true }]
}
```

`name`, `ownerId` có thể vắng. Xem mục 5c cho chủ phòng và tên phòng.

- `phase=playing`: vị trí hiện tại = `serverNow - startedAt`.
- `phase=paused`: vị trí = `positionMs`.
- `epoch` tăng mỗi khi có thay đổi làm mất hiệu lực trạng thái cũ (đổi bài, seek, play/pause). Client bỏ qua tin có `epoch` cũ.

## 2. Đo độ lệch đồng hồ (NTP đơn giản)

Client gửi `{t:"ping", c0}` (c0 = giờ máy client). Server trả `{t:"pong", c0, s1}` (s1 = giờ server). Client nhận lúc c2:
- `rtt = c2 - c0`
- `offset = s1 - (c0 + rtt/2)` (giờ server ≈ giờ máy + offset)

Đo 8 lần lúc vào phòng, lấy mẫu có `rtt` nhỏ nhất. Đo lại mỗi 30 giây khi màn hình sáng, mỗi vài phút khi nền.

## 2b. Xác thực

`POST /rooms`, `GET /room/<CODE>/info` và `WS /room/<CODE>` cần khóa dùng chung `ROOM_KEY` (header `X-Unison-Key`, hoặc tham số `?key=` khi không đặt được header). Sai hoặc thiếu trả HTTP 401 trước khi nâng cấp WebSocket; client coi đó là lỗi cuối cùng và không thử lại. Ba đường luôn mở: `GET /health` trả `{"ok":true,"protocol":6}`; `GET /join/<CODE>` là trang mà link mời mở ra (thử mở app bằng `intent://`, không thì hiện mã); `GET /.well-known/assetlinks.json` để Android xác minh link https của app. Ba đường này không đụng tới phòng nên không cần khóa. Chi tiết vận hành ở [../server/README.md](../server/README.md).

`GET /room/<CODE>/info` chỉ đọc, không tạo gì: `{"exists":true,"name":"Cả nhà","members":2,"playing":true,"title":"..."}`; `exists:false` khi phòng chưa từng có hoặc đã hết hạn. App dùng nó cho danh sách phòng gần đây.

## 3. Tin nhắn client → server

| `t` | Trường | Ý nghĩa |
|---|---|---|
| `join` | `name`, `clientId`, `create?` | Vào phòng; server trả `state`. `create:true` là mã máy vừa tự tạo, `create:false` là mã được cho: phòng chưa tồn tại thì server trả lỗi `room_not_found` rồi đóng 4004 (gõ sai mã không mở phòng rỗng). Vắng `create` là app cũ, được mở phòng như trước |
| `bye` | | Rời có chủ ý (khác với mất kết nối). Chủ phòng gửi `bye` thì người ở lâu nhất lên làm chủ; phòng hết người thì không còn chủ |
| `kick` | `id` | Chỉ chủ phòng: ngắt kết nối thành viên đó (đóng 4001, kèm lỗi `removed`); họ vẫn vào lại được |
| `room.name` | `name` | Đổi tên phòng, tối đa 32 ký tự, rỗng là xóa tên |
| `room.settings` | `guestControl` | Chỉ chủ phòng: `all` (mọi người điều khiển, mặc định) hoặc `add` (khách chỉ thêm bài) |
| `ping` | `c0` | Đo đồng hồ |
| `queue.add` | `videoId`, metadata, `next?` | Thêm bài; `next: true` chèn ngay sau bài đang phát (nếu phòng đang `idle` thì bài mới chỉ được thêm vào cuối và phát) |
| `queue.addMany` | `tracks[]`, `next?` | Thêm nhiều bài một lần (playlist), tối đa 100 bài mỗi tin, bài sai `videoId` bị bỏ; cùng quy tắc `next` như `queue.add`. Một tin, một lần phát `state`, nên không dính giới hạn 20 tin mỗi giây |
| `queue.remove` | `id` | Xóa bài |
| `queue.swap` | `id`, `track` (`videoId`, `title`, `artist`, `thumb?`, `durMs`) | Thay mục `id` bằng bản khác của cùng một bài (video ↔ bản audio), giữ chỗ, giữ `id` và người thêm. Nếu đó là bài đang phát (đang chạy, tạm dừng hay đang chuẩn bị): phát `prepare` mới cho mọi máy, tua đến đúng vị trí hiện tại (cắt theo độ dài bản mới), rồi `start` khi mọi người sẵn sàng; phòng đang tạm dừng thì phát tiếp sau lần đổi. `videoId` trùng với bản hiện có hoặc `id` không có thì bỏ qua; `videoId` sai thì `bad_video`. Bị giới hạn như `queue.move` khi chủ chỉ cho khách thêm bài. Giao thức 7 |
| `queue.clear` | | Xóa hết hàng đợi, phòng về `idle` |
| `queue.shuffle` | | Trộn các bài **sắp tới**, bài đang phát giữ nguyên chỗ. Khi phòng đang `idle` (hàng đợi đã hết) thì trộn toàn bộ và phát từ bài đầu. Dưới 2 bài thì không làm gì |
| `jump` | `id` | Phát ngay bài này từ đầu (qua barrier) |
| `queue.move` | `id`, `toIndex` | Đổi vị trí |
| `play` / `pause` | | Điều khiển. `play` khi phòng `idle` ở bài cuối (hàng đợi đã hết) phát lại **từ bài đầu**, không chỉ bài cuối |
| `seek` | `positionMs` | Tua |
| `next` / `prev` | | Chuyển bài; `next` ở bài cuối khi `repeat=all` quay về bài đầu |
| `repeat` | `mode` | `off`: dừng sau bài cuối. `all`: hết hàng đợi thì phát lại từ đầu. `one`: bài hiện tại hết thì phát lại chính nó (nút `next` vẫn sang bài kế). Giá trị lạ bị bỏ qua |
| `solo` | `on` | Bắt đầu (`true`) hoặc thôi (`false`) nghe riêng: lệnh của phòng không điều khiển máy này nữa và phòng không chờ máy này ở barrier. Server quên cờ này khi socket đứt, nên client gửi lại sau mỗi lần kết nối lại |
| `resync` | | Xin server gửi lại `state` (và `prepare` nếu phòng đang chuẩn bị) cho riêng socket này; dùng khi quay lại phòng sau khi nghe riêng |
| `ready` | `epoch` | Máy đã resolve xong và nạp đệm đủ, sẵn sàng phát |
| `report` | `epoch`, `posMs`, `bufferMs` | Báo vị trí định kỳ (chỉ dùng chẩn đoán, 10 giây một lần) |
| `resolveFailed` | `epoch`, `reason` | Máy không lấy được luồng. Tính như đã trả lời để không kìm các máy khác; nếu **mọi** máy trong phòng đều báo lỗi thì server gửi `error` mã `unplayable` và chuyển sang bài kế (hoặc `idle` nếu hết bài) thay vì chạy đồng hồ im lặng |
| `ended` | `epoch` | Bài phát hết mà không còn bài nạp trước (bài cuối, hoặc nạp trước thất bại) |
| `advanced` | `epoch`, `itemId`, `startedAt` | Máy đã tự chuyển sang bài kế đã nạp trước; `startedAt` là giờ server lúc nghe thấy vị trí 0 của bài mới |

## 4. Tin nhắn server → client

| `t` | Trường | Ý nghĩa |
|---|---|---|
| `state` | toàn bộ trạng thái, `protocol` | Gửi khi vào phòng và khi thay đổi lớn; `protocol` là phiên bản giao thức của server (hiện là 6) |
| `prepare` | `epoch`, bài, `seekToMs`, `by?` | Chuẩn bị bài: resolve, nạp đệm, rồi gửi `ready`. `by` là `clientId` người vừa bấm chuyển bài; vắng mặt khi phòng tự sang bài kế |
| `start` | `epoch`, `startAt` (giờ server), `by?` | Bắt đầu phát tại thời điểm này |
| `pause` | `epoch`, `positionMs`, `by?` | Dừng tại vị trí |
| `advance` | `epoch`, `index`, `startedAt` | Cả phòng sang bài kế không qua barrier, vị trí 0 nghe thấy lúc `startedAt` |
| `pong` | `c0`, `s1` | Trả lời ping |
| `members` | `members[]` | Danh sách thành viên, gửi khi có người vào, ra, đổi tên, đổi chế độ nghe riêng, đổi chủ hoặc chuyển giữa hiện diện và `away` |
| `error` | `code`, `message` | Mã hiện có: `not_joined`, `bad_message`, `bad_json`, `rate_limited`, `unknown_type`, `bad_video`, `queue_full`, `unplayable`, `room_not_found` (kèm đóng 4004), `room_full` (kèm đóng 1008), `forbidden` (lệnh chỉ dành cho chủ), `removed` (kèm đóng 4001) |

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

### Phát lặp

Phát lặp không đi đường gapless: hết bài thì client báo `ended` (hoặc báo thức hết bài chạy), server gọi `begin` lại đúng bài đó (`repeat=one`) hoặc bài đầu (`repeat=all` ở cuối hàng đợi), nên có một nhịp barrier khoảng 1,5 đến 4 giây giữa hai lượt. Khi `repeat=one` client không nạp trước bài kế (nếu không ExoPlayer sẽ tự sang bài kế) và server bỏ qua `advanced`.

## 5b. Nghe riêng và hiện diện

**Nghe riêng (`solo`).** Một máy có thể thôi theo phòng mà không cần rời phòng. Máy đó giữ nguyên bài đang phát; từ đó `prepare`, `start`, `pause`, `advance` của phòng chỉ cập nhật phần hiển thị (phòng đang dừng, đang ở bài nào), còn nút phát, dừng, tua, bài kế, bài trước, chọn bài chỉ tác động lên máy này, đi theo hàng đợi của phòng và nạp trước bài kế để hết bài không có khoảng trống. Máy nghe riêng không gửi `ready`, `ended`, `advanced` nên không bao giờ kìm phòng. Quay lại phòng: gửi `solo:false` rồi `resync`, và xử lý `state` nhận về như người vào muộn (đang cùng bài thì chỉ căn lại vị trí, không nạp lại).

Ai làm gì: `pause`, `start` và `prepare` mang `by` để máy khác hiện thông báo "Ann đã dừng phòng" kèm nút "Keep playing" (chuyển sang nghe riêng và phát tiếp) hoặc "Ann đã chuyển sang bài X".

**Hiện diện (`away`).** Client gửi `ping` mỗi 30 giây (mỗi lần ping giữ sóng di động thức, nên thưa hơn thì tiết kiệm pin hơn), server ghi lại lần nghe cuối của từng socket. Im quá 75 giây thì thành viên được đánh dấu `away` (mờ đi, không tính là đang nghe, không kìm barrier); im quá 150 giây thì server đóng socket và xóa khỏi danh sách. Mỗi tin nhắn của bất kỳ ai là một dịp để server rà soát và phát lại `members` nếu ai đó đổi trạng thái, nên không cần bộ đếm giờ riêng. Đây là lớp dự phòng cho socket chết mà không đóng; app bị tắt cưỡng bức thường được nhận ra ngay khi socket đóng.

## 5c. Chủ phòng, tên phòng và vòng đời

**Chủ phòng.** Người mở phòng (`create:true`), hoặc người vào đầu tiên khi phòng chưa có chủ, là chủ. `guestControl` mặc định `all`: mọi người ngang quyền, như trước. Chủ chuyển sang `add` thì khách chỉ được thêm bài (`queue.add`, `queue.addMany`) và tự nghe riêng; `play`, `pause`, `seek`, `next`, `prev`, `jump`, `queue.remove`, `queue.swap`, `queue.move`, `queue.clear`, `queue.shuffle`, `repeat`, `room.name` bị trả `forbidden`. Giới hạn chỉ có hiệu lực khi chủ đang có mặt (socket mở và không `away`); chủ mất mạng thì mọi người điều khiển được, chủ quay lại thì giới hạn có lại, không cần bộ đếm bàn giao. `kick` và `room.settings` luôn chỉ dành cho chủ. Phòng hết người thì mất chủ và `guestControl` về `all`; người vào đầu tiên sau đó thành chủ mới.

**Vòng đời.** Mã chỉ là tên: phòng sinh ra khi có người vào với `create` không phải `false`, và không tồn tại cho đến lúc đó. Phòng trống giữ 7 ngày nếu còn bài trong hàng đợi, 1 giờ nếu không còn bài, rồi bị xóa hết (`deleteAll`). Server chỉ có một báo thức Durable Object nhưng giữ giờ đến hạn của từng việc (`barrier`, `end`, `gc`, `sweep`) và đặt báo thức ở mốc gần nhất. `sweep` chạy 5 phút một lần khi phòng có người: đóng socket im quá 150 giây (kể cả khi không ai gửi gì), để phòng toàn máy chết vẫn trống và bị dọn. Socket chưa vào phòng (hoặc bị từ chối) không tạo dữ liệu nào. Server còn hiểu trạng thái lưu theo dạng cũ (một báo thức duy nhất).

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
- Tiến trình bị hệ thống giết: app lưu mã phòng, thời điểm còn sống lần cuối (ghi mỗi phút khi ở trong phòng) và chế độ nghe riêng. Service khởi động lại trong vòng 10 phút thì vào lại phòng (`join` với `create:false`), và nếu đang nghe riêng thì vào lại ở chế độ nghe riêng, tạm dừng, không tự phát. Ngoài 10 phút, hoặc mở app bình thường, thì bắt đầu ở ngoài phòng với hàng đợi cá nhân.
- Tạm dừng lâu: ở trong phòng mà không phát và màn hình không hiện quá 20 phút thì client đóng WebSocket (ping mỗi 30 giây giữ sóng thức cả ngày); nối lại khi màn hình hiện hoặc khi có lệnh từ thông báo (lệnh được giữ đến khi nối xong). Server thấy đó là một thành viên rời đi, và phòng cho phép mọi người điều khiển nếu chủ là người đó.
- Kết nối chết mà không đóng: client dùng đúng một ping (30 giây) và coi kết nối đã chết nếu 45 giây không có `pong`, rồi nối lại; không còn ping cấp giao thức của OkHttp.
- Máy tự dừng (cuộc gọi, ứng dụng khác chiếm âm thanh) trong lúc phòng đang phát: nút phát chỉ tiếp tục trên máy đó, phòng không bị khởi động lại; drift lớn được xử lý bằng một lần seek.
- Server DO ngủ (Hibernation): trạng thái lưu trong storage, không mất khi tỉnh dậy.
- Tin nhắn có `epoch` cũ bị bỏ qua.

## 8. Điểm chưa chốt (kiểm chứng ở Prototype 2)

- Độ trễ bắt đầu 1500ms có đủ cho máy chậm không.
- Ngưỡng chỉnh lệch và mức chỉnh tốc độ có gây nghe méo tiếng không.
- Cách xử lý khi hai người bấm điều khiển cùng lúc (hiện tại: tin đến server trước thắng).
