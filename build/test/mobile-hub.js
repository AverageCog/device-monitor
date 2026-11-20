// Fixture hub for end-to-end tests of the iOS app in the Simulator: a real hub (fixture mode)
// that terminates TLS on localhost with a throwaway CA, seven realistic devices that keep
// reporting, a week of history, an electricity price and firing alerts. Synthetic data, loopback only.
//
//   node build/test/mobile-hub.js [--port 8443] [--control 8444] [--dir <dir>] [--keep] [--interval 2000]
//
//   --port     HTTPS port; the hub's origin is https://localhost:<port> (default 8443)
//   --control  port of the plain-HTTP control endpoint on 127.0.0.1 (default: the HTTPS port + 1; 0 picks a free one)
//   --dir      keeps ca.pem and ca.key there, so one CA stays trusted across runs
//              (default: a temporary directory that is removed on exit)
//   --keep     with --dir: also keep the hub's data (paired phones, history) in <dir>/hub
//   --interval milliseconds between each device's reports (default 2000, as real agents report)
//
// Trust the CA once per simulator:   xcrun simctl keychain <udid> add-root-cert <dir>/ca.pem
// When it is ready it prints one JSON line on stdout:
//   { origin, ca, invitation, controlPort, pin, dataDir }     (pin: base64 SHA-256 of the served SPKI)
//
// Control endpoint, http://127.0.0.1:<control> (curl -X POST for the POSTs):
//   GET  /invite                  a fresh iPhone / iPad invitation, as text
//   GET  /state                   { origin, pin, phones, devices: { <id>: "reporting" | "paused" } }
//   POST /rotate-tls              new leaf key + certificate from the same CA, swapped in live -> { pin, previous, key }
//                                 ?key=ec|rsa picks the key type (default: the other one), ?keep=1 leaves open
//                                 connections alone (default: they are closed, so every client handshakes again)
//   POST /revoke-mobile           removes every paired phone -> { revoked }
//   POST /device/<id>/offline     stops that device's reports (the hub shows it offline 30 s after the last one)
//   POST /device/<id>/online      resumes them
//   POST /alert                   the Gaming PC's D: drive passes the 90 % disk rule, then recovers after
//                                 ?seconds=8 -> an alert event "firing", later "resolved"
//
// Devices: gaming (Windows, one NVIDIA GPU, sensors and fans) · spark (Linux DGX, AI models, measured CPU
// power) · mbp (MacBook, no GPU temperature) · server (Linux, no GPU, a disk over the default 90 % rule)
// · studio (Windows, two GPUs, an older app version) · nas (reports three times, then goes offline; has
// a network card address for Wake-on-LAN) · htpc (offline since before the hub started).
const crypto = require('node:crypto'), fs = require('node:fs'), http = require('node:http'), os = require('node:os'), path = require('node:path');
const { execFileSync } = require('node:child_process');
const { startHub } = require('../../server');
const transport = require('../../transport');

const arg = (name, fallback) => { const i = process.argv.indexOf('--' + name); return i > 1 && process.argv[i + 1] ? process.argv[i + 1] : fallback; };
const port = Number(arg('port', 8443)), controlPort = Number(arg('control', port + 1)), given = arg('dir'), keep = !!given && process.argv.includes('--keep');
const interval = Math.max(50, Number(arg('interval', 2000)) || 2000);
const temporary = [];
const scratch = (parent, prefix) => { const dir = fs.mkdtempSync(path.join(parent, prefix)); temporary.push(dir); return dir; };
const base = given ? path.resolve(given) : scratch(os.tmpdir(), 'dm-mobile-hub-');
fs.mkdirSync(base, { recursive: true, mode: 0o700 });
const dataDir = keep ? path.join(base, 'hub') : scratch(base, 'hub-'), work = scratch(base, 'tls-');
const origin = 'https://localhost:' + port, ca = path.join(base, 'ca.pem'), caKey = path.join(base, 'ca.key');

