// Runs the real hub (server.js, fixture mode) behind a TLS front on 127.0.0.1 for the Swift
// transport's end-to-end tests, in the manner of build/test/desktop-rotation.cjs.
//
//   node e2e-hub.cjs <repository root>
//
// The front presents certificates from a throwaway CA, records every request that reaches it,
// and can swap its key, misbehave or impersonate on command. Commands are JSON lines on stdin
// ({ seq, command, ...arguments }); each gets one JSON line on stdout ({ seq, ok, result | error }).
// Everything is synthetic and bound to loopback, and the process exits when stdin closes.
'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const http2 = require('node:http2');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');
const { execFileSync } = require('node:child_process');

const root = path.resolve(process.argv[2] || '.');
const { startHub } = require(path.join(root, 'server.js'));
const transport = require(path.join(root, 'transport.js'));

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-ios-e2e-'));
const openssl = (...args) => execFileSync('openssl', args, { cwd: dir, stdio: ['ignore', 'pipe', 'pipe'] });
const file = name => path.join(dir, name);

function authority(name) {
  fs.writeFileSync(file(name + '.cnf'), '[req]\ndistinguished_name = dn\nx509_extensions = ca\nprompt = no\n[dn]\nCN = ' + name + '\n' +
    '[ca]\nbasicConstraints = critical,CA:TRUE\nkeyUsage = critical,keyCertSign,cRLSign\nsubjectKeyIdentifier = hash\n');
  openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', name + '.key');
  openssl('req', '-x509', '-new', '-key', name + '.key', '-sha256', '-days', '2', '-config', name + '.cnf', '-out', name + '.pem');
}
function leaf(name, ca, san, rsa = false) {
  fs.writeFileSync(file(name + '.cnf'), '[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = ' + name + '\n');
  fs.writeFileSync(file(name + '.ext'), 'subjectAltName = ' + san + '\nbasicConstraints = critical,CA:FALSE\n' +
    'keyUsage = critical,digitalSignature\nextendedKeyUsage = serverAuth\n');
  if (rsa) openssl('genrsa', '-out', name + '.key', '2048');
  else openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', name + '.key');
  openssl('req', '-new', '-key', name + '.key', '-config', name + '.cnf', '-out', name + '.csr');
  openssl('x509', '-req', '-in', name + '.csr', '-CA', ca + '.pem', '-CAkey', ca + '.key', '-CAcreateserial', '-sha256', '-days', '2',
    '-extfile', name + '.ext', '-out', name + '.pem');
  return { cert: fs.readFileSync(file(name + '.pem')), key: fs.readFileSync(file(name + '.key')) };
}

