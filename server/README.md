# Unison server

Cloudflare Worker + một Durable Object cho mỗi phòng. Chỉ giữ siêu dữ liệu (queue, trạng thái phát, thành viên), không có audio.

- `src/index.ts`: định tuyến (`GET /health`, `POST /rooms`, `WS /room/<CODE>`) và kiểm tra khóa dùng chung.
- `src/room.ts`: logic phòng (barrier chuẩn bị, phát, tạm dừng, tua, queue, dọn phòng trống).
- `src/protocol.ts`: kiểu tin nhắn, khớp với [../docs/PROTOCOL.md](../docs/PROTOCOL.md).
- `scripts/sim.mjs`: mô phỏng nhiều thiết bị, kiểm tra toàn bộ luồng giao thức.
- `scripts/sim-keyed.mjs`: dựng server cục bộ có khóa, chạy `sim.mjs`, rồi dọn sạch tiến trình (là lệnh `npm test`).

## Chạy cục bộ (không cần tài khoản Cloudflare)

Wrangler yêu cầu Node 22 trở lên. Máy này có Node 22 riêng tại `~/.local/share/node`:

```bash
export PATH=$HOME/.local/share/node/bin:$PATH
cd server
npm install
npm run typecheck
npm run dev          # http://127.0.0.1:8787
npm run sim          # ở terminal khác, server không khóa; kỳ vọng 39 passed
npm test             # tự dựng server có khóa rồi kiểm thử; kỳ vọng 45 passed, 0 failed
```

Để điện thoại trong cùng Wi-Fi kết nối được, chạy `npx wrangler dev --ip 0.0.0.0 --port 8787` rồi dùng `ws://<ip-máy-dev>:8787`.

## Triển khai

Đã triển khai tại `https://your-worker.example.workers.dev` (WebSocket: `wss://.../room/<CODE>`).

```bash
npx wrangler login        # một lần, mở trình duyệt
npm run deploy
node scripts/sim.mjs https://your-worker.example.workers.dev   # kiểm thử trên server thật
```

Thử WebSocket bằng curl phải thêm `--http1.1` (HTTP/2 không có header Upgrade).

## Khóa dùng chung (bí mật)

Nếu không có khóa, ai biết URL đều có thể tạo phòng và tiêu hạn mức 100.000 yêu cầu mỗi ngày của gói Free. Worker vì vậy yêu cầu khóa `ROOM_KEY` cho `POST /rooms` và `WS /room/<CODE>`; sai hoặc thiếu thì trả 401. `/health` luôn mở để phân biệt "server hỏng" với "sai khóa". Khóa gửi trong header `X-Unison-Key` (app) hoặc tham số `?key=` (client không đặt được header, ví dụ trình duyệt). Nếu server không có `ROOM_KEY` (chạy cục bộ) thì mở hoàn toàn.

```bash
# đặt hoặc đổi khóa (giá trị tự sinh, không lưu vào Git)
openssl rand -hex 16 | tr -d '\n' | npx wrangler secret put ROOM_KEY
```

App Android đọc khóa lúc build từ `spikes/p1-resolver-player/local.properties` (đã nằm trong `.gitignore`):

```properties
unison.roomKey=<khóa>
# tùy chọn, mặc định là server hiện tại
unison.serverUrl=https://your-worker.example.workers.dev
```

Đổi khóa nghĩa là phải build và cài lại app cho cả nhóm. Khóa nằm trong APK nên chỉ chống người lạ, không chống người trong nhóm.

## Vận hành

- Xem log trực tiếp: `npx wrangler tail`.
- Phòng trống tự xóa sau 24 giờ; mỗi phòng chứa tối đa 12 người và 200 bài, mỗi kết nối tối đa 20 tin nhắn mỗi giây.
- Ước tính tải: một thiết bị gửi khoảng 2 ping mỗi phút (đo đồng hồ) và vài tin mỗi bài, còn ghi bộ nhớ khoảng 10 lần mỗi bài, nên nhóm 5 người nghe cả ngày vẫn thấp hơn nhiều so với hạn mức 100.000 yêu cầu và 100.000 lượt ghi mỗi ngày (tin WebSocket tính 20 tin bằng 1 yêu cầu).
- Bản triển khai hiện tại: giao thức phiên bản 2 (`GET /health` báo `protocol`, tin `state` cũng mang trường này).
