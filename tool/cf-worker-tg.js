// cf-worker-tg.js - a FREE Cloudflare Worker that bridges WebSocket <-> Telegram.
//
// WHY: on a hard-blackhole network Telegram's own IPs (149.154.x / 91.108.x) are
// dropped by TSPU before packets leave the operator, so no local trick reaches them.
// But Cloudflare's edge IS reachable (proven by tg-ws-probe). This Worker runs ON the
// Cloudflare edge -- OUTSIDE the operator's drop scope -- and connect()s onward to the
// real Telegram datacenters. Your Telegram client still speaks real MTProto end-to-end;
// the Worker is a dumb byte relay (it cannot read your messages -- MTProto is encrypted
// to Telegram with your auth key). No VPS, no subscription: Cloudflare free tier.
//
// ---------------------------------------------------------------------------------
// DEPLOY (about 2 minutes, free):
//   1. Open https://dash.cloudflare.com  ->  Workers & Pages  ->  Create  ->  Worker.
//   2. Name it something boring (e.g. "cdn-edge-7").  Deploy the default, then "Edit code".
//   3. Replace ALL the code with this file's contents. Set KEY below to your own secret.
//   4. Deploy. You get a URL like  https://cdn-edge-7.<your-name>.workers.dev
//   5. PROVE it: open  https://cdn-edge-7.<your-name>.workers.dev/test?key=YOURSECRET
//      in a browser ON THE BLOCKED MACHINE. If you see DC1..DC5 "CONNECTED", Cloudflare
//      reaches Telegram from your network -> the app bridge will work. Send me that output.
// ---------------------------------------------------------------------------------

import { connect } from 'cloudflare:sockets';

// CHANGE THIS to your own random secret (so the relay is not an open abuse target).
const KEY = 'change-me-to-a-long-random-string';

// Telegram's published datacenters (core.telegram.org/resources/cidr.txt). Only these
// are reachable through the relay, so it can never be abused as a general open proxy.
const TG_DCS = {
  '1': '149.154.175.50',
  '2': '149.154.167.51',
  '3': '149.154.175.100',
  '4': '149.154.167.91',
  '5': '91.108.56.130',
};
const TG_ALLOW = /^(149\.154\.|91\.108\.|95\.161\.|91\.105\.|185\.76\.)/;

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.searchParams.get('key') !== KEY) {
      return new Response('no', { status: 403 });
    }

    // --- /test : prove Cloudflare edge -> Telegram DC reachability ---
    if (url.pathname === '/test') {
      const out = {};
      for (const [dc, ip] of Object.entries(TG_DCS)) {
        const label = 'DC' + dc + ' ' + ip;
        try {
          const s = connect({ hostname: ip, port: 443 });
          await s.opened;            // resolves once the TCP handshake completes
          out[label] = 'CONNECTED';
          try { await s.close(); } catch (e) {}
        } catch (e) {
          out[label] = 'FAIL: ' + (e && e.message ? e.message : e);
        }
      }
      return new Response(JSON.stringify(out, null, 2),
        { headers: { 'content-type': 'application/json' } });
    }

    // --- WebSocket <-> Telegram TCP relay (the production path) ---
    if (request.headers.get('Upgrade') === 'websocket') {
      const dc = url.searchParams.get('dc');
      let host = url.searchParams.get('host');
      const port = parseInt(url.searchParams.get('port') || '443', 10);
      if (dc && TG_DCS[dc]) host = TG_DCS[dc];
      if (!host || !TG_ALLOW.test(host)) {
        return new Response('forbidden target', { status: 403 });
      }

      const pair = new WebSocketPair();
      const client = pair[0];
      const server = pair[1];
      server.accept();

      try {
        const socket = connect({ hostname: host, port: port });
        const writer = socket.writable.getWriter();

        // Telegram -> WebSocket
        (async () => {
          const reader = socket.readable.getReader();
          try {
            for (;;) {
              const r = await reader.read();
              if (r.done) break;
              server.send(r.value);
            }
          } catch (e) {}
          try { server.close(1000); } catch (e) {}
        })();

        // WebSocket -> Telegram
        server.addEventListener('message', async (ev) => {
          try {
            const data = ev.data instanceof ArrayBuffer ? new Uint8Array(ev.data) : ev.data;
            await writer.write(data);
          } catch (e) {}
        });
        server.addEventListener('close', () => { try { socket.close(); } catch (e) {} });
        server.addEventListener('error', () => { try { socket.close(); } catch (e) {} });
      } catch (e) {
        try { server.close(); } catch (e2) {}
      }

      return new Response(null, { status: 101, webSocket: client });
    }

    return new Response('relay up. /test?key=... to probe Telegram from this edge.',
      { status: 200 });
  },
};
