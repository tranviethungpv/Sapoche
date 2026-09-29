# Unison server

Cloudflare Worker + một Durable Object cho mỗi phòng. Chỉ giữ siêu dữ liệu (queue, trạng thái phát, thành viên), không có audio.

- `src/index.ts`: định tuyến (`GET /health`, `POST /rooms`, `WS /room/<CODE>`).
- `src/room.ts`: logic phòng (barrier chuẩn bị, phát, tạm dừng, tua, queue, dọn phòng trống).
- `src/protocol.ts`: kiểu tin nhắn, khớp với [../docs/PROTOCOL.md](../docs/PROTOCOL.md).
- `scripts/sim.mjs`: mô phỏng nhiều thiết bị, kiểm tra toàn bộ luồng giao thức.

## Chạy cục bộ (không cần tài khoản Cloudflare)

Wrangler yêu cầu Node 22 trở lên. Máy này có Node 22 riêng tại `~/.local/share/node`:

```bash
export PATH=$HOME/.local/share/node/bin:$PATH
cd server
npm install
npm run typecheck
npm run dev          # http://127.0.0.1:8787
npm run sim          # ở terminal khác; kỳ vọng 22 passed, 0 failed
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