// ---- TLS: Node makes the keys, the openssl CLI (OpenSSL or LibreSSL) signs ----
const gitOpenssl = path.join(process.env.ProgramFiles || 'C:/Program Files', 'Git', 'usr', 'bin', 'openssl.exe');   // Windows has none on PATH
const openssl = (...args) => execFileSync(process.platform === 'win32' && fs.existsSync(gitOpenssl) ? gitOpenssl : 'openssl', args, { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
function privateKey(file, type) {
  const pair = type === 'rsa' ? crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }) : crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
  fs.writeFileSync(file, pair.privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
}
function authority() {
  if (fs.existsSync(ca) && fs.existsSync(caKey)) return;
  const config = path.join(work, 'ca.cnf');
  fs.writeFileSync(config, '[req]\ndistinguished_name = dn\nx509_extensions = v3\nprompt = no\n[dn]\nCN = Device Monitor fixture CA ' + crypto.randomBytes(3).toString('hex') +
    '\n[v3]\nbasicConstraints = critical,CA:TRUE\nkeyUsage = critical,keyCertSign,cRLSign\nsubjectKeyIdentifier = hash\n');
  privateKey(caKey, 'ec');
  openssl('req', '-x509', '-new', '-key', caKey, '-sha256', '-days', '3650', '-config', config, '-out', ca);
}
// A leaf for localhost / 127.0.0.1 within Apple's limits for TLS server certificates (SAN, serverAuth, under 398 days).
// 'ec' is what a Tailscale or Let's Encrypt hub serves; 'rsa' is what many home CAs issue. Pins must work for both.
let leafType = null, pin = null;
function leaf(type = leafType === 'ec' ? 'rsa' : 'ec') {
  const config = path.join(work, 'leaf.cnf'), key = path.join(work, 'leaf.key'), request = path.join(work, 'leaf.csr'), cert = path.join(work, 'leaf.pem');
  fs.writeFileSync(config, '[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = localhost\n[v3]\nbasicConstraints = critical,CA:FALSE\nkeyUsage = critical,digitalSignature' +
    (type === 'rsa' ? ',keyEncipherment' : '') + '\nextendedKeyUsage = serverAuth\nsubjectAltName = DNS:localhost,IP:127.0.0.1\nauthorityKeyIdentifier = keyid\n');
  privateKey(key, type);
  openssl('req', '-new', '-key', key, '-config', config, '-out', request);
  openssl('x509', '-req', '-in', request, '-CA', ca, '-CAkey', caKey, '-set_serial', '0x' + (crypto.randomBytes(8).readBigUInt64BE() >> 1n).toString(16),
    '-sha256', '-days', '397', '-extfile', config, '-extensions', 'v3', '-out', cert);
  const options = { key: fs.readFileSync(key), cert: fs.readFileSync(cert) };
  leafType = type; pin = transport.publicKeyPin(new crypto.X509Certificate(options.cert));
  return options;
}

// ---- Devices (modelled on build/screenshots.js) ----
const GB = 1e9, TB = 1e12, MIN = 60e3, started = Date.now(), version = require('../../package.json').version;
const devs = [
  { id: 'gaming', name: 'Gaming PC', platform: 'windows', os: 'Windows 11 Pro', formFactor: 'desktop', uptime: 5.2 * 3600, appVersion: version, mac: 'a8:a1:59:3c:10:01',
    cpu: { name: 'AMD Ryzen 9 9950X3D', threads: 32, base: 22, swing: 18, clock: 5250, temp: 52 }, mem: 64 * GB, memUse: 0.48, ai: [],
    gpus: [{ name: 'NVIDIA GeForce RTX 5090', base: 70, swing: 25, mem: 32 * GB, power: 575, temp: 66 }],
    disks: [{ name: 'C:', label: 'Windows', total: 2 * TB, used: 1.1 * TB }, { name: 'D:', label: 'Games', total: 4 * TB, used: 3.1 * TB }],
    fans: [['CPU fan', 1240], ['Rear', 980], ['Front 1', 1110], ['Front 2', 1105]], temps: [['CPU Package', 61], ['Motherboard', 38], ['NVMe 1', 44], ['NVMe 2', 41]] },
  { id: 'spark', name: 'DGX Spark', platform: 'linux', os: 'Ubuntu 24.04 LTS', formFactor: 'desktop', uptime: 12 * 86400, cpuPower: 38,
    cpu: { name: 'NVIDIA Grace (Cortex-X925)', threads: 20, base: 18, swing: 10, clock: 3900, temp: 58 }, mem: 128 * GB, memUse: 0.86,
    gpus: [{ name: 'NVIDIA GB10', base: 88, swing: 10, mem: 0, power: 140, temp: 71 }], disks: [{ name: '/', total: 4 * TB, used: 2.3 * TB }],
    ai: [{ app: 'ComfyUI', mem: 62e9, models: [{ name: 'flux2_dev_fp8.safetensors', size: 23.8e9, kind: 'unet' }, { name: 'qwen3_vl_8b.safetensors', size: 16.4e9, kind: 'clip' }, { name: 'flux2_vae.safetensors', size: 0.34e9, kind: 'vae' }] },
         { app: 'Ollama', mem: 21e9, models: [{ name: 'qwen3:32b', size: 20.1e9 }] }] },
  { id: 'mbp', name: 'MacBook Pro', platform: 'macos', os: 'macOS 26.1', formFactor: 'laptop', uptime: 3 * 86400, appVersion: version,
    cpu: { name: 'Apple M4 Max', threads: 16, base: 14, swing: 10, clock: 4500, temp: 49 }, mem: 48 * GB, memUse: 0.62,
    gpus: [{ name: 'Apple M4 Max GPU', base: 12, swing: 8, mem: 0, power: null, temp: null }], disks: [{ name: '/', label: 'Macintosh HD', total: 2 * TB, used: 0.9 * TB }] },
  { id: 'server', name: 'Home Server', platform: 'linux', os: 'Debian 13', formFactor: 'desktop', uptime: 41 * 86400, mac: '3c:ec:ef:7a:22:04',
    cpu: { name: 'Intel Core i5-13500', threads: 20, base: 9, swing: 5, clock: 2500, temp: 41 }, mem: 32 * GB, memUse: 0.41, gpus: [],
    disks: [{ name: '/', total: 0.5 * TB, used: 0.12 * TB }, { name: '/mnt/media', label: 'Media', total: 16 * TB, used: 11.8 * TB }, { name: '/mnt/backup', label: 'Backup', total: 8 * TB, used: 7.6 * TB }] },
  { id: 'studio', name: 'Studio PC', platform: 'windows', os: 'Windows 11 Home', formFactor: 'desktop', uptime: 26 * 3600, appVersion: '1.2.30', mac: '04:42:1a:9e:5b:05',
    cpu: { name: 'Intel Core i9-14900K', threads: 32, base: 31, swing: 22, clock: 5600, temp: 57 }, mem: 96 * GB, memUse: 0.55,
    gpus: [{ name: 'NVIDIA GeForce RTX 4090', base: 55, swing: 35, mem: 24 * GB, power: 450, temp: 63 }, { name: 'NVIDIA GeForce RTX 4070 Ti SUPER', base: 20, swing: 15, mem: 16 * GB, power: 285, temp: 54 }],
    disks: [{ name: 'C:', label: 'System', total: 1 * TB, used: 0.61 * TB }, { name: 'E:', label: 'Projects', total: 8 * TB, used: 5.2 * TB }],
    fans: [['CPU pump', 2650], ['Top 1', 890], ['Top 2', 905], ['GPU 2', 1420]], temps: [['CPU Package', 64], ['VRM', 52], ['NVMe', 47]] },
  { id: 'nas', name: 'NAS', platform: 'linux', os: 'TrueNAS SCALE 25.04', formFactor: 'desktop', uptime: 96 * 86400, mac: '00:11:32:c4:0d:06', reports: 3,
    cpu: { name: 'Intel N100', threads: 4, base: 6, swing: 4, clock: 2900, temp: 39 }, mem: 16 * GB, memUse: 0.58, gpus: [],
    disks: [{ name: '/', total: 0.25 * TB, used: 0.03 * TB }, { name: '/mnt/tank', label: 'Tank', total: 24 * TB, used: 15.1 * TB }] },
  // Never reports in this run: registered as last seen three days ago, so it is offline from the first second.
  { id: 'htpc', name: 'Living Room PC', platform: 'windows', os: 'Windows 11 Home', formFactor: 'desktop', mac: '70:85:c2:6b:f0:07', gone: 3 * 86400e3,
    cpu: { name: 'AMD Ryzen 5 5600G', threads: 12, base: 8, swing: 6, clock: 3900, temp: 44 }, mem: 16 * GB, memUse: 0.37, gpus: [], disks: [] },
];
const clamp = v => Math.max(0, Math.min(100, v));
// Smooth, slightly noisy load curves so the charts look like real machines.
const wave = (t, base, swing, phase) => clamp(base + swing * (0.6 * Math.sin(t / 2.1e6 + phase) + 0.4 * Math.sin(t / 5.3e5 + phase * 3)) + (Math.random() - 0.5) * swing * 0.3);
function sample(d, t, i) {
  const cpu = wave(t, d.cpu.base, d.cpu.swing, i), g = d.gpus[0], gpu = g ? wave(t, g.base, g.swing, i + 1) : null;
  return { cpu, gpu, mem: d.memUse * 100 + Math.sin(t / 3e6 + i) * 3, cpuTemp: d.cpu.temp + cpu * 0.25,
    gpuTemp: g?.temp != null ? g.temp - 20 + gpu * 0.25 : null, gpuPower: g?.power ? g.power * (0.12 + 0.85 * gpu / 100) : null };
}
let alertUntil = 0;
function report(d, i) {
  const t = Date.now(), s = sample(d, t, i);
  return { id: d.id, hostname: d.name, platform: d.platform, os: d.os, uptime: d.uptime + (t - started) / 1000, formFactor: d.formFactor, appVersion: d.appVersion,
    power: d.cpuPower ? { cpu: d.cpuPower * (0.6 + s.cpu / 100) } : null,
    cpu: { name: d.cpu.name, usage: s.cpu, threads: d.cpu.threads, clockMHz: d.cpu.clock, temp: s.cpuTemp, cores: Array.from({ length: d.cpu.threads }, () => clamp(s.cpu + (Math.random() - 0.5) * 30)) },
    memory: { total: d.mem, used: d.mem * s.mem / 100 },
    gpus: d.gpus.map((g, n) => {
      const usage = n ? wave(t, g.base, g.swing, i + n + 2) : s.gpu, temp = g.temp != null ? g.temp - 20 + usage * 0.25 : null;
      return { name: g.name, vendor: /Apple/.test(g.name) ? 'apple' : 'nvidia', usage, temp, power: g.power ? g.power * (0.12 + 0.85 * usage / 100) : null, powerLimit: g.power,
        memUsed: g.mem * (0.3 + 0.6 * usage / 100), memTotal: g.mem, fan: temp != null ? 30 + usage * 0.4 : null, clockMHz: g.power ? 2400 + usage * 3 : null };
    }),
    disks: d.disks.map(k => d.id === 'gaming' && k.name === 'D:' && t < alertUntil ? { ...k, used: k.total * 0.97 } : k),
    net: { rx: 2e5 + Math.random() * 1.5e6, tx: 5e4 + Math.random() * 3e5 }, diskIO: { read: Math.random() * 2e7, write: Math.random() * 1e7 },
    temps: (d.temps || []).map(([name, v]) => ({ name, parent: 'Motherboard', value: v + Math.random() * 2 })),
    fans: (d.fans || []).map(([name, rpm]) => ({ name, rpm: rpm + Math.random() * 30 })),
    ai: d.ai, features: ['procs', 'actions'], actions: d.platform === 'macos' ? [] : ['sleep', 'restart', 'shutdown'], macs: d.mac ? [d.mac] : [] };
}
// Seven days of one-minute history, in the layout the hub imports on start. The DGX has a four-hour
// outage a day ago, the laptop sleeps at night and the living-room PC has been off for three days.
function seed() {
  fs.mkdirSync(path.join(dataDir, 'history'), { recursive: true });
  devs.forEach((d, i) => {
    const lines = [];
    for (let t = Math.floor((started - 7 * 86400e3) / MIN) * MIN; t < started - MIN - (d.gone || 0); t += MIN) {
      if ((d.id === 'spark' && t > started - 30 * 3600e3 && t < started - 26 * 3600e3) || (d.id === 'mbp' && new Date(t).getHours() < 7)) continue;
      const s = sample(d, t, i);
      lines.push(JSON.stringify({ id: d.id, t, ...s, rx: 1e5 + Math.random() * (d.id === 'server' ? 4e6 : 8e5), tx: 4e4 + Math.random() * (d.id === 'server' ? 2e6 : 2e5),
        dr: Math.random() * 3e7, dw: Math.random() * 2e7, cpuMax: Math.min(100, s.cpu + 15), gpuMax: s.gpu, cpuTempMax: s.cpuTemp + 4, gpuTempMax: s.gpuTemp != null ? s.gpuTemp + 3 : null }));
    }
    fs.writeFileSync(path.join(dataDir, 'history', d.id + '.ndjson'), lines.join('\n') + '\n');
  });
  const off = devs.filter(d => d.gone).map(d => [d.id, { id: d.id, name: d.name, hostname: d.name, platform: d.platform, os: d.os, firstSeen: started - 90 * 86400e3,
    lastSeen: started - d.gone, order: 99, hw: { formFactor: d.formFactor, threads: d.cpu.threads }, macs: [d.mac] }]);
  fs.writeFileSync(path.join(dataDir, 'devices.json'), JSON.stringify(Object.fromEntries(off)));
}

(async () => {
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  authority();
  if (!fs.existsSync(path.join(dataDir, 'devices.json'))) seed();
  const hub = await startHub({ fixture: true, publicUrl: origin, tlsOptions: leaf('ec'), port: 0, dataDir, rootDir: path.join(__dirname, '../..') });
  // The hub's own API, as its local operator.
  const api = async (method, resource, body) => (await transport.hubJson('http://127.0.0.1:' + hub.port, resource, { method, token: hub.localKey, body: body && JSON.stringify(body) })).json;
  const invitation = async () => origin + '/mobile#join=' + (await api('POST', '/api/invites', { kind: 'mobile', origin })).code;
  const live = devs.filter(d => !d.gone), paused = new Set();
  const send = d => hub.seedReport(report(d, devs.indexOf(d)));
  const tick = () => { for (const d of live) if (!paused.has(d.id)) { send(d); if (d.reports && !--d.reports) paused.add(d.id); } };
  tick();
  const timer = setInterval(tick, interval);
  await api('PUT', '/api/order', { ids: devs.map(d => d.id) });
  if (!await api('GET', '/api/energy/settings')) await api('PUT', '/api/energy/settings', { region: 'US-CA', rate: 0.316, currency: 'USD' });

  const control = http.createServer(async (req, res) => {
    const reply = (status, body) => { res.writeHead(status, { 'Content-Type': typeof body === 'string' ? 'text/plain; charset=utf-8' : 'application/json', 'Cache-Control': 'no-store' }); res.end(typeof body === 'string' ? body : JSON.stringify(body)); };
    try {
      req.resume();
      // For tools on this machine only: no web page, cross-site or DNS-rebound, may drive the fixture.
      if (req.headers.origin || !/^(127\.0\.0\.1|localhost):\d+$/.test(req.headers.host || '')) return reply(403, { error: 'Loopback tools only.' });
      const url = new URL(req.url, 'http://x'), route = req.method + ' ' + url.pathname, device = /^POST \/device\/([^/]+)\/(offline|online)$/.exec(route);
      if (route === 'GET /invite') return reply(200, await invitation());
      if (route === 'GET /state') return reply(200, { origin, pin, phones: await api('GET', '/api/mobile'), devices: Object.fromEntries(live.map(d => [d.id, paused.has(d.id) ? 'paused' : 'reporting'])) });
      if (route === 'POST /rotate-tls') {
        const previous = pin, type = url.searchParams.get('key');
        if (type && type !== 'ec' && type !== 'rsa') return reply(400, { error: 'key must be ec or rsa' });
        hub.setSecureContext(leaf(type || undefined), !url.searchParams.has('keep'));
        return reply(200, { pin, previous, key: leafType });
      }
      if (route === 'POST /revoke-mobile') {
        const phones = await api('GET', '/api/mobile');
        for (const m of phones) await api('DELETE', '/api/mobile/' + m.id);
        return reply(200, { revoked: phones.length });
      }
      if (device) {
        const d = live.find(x => x.id === device[1]);
        if (!d) return reply(404, { error: 'No such reporting device. Try: ' + live.map(x => x.id).join(', ') });
        if (device[2] === 'offline') paused.add(d.id); else { delete d.reports; paused.delete(d.id); send(d); }
        return reply(200, { id: d.id, state: paused.has(d.id) ? 'paused' : 'reporting' });
      }
      if (route === 'POST /alert') {
        const seconds = Math.max(1, Math.min(600, Number(url.searchParams.get('seconds')) || 8)), d = devs[0];
        if (paused.has(d.id)) return reply(409, { error: d.name + ' is paused. POST /device/' + d.id + '/online first.' });
        alertUntil = Date.now() + seconds * 1000; send(d);
        setTimeout(() => { if (Date.now() >= alertUntil && !paused.has(d.id)) send(d); }, seconds * 1000 + 50).unref();
        return reply(200, { ok: true, device: d.id, seconds });
      }
      reply(404, { error: 'not found' });
    } catch (e) { reply(500, { error: String(e.message || e) }); }
  });
  await new Promise((resolve, reject) => { control.once('error', reject); control.listen(controlPort, '127.0.0.1', resolve); });
  const stop = () => {
    clearInterval(timer); hub.close(); control.close(); control.closeAllConnections();
    for (const dir of temporary.reverse()) fs.rmSync(dir, { recursive: true, force: true });
    process.exit();
  };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
  console.log(JSON.stringify({ origin, ca, invitation: await invitation(), controlPort: control.address().port, pin, dataDir }));
})().catch(e => {
  console.error(e.stderr ? String(e.stderr) : e.stack || e.message);
  for (const dir of temporary.reverse()) fs.rmSync(dir, { recursive: true, force: true });
  process.exit(1);
});
