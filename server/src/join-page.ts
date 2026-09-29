const PACKAGE = "app.unison";

/**
 * The page an invitation link opens. With the app installed and the link verified Android goes
 * straight to the app and never shows this; otherwise the page tries the app and, failing that, shows
 * the code so it can be typed in. Nothing here touches the room.
 */
export function joinPage(code: string): string {
  const intent = `intent://join/${code}#Intent;scheme=unison;package=${PACKAGE};end`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Join on Unison</title>
<style>
  :root { color-scheme: light dark; --pink: #d4587a; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 16px/1.5 system-ui, sans-serif; background: #fdf3f5; color: #2b1d21; }
  @media (prefers-color-scheme: dark) { body { background: #1a1315; color: #f3e6e9; } }
  main { max-width: 22rem; padding: 2rem 1.5rem; text-align: center; }
  h1 { font-size: 1.25rem; margin: 0 0 1rem; }
  .code { font-size: 2.5rem; letter-spacing: .4rem; font-weight: 700; margin: 1rem 0 1.5rem; }
  a.open, button { display: block; width: 100%; box-sizing: border-box; margin: .5rem 0; padding: .9rem; border: 0; border-radius: 1rem; font: inherit; font-weight: 600; text-decoration: none; cursor: pointer; }
  a.open { background: var(--pink); color: #fff; }
  button { background: transparent; color: var(--pink); box-shadow: inset 0 0 0 2px var(--pink); }
  p { opacity: .7; font-size: .9rem; }
</style>
</head>
<body>
<main>
  <h1>You are invited to listen together</h1>
  <div class="code">${code}</div>
  <a class="open" href="${intent}">Open in Unison</a>
  <button id="copy">Copy code</button>
  <p>Not opening? Install Unison, then choose Room and enter this code.</p>
</main>
<script>
  document.getElementById("copy").onclick = function () {
    if (navigator.clipboard) navigator.clipboard.writeText("${code}");
    this.textContent = "Copied";
  };
  if (/Android/i.test(navigator.userAgent)) setTimeout(function () { location.href = "${intent}"; }, 300);
</script>
</body>
</html>
`;
}

/**
 * Lets Android verify that this host belongs to the app, so its links open the app directly. Both the
 * release key and the debug key are listed; a fingerprint is public.
 */
export const ASSET_LINKS = [
  {
    relation: ["delegate_permission/common.handle_all_urls"],
    target: {
      namespace: "android_app",
      package_name: PACKAGE,
      sha256_cert_fingerprints: [
        "AC:29:E8:89:49:56:43:2C:84:C6:BD:A3:D3:E5:77:AF:6F:0C:0B:8F:3D:F9:0F:E3:B8:1E:11:4C:0F:8F:8C:23",
        "1E:46:49:89:64:96:47:57:5B:2F:54:23:45:01:D6:58:B7:50:8E:7D:85:97:E7:EA:17:F0:69:34:C4:75:A0:C5",
      ],
    },
  },
];
