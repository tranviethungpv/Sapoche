# Unison server

Cloudflare Worker + một Durable Object cho mỗi phòng. Chỉ giữ siêu dữ liệu (queue, trạng thái phát, thành viên), không có audio.

- `src/index.ts`: định tuyến (`GET /health`, `POST /rooms`, `WS /room/<CODE>`, `GET /room/<CODE>/info`, `GET /join/<CODE>`, `GET /.well-known/assetlinks.json`, `GET /update/latest.json`, `GET /update/app-<mã bản>.apk`) và kiểm tra khóa dùng chung.
- `src/update.ts`: cập nhật cho chính app, đọc từ bucket R2 `unison-releases` (riêng tư, chỉ đọc qua Worker, cần khóa). Cách tạo và phát hành: [../docs/FINISH.md](../docs/FINISH.md).
- `src/room.ts`: logic phòng (barrier chuẩn bị, phát, tạm dừng, tua, queue, chủ phòng và quyền, dọn phòng trống và socket chết).
- `src/join-page.ts`: trang HTML của link mời và danh sách khóa ký cho `assetlinks.json` (thêm khóa mới ở đây khi đổi khóa ký).
- `src/protocol.ts`: kiểu tin nhắn, khớp với [../docs/PROTOCOL.md](../docs/PROTOCOL.md).
- `scripts/sim.mjs`: mô phỏng nhiều thiết bị, kiểm tra toàn bộ luồng giao thức.
- `scripts/sim-keyed.mjs`: dựng hai server cục bộ có khóa (một với hẹn giờ thật, một với hẹn giờ vài giây để xem phòng hết hạn), chạy `sim.mjs`, rồi dọn sạch tiến trình (là lệnh `npm test`).

## Chạy cục bộ (không cần tài khoản Cloudflare)

Wrangler yêu cầu Node 22 trở lên. Máy này có Node 22 riêng tại `~/.local/share/node`:

```bash
export PATH=$HOME/.local/share/node/bin:$PATH
cd server
npm install
npm run typecheck
npm run dev          # http://127.0.0.1:8787
npm run sim          # ở terminal khác, server không khóa; kỳ vọng 39 passed
npm test             # tự dựng server có khóa rồi kiểm thử; kỳ vọng 128 passed rồi 6 passed, 0 failed
```

Để điện thoại trong cùng Wi-Fi kết nối được, chạy `npx wrangler dev --ip 0.0.0.0 --port 8787` rồi dùng `ws://<ip-máy-dev>:8787`.

## Triển khai

Đã triển khai tại `https://your-worker.example.workers.dev` (WebSocket: `wss://.../room/<CODE>`).

```bash
npx wrangler login        # một lần, mở trình duyệt
npx wrangler r2 bucket create unison-releases   # một lần; bucket phải có trước khi deploy
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
- Phòng trống còn bài tự xóa sau 7 ngày, phòng trống không còn bài sau 1 giờ; mỗi phòng chứa tối đa 12 người và 200 bài, mỗi kết nối tối đa 20 tin nhắn mỗi giây. Một phòng chiếm chưa tới 50 KB (gói miễn phí cho 5 GB tổng), nên phòng mồ côi không tốn tiền; việc dọn là để danh sách "phòng gần đây" trung thực.
- Biến môi trường chỉ dành cho test (`STALE_MS`, `DROP_MS`, `SWEEP_MS`, `EMPTY_MS`, `EMPTY_BARE_MS`) rút ngắn các hẹn giờ trên; không đặt chúng trên server thật.
- Ước tính tải: một thiết bị gửi khoảng 2 ping mỗi phút (đo đồng hồ) và vài tin mỗi bài, còn ghi bộ nhớ khoảng 10 lần mỗi bài, nên nhóm 5 người nghe cả ngày vẫn thấp hơn nhiều so với hạn mức 100.000 yêu cầu và 100.000 lượt ghi mỗi ngày (tin WebSocket tính 20 tin bằng 1 yêu cầu).
- Bản triển khai hiện tại: giao thức phiên bản 6 (`GET /health` báo `protocol`, tin `state` cũng mang trường này). Thay đổi từ 5 sang 6 chỉ thêm, app bản 5 vẫn dùng được.