async function main() {
  authority('trusted'); authority('foreign');
  const here = 'IP:127.0.0.1,DNS:localhost';
  const certs = {
    a: leaf('a', 'trusted', here),              // the key the hub is paired under
    b: leaf('b', 'trusted', here, true),        // the key it rotates to (RSA, to cover both kinds)
    c: leaf('c', 'trusted', here),              // a valid certificate in the wrong hands
    untrusted: leaf('untrusted', 'foreign', here),
    wrongName: leaf('wrong-name', 'trusted', 'DNS:wrong.test'),
  };
  const pins = Object.fromEntries(Object.entries(certs).map(([k, v]) => [k, transport.publicKeyPin(new crypto.X509Certificate(v.cert))]));
  const proxyCertFile = file('proxy.pem');
  fs.writeFileSync(proxyCertFile, certs.a.cert);

  let hub, other, mode = 'normal', served = 'a', streams = 0, bigBytes = 0, connections = 0;
  const calls = [], connectionIds = new WeakMap();
  const proofPath = '/api/desktop/tls-proof';
  const sse = { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store' };
  const write = (res, chunk) => new Promise(resolve => {
    if (res.destroyed || res.write(chunk)) return resolve();
    const done = () => { res.off('drain', done); res.off('close', done); resolve(); };
    res.once('drain', done); res.once('close', done);
  });

  const front = https.createServer(certs.a, async (req, res) => {
    let bytes;
    try { bytes = await transport.readBytes(req, 2e6); } catch { res.destroy(); return; }
    const url = new URL(req.url, 'http://x');
    calls.push({ mode, served, method: req.method, path: url.pathname, query: url.search,
      authorization: req.headers.authorization ?? null, contentType: req.headers['content-type'] ?? null,
      cookie: req.headers.cookie ?? null, body: bytes.toString('utf8'), http: req.httpVersion,
      resumed: req.socket.isSessionReused(), connection: connectionIds.get(req.socket) ?? (connectionIds.set(req.socket, ++connections), connections) });
    if (url.pathname === '/api/stream') { streams++; res.once('close', () => { streams--; }); }

    if (url.pathname === '/e2e/redirect') { res.writeHead(302, { Location: '/api/devices' }); res.end(); return; }
    if (url.pathname === '/e2e/slow') return;                       // never answers
    if (url.pathname === '/e2e/cookie') { res.writeHead(200, { 'Content-Type': 'application/json', 'Set-Cookie': 'dm=1; Path=/' }); res.end('{}'); return; }
    if (url.pathname === '/e2e/big') {
      const n = Number(url.searchParams.get('bytes'));
      res.writeHead(200, { 'Content-Type': 'application/json', ...(url.searchParams.has('chunked') ? {} : { 'Content-Length': n }) });
      res.end(Buffer.alloc(n, 0x20)); return;
    }
    if (url.pathname === '/api/info' && mode === 'big-info') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ app: 'device-monitor', pad: 'x'.repeat(100000) })); return; }
    if (url.pathname === '/api/info' && mode === 'not-a-hub') { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end('<!doctype html><title>Router</title>'); return; }
    if (url.pathname === '/api/stream' && mode === 'stalled-stream') { res.writeHead(200, sse); res.write('data: {"type":"snapshot","devices":[]}\n\n'); return; }
    if (url.pathname === '/api/stream' && mode === 'big-stream') {
      // One snapshot-sized frame of multi-byte text, written in pieces that ignore character
      // boundaries, then its digest and a heartbeat so the reader can check what it received.
      res.writeHead(200, sse);
      const unit = Buffer.from('aé漢😀', 'utf8'), head = '{"type":"snapshot","devices":[],"pad":"', tail = '"}';
      const pad = Buffer.alloc(Math.ceil(bigBytes / unit.length) * unit.length);
      for (let at = 0; at < pad.length; at += unit.length) unit.copy(pad, at);
      const payload = Buffer.concat([Buffer.from(head), pad, Buffer.from(tail)]);
      const frame = Buffer.concat([Buffer.from('data: '), payload, Buffer.from('\n\n')]);
      for (let at = 0; at < frame.length; at += 65521) await write(res, frame.subarray(at, at + 65521));
      await write(res, 'data: ' + JSON.stringify({ type: 'digest', bytes: payload.length, sha256: crypto.createHash('sha256').update(payload).digest('hex') }) + '\n\n');
      const beat = setInterval(() => res.write('data: {"type":"status","online":{}}\n\n'), 200);
      res.once('close', () => clearInterval(beat));
      return;
    }

    if (mode === 'unrelated' && !other) other = await startHub({ ...options, dataDir: file('different-hub') });
    const backend = mode === 'unrelated' ? other : hub;
    const headers = { ...req.headers, 'x-forwarded-for': '192.168.1.8', 'x-forwarded-proto': 'https' };
    const upstream = http.request({ host: '127.0.0.1', port: backend.port, path: req.url, method: req.method, headers, agent: false }, reply => {
      res.writeHead(reply.statusCode, reply.headers);
      reply.pipe(res);
      // When the hub cuts a response short (a revoked stream), so does the front.
      reply.on('error', () => res.destroy());
      reply.on('close', () => { if (!reply.complete) res.destroy(); });
    });
    upstream.on('error', () => res.destroy());
    res.on('close', () => upstream.destroy());
    upstream.end(bytes);
  });
  await new Promise(resolve => front.listen(0, '127.0.0.1', resolve));
  const base = 'https://127.0.0.1:' + front.address().port;
  const options = { port: 0, dataDir: file('hub'), fixture: true, publicUrl: base, proxyCertFile };
  hub = await startHub(options);
  const local = (resource, init = {}) => transport.hubJson('http://127.0.0.1:' + hub.port, resource, { token: hub.localKey, ...init });

  // The hub itself speaks HTTP/1.1, but tailscale serve and most reverse proxies offer HTTP/2,
  // where every request shares one connection and so one handshake. This stand-in answers a few
  // paths itself; it is there to exercise the client's connection handling, not the hub.
  const multiplexed = new Set();
  const h2 = http2.createSecureServer({ ...certs.a, allowHTTP1: false }, (req, res) => {
    const url = new URL(req.url, 'http://x');
    calls.push({ mode, served: 'h2', method: req.method, path: url.pathname, query: url.search,
      authorization: req.headers.authorization ?? null, contentType: req.headers['content-type'] ?? null,
      cookie: req.headers.cookie ?? null, body: '', resumed: req.socket.isSessionReused?.() ?? false, connection: 0, http: req.httpVersion });
    if (url.pathname === '/api/stream') {
      streams++;
      res.writeHead(200, sse);
      res.write('data: {"type":"snapshot","devices":[]}\n\n');
      const beat = setInterval(() => res.write('data: {"type":"status","online":{}}\n\n'), 100);
      res.once('close', () => { streams--; clearInterval(beat); });
      return;
    }
    const answer = () => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ app: 'device-monitor', http: req.httpVersion })); };
    if (url.pathname === '/e2e/slow') setTimeout(answer, 300); else answer();
  });
  h2.on('session', session => { multiplexed.add(session); session.once('close', () => multiplexed.delete(session)); });
  await new Promise(resolve => h2.listen(0, '127.0.0.1', resolve));

  // A hub with the mobile routes issues mobile invitations. An older one only has the desktop
  // kind, whose redemption has the same shape ({ id, client, <second secret> }) and proof key.
  const invite = kind => local('/api/invites', { method: 'POST', body: JSON.stringify({ kind, origin: base }) }).then(r => r.json);
  const mobile = await invite('mobile').then(() => true, () => false);
  const seed = (id, hostname) => hub.seedReport({ id, hostname, platform: 'linux', cpu: { usage: 37 }, memory: { total: 8e9, used: 2e9 } });

  const commands = {
    invite() { return invite(mobile ? 'mobile' : 'desktop'); },
    seed({ id, hostname }) { seed(id, hostname); return {}; },
    // The operator removing the enrollment on the hub. A desktop's goes with its device.
    async revoke({ id }) {
      if (!mobile) seed(id, 'revoked');
      return (await local((mobile ? '/api/mobile/' : '/api/devices/') + encodeURIComponent(id), { method: 'DELETE' })).json;
    },
    // `certificate` is what the front presents; `proxy` is the certificate the hub is told is being served.
    // `keepTickets` models a TLS terminator that renews its certificate in place (tailscale serve,
    // a reloaded nginx): session tickets issued under the old key stay redeemable.
    present({ certificate, proxy, keepTickets }) {
      served = certificate;
      const tickets = front.getTicketKeys();
      front.setSecureContext(certs[certificate]);
      if (keepTickets) front.setTicketKeys(tickets);
      if (proxy) fs.writeFileSync(proxyCertFile, certs[proxy].cert);
      front.closeAllConnections();      // a rotated server does not keep its old connections
      return {};
    },
    // The same for the HTTP/2 stand-in.
    presentMultiplexed({ certificate }) {
      h2.setSecureContext(certs[certificate]);
      for (const session of multiplexed) session.destroy();
      return {};
    },
    mode(args) { mode = args.mode; bigBytes = args.bytes || 0; return {}; },
    calls({ since = 0 }) { return { total: calls.length, calls: calls.slice(since) }; },
    streams() { return { open: streams }; },
  };

  const reply = value => process.stdout.write(JSON.stringify(value) + '\n');
  reply({ ready: true, origin: base, multiplexedOrigin: 'https://127.0.0.1:' + h2.address().port, mobile, pins,
    ca: new crypto.X509Certificate(fs.readFileSync(file('trusted.pem'))).raw.toString('base64') });
  const lines = readline.createInterface({ input: process.stdin });
  lines.on('line', async line => {
    let seq = null;
    try {
      const message = JSON.parse(line); seq = message.seq;
      reply({ seq, ok: true, result: await commands[message.command](message) });
    } catch (error) { reply({ seq, ok: false, error: String(error && error.message || error) }); }
  });
  lines.on('close', () => {
    hub.close(); other?.close(); front.closeAllConnections(); front.close();
    for (const session of multiplexed) session.destroy();
    h2.close();
    fs.rmSync(dir, { recursive: true, force: true });
    process.exit(0);
  });
}
main().catch(error => { console.error(error.stack || error); fs.rmSync(dir, { recursive: true, force: true }); process.exit(1); });
