// Regenerates the certificate and HMAC fixtures in this directory from the hub's own JavaScript,
// so the Swift ports are checked against the code they must interoperate with.
//
//   node ios/Packages/DMCore/Tests/DMCoreTests/Fixtures/transport/generate-fixtures.cjs
//
// Needs the openssl CLI (OpenSSL 3). Only certificates are written; every private key stays in
// a temporary directory that is deleted before the script exits.
'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '../../../../../../..');
const transport = require(path.join(root, 'transport.js'));
const identity = require(path.join(root, 'desktop-identity.js'));

// ---- certificates -----------------------------------------------------------
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-ios-fixtures-'));
const out = path.join(__dirname, 'certs');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out);
const openssl = (...args) => execFileSync('openssl', args, { cwd: work, stdio: ['ignore', 'pipe', 'pipe'] });

const config = path.join(work, 'openssl.cnf');
const writeConfig = extra => fs.writeFileSync(config, [
  '[req]', 'distinguished_name = dn', 'x509_extensions = ext', 'prompt = no',
  '[dn]', 'CN = fixture',
  '[ext]', 'subjectAltName = DNS:hub.test,IP:127.0.0.1', 'basicConstraints = critical,CA:FALSE',
  'keyUsage = critical,digitalSignature', 'extendedKeyUsage = serverAuth', ...extra, '',
].join('\n'));

const keys = {
  'rsa-2048': ['-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048'],
  'rsa-3072': ['-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:3072'],
  'rsa-4096': ['-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:4096'],
  'rsa-pss-2048': ['-algorithm', 'RSA-PSS', '-pkeyopt', 'rsa_keygen_bits:2048'],
  'ec-p256': ['-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256'],
  'ec-p384': ['-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-384'],
  'ec-p521': ['-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-521'],
  'ed25519': ['-algorithm', 'ED25519'],
  'ed448': ['-algorithm', 'ED448'],
};
const rows = [];
function record(name, pemFile, note) {
  const cert = new crypto.X509Certificate(fs.readFileSync(path.join(work, pemFile)));
  const spki = cert.publicKey.export({ type: 'spki', format: 'der' });
  // The Swift side slices these bytes out of the certificate instead of re-encoding the key.
  if (!cert.raw.includes(spki)) throw new Error(name + ': exported SPKI is not a slice of the certificate');
  fs.writeFileSync(path.join(out, name + '.der'), cert.raw);
  rows.push({
    name, file: 'certs/' + name + '.der', note, bytes: cert.raw.length,
    keyType: cert.publicKey.asymmetricKeyType,
    pin: transport.publicKeyPin(cert),
    spki: spki.toString('hex'),
  });
}
writeConfig([]);
for (const [name, args] of Object.entries(keys)) {
  openssl('genpkey', ...args, '-out', name + '.key');
  openssl('req', '-x509', '-new', '-key', name + '.key', '-days', '3650', '-config', config, '-subj', '/CN=' + name + '.fixture', '-out', name + '.pem');
  record(name, name + '.pem', 'self-signed, v3');
}
// X.509 v1: no [0] version field and no extensions in TBSCertificate.
openssl('req', '-new', '-key', 'ec-p256.key', '-config', config, '-subj', '/CN=v1.fixture', '-out', 'v1.csr');
openssl('x509', '-req', '-in', 'v1.csr', '-signkey', 'ec-p256.key', '-days', '3650', '-out', 'v1.pem');
record('v1-ec-p256', 'v1.pem', 'version 1 certificate (no version tag, no extensions)');
// Issued by a CA, with a 20-byte serial number and a long subject.
openssl('req', '-x509', '-new', '-key', 'rsa-2048.key', '-days', '3650', '-subj', '/CN=Fixture Root', '-addext', 'basicConstraints=critical,CA:TRUE', '-out', 'ca.pem');
fs.writeFileSync(path.join(work, 'leaf.ext'), 'subjectAltName = DNS:hub.test,DNS:*.hub.test,IP:127.0.0.1,IP:::1\nextendedKeyUsage = serverAuth\nkeyUsage = critical,digitalSignature\n');
openssl('req', '-new', '-key', 'ec-p384.key', '-subj', '/C=AU/ST=Victoria/L=Melbourne/O=Device Monitor Fixtures/OU=Transport/CN=leaf.hub.test', '-out', 'leaf.csr');
openssl('x509', '-req', '-in', 'leaf.csr', '-CA', 'ca.pem', '-CAkey', 'rsa-2048.key', '-set_serial', '0x' + 'a5'.repeat(20), '-days', '3650', '-extfile', 'leaf.ext', '-out', 'leaf.pem');
record('ca-issued-ec-p384', 'leaf.pem', 'issued by a separate CA, 20-byte serial');
// A certificate above 64 KiB, so its outer lengths use the three-byte long form.
writeConfig(['1.3.6.1.4.1.55555.1 = ASN1:UTF8String:' + 'x'.repeat(70000)]);
openssl('req', '-x509', '-new', '-key', 'ed25519.key', '-days', '3650', '-config', config, '-subj', '/CN=huge.fixture', '-out', 'huge.pem');
record('huge-extension-ed25519', 'huge.pem', '70 kB extension: three-byte DER lengths');
fs.rmSync(work, { recursive: true, force: true });
fs.writeFileSync(path.join(__dirname, 'spki-pins.json'), JSON.stringify(rows, null, 1) + '\n');

// ---- desktop-identity vectors ----------------------------------------------------
// Deterministic "random" material, so regenerating does not churn the fixture.
let counter = 0;
const bytes = n => crypto.createHash('sha512').update('dm-ios-fixture/' + counter++).digest().subarray(0, n);
const secret = () => bytes(32).toString('base64url');
const hex = () => bytes(32).toString('hex');

const tokens = [
  ...Array.from({ length: 12 }, secret),
  '', 'a', 'password', 'ünïcödé', '漢字かな', '😀 emoji', 'line\nbreak', 'nul\u0000byte', ' leading and trailing ',
];
const digests = tokens.map(token => ({ token, digest: identity.credentialDigest(token) }));

const keys2 = [];
for (let i = 0; i < 12; i++) {
  const agent = hex(), client = hex();
  keys2.push({ agent, client, key: identity.desktopKey(agent, client).toString('hex') });
}
// The second secret's digest takes the agent digest's place for a mobile enrollment.
for (let i = 0; i < 6; i++) {
  const proof = secret(), client = secret();
  const a = identity.credentialDigest(proof), c = identity.credentialDigest(client);
  keys2.push({ agent: a, client: c, key: identity.desktopKey(a, c).toString('hex'), proofSecret: proof, clientSecret: client });
}
const good = hex();
for (const [agent, client] of [
  [good.toUpperCase(), good], [good, good.toUpperCase()], [good.slice(1), good], [good, good + '0'],
  ['', good], [good, ''], ['g'.repeat(64), good], [good, ' ' + good.slice(1)], [good.slice(0, 63) + '\n', good],
]) keys2.push({ agent, client, key: identity.desktopKey(agent, client) });   // null: rejected

const awkward = [
  '', ' ', '/', 'https://hub.example/', '"', '\\', '\\"', '"quoted"', 'back\\slash', '</script>',
  '\b\f\n\r\t', '\u0000', '\u0001\u0002\u0003', '\u000b', '\u001f', '\u007f', '\u0080', 'ÿ',
  Array.from({ length: 32 }, (_, i) => String.fromCharCode(i)).join(''),
  'é', 'ünïcödé', '漢字', '😀', 'a😀b', '  ', '﻿', '�', 'é',
  'a'.repeat(300), 'tab\tand\nnewline', '{"json":true}', '[1,2,3]', 'null', "single'quote", '%00%2F', '+/=',
];
const macs = [];
const macRow = (key, role, ...fields) => macs.push({
  key: key.toString('hex'), role, fields, json: JSON.stringify([role, ...fields]), mac: identity.mac(key, role, ...fields),
});
const origins = ['https://hub.example', 'https://127.0.0.1:8443', 'https://[::1]:7443', 'https://my-pc.tailnet-1234.ts.net', 'https://xn--bcher-kva.example:444'];
for (let i = 0; i < 10; i++) {
  const key = identity.desktopKey(hex(), hex()), origin = origins[i % origins.length];
  const nonce = secret(), pin = bytes(32).toString('base64');
  macRow(key, 'lookup');
  macRow(key, 'desktop', origin, nonce);
  macRow(key, 'hub', origin, nonce, pin);
}
const key = identity.desktopKey(hex(), hex());
for (const s of awkward) { macRow(key, s); macRow(key, 'role', s); macRow(key, 'role', s, s, 'tail'); }
macRow(key, 'role', ...awkward);
macRow(bytes(1), 'lookup'); macRow(bytes(64), 'lookup'); macRow(bytes(200), 'hub', 'a', 'b', 'c');

fs.writeFileSync(path.join(__dirname, 'identity-vectors.json'), JSON.stringify({ digests, keys: keys2, macs }, null, 1) + '\n');

// ---- origins and invitations ---------------------------------------------------
// What the desktop's parser makes of each input. The Swift parser is stricter by design, so the
// tests assert one direction: whatever Swift accepts, JavaScript accepts with the same result.
const { validKey } = require(path.join(root, 'access.js'));
const originInputs = [
  'https://hub.example', 'https://hub.example/', 'https://hub.example:8443', 'https://hub.example:8443/', 'https://hub.example:443',
  'https://hub.example:443/', 'HTTPS://HUB.EXAMPLE', 'Https://Hub.Example:7777/', 'https://HUB.example:8443', 'https://127.0.0.1:7443',
  'https://192.168.1.20', 'https://[::1]', 'https://[::1]:8443', 'https://[::1]:443', 'https://[0:0:0:0:0:0:0:1]', 'https://[2001:DB8::1]',
  'https://[2001:db8:0:0:1:0:0:1]', 'https://[2001:0db8:0000:0000:0000:0000:0000:0001]', 'https://[::ffff:192.168.1.5]', 'https://[::]',
  'https://[1::]', 'https://[1:0:0:2:0:0:0:3]', 'https://[1:2:3:4:5:6:7:8]', 'https://[fe80::1%25en0]', 'https://[fe80::1%en0]',
  'https://my-pc.tailnet-1234.ts.net', 'https://xn--bcher-kva.example', 'https://bücher.example', 'https://例え.テスト', 'https://ＨＵＢ.example',
  'https://hub。example', 'https://hub.example​', 'https://ⓗub.example', 'http://hub.example', 'http://127.0.0.1:7777', 'http://localhost:7777',
  'ftp://hub.example', 'wss://hub.example', 'https://user@hub.example', 'https://user:pw@hub.example', 'https://:pw@hub.example',
  'https://@hub.example', 'https://hub.example/path', 'https://hub.example//', 'https://hub.example/?', 'https://hub.example/?q=1',
  'https://hub.example/#', 'https://hub.example/#frag', 'https://hub.example?x', 'https://hub.example#x', 'https://', 'https:///',
  'https://:443', 'https://hub.example:', 'https://hub.example:0', 'https://hub.example:1', 'https://hub.example:65535',
  'https://hub.example:65536', 'https://hub.example:080', 'https://hub.example:8443x', 'https://hub.example:-1', 'https://hub.example:+80',
  'https://hub.example:443:443', 'https://hub_example', 'https://hub.example.', 'https://hub..example', 'https://.hub.example',
  'https://-hub.example', 'https://hub-.example', 'https://1.2.3', 'https://1.2.3.4.5', 'https://0x7f.0.0.1', 'https://017.0.0.1',
  'https://256.1.1.1', 'https://127.1', 'https://2130706433', 'https://1.2.3.04', 'https://127.0.0.1.', 'https://1.1.1.1.example',
  'https://0x.example', 'https://example.0x10', 'https://example.1', 'https://1e3.example', 'https://hub.example\\@evil.example',
  'https://evil.example\\.hub.example', 'https://hub.example\\', 'https://hub.example%2f', 'https://hub%2eexample', 'https://hub.example%00',
  'https://hub .example', ' https://hub.example', 'https://hub.example ', 'https://hub.example\n', 'https://hub\t.example',
  'https://hub\n.example', 'https:hub.example', 'https:/hub.example', 'https:\\\\hub.example', '//hub.example', 'hub.example', '',
  'https://[::1', 'https://::1', 'https://[::1]]', 'https://[:::1]', 'https://[1::2::3]', 'https://[12345::1]', 'https://[::1]:',
  'https://[::1]x', 'https://[::g]', 'https://[1.2.3.4]', 'https://[]', 'https://[:]', 'https://[::ffff:192.168.01.5]', 'https://[1:2:3:4:5:6:7::]',
  'https://[::1.2.3.4]', 'https://[0:0:0:0:0:0:0:0:1]', 'https://[::1%lo0]', 'https://xn--', 'https://xn--a', 'https://xn--a.example',
  'https://' + 'a'.repeat(63) + '.example', 'https://' + 'a'.repeat(64) + '.example', 'https://' + ('a'.repeat(50) + '.').repeat(5) + 'example',
  'https://a', 'https://A', 'https://localhost', 'https://localhost:7443', 'javascript:alert(1)', 'data:text/plain,https://hub.example',
];
const jsOrigin = input => { try { return transport.origin(input); } catch { return null; } };
const originRows = originInputs.map(input => ({ input, origin: jsOrigin(input) }));

// pairWithHub()'s own checks with the mobile path in place of "/pair".
function jsInvitation(link) {
  try {
    const u = new URL(String(link).trim());
    const code = new URLSearchParams(u.hash.slice(1)).get('join');
    if (!transport.origin(u.origin) || u.username || u.password || u.pathname !== '/mobile' || u.search || !validKey(code)) return null;
    return { origin: u.origin, code };
  } catch { return null; }
}
const C = secret(), D = secret(), o = 'https://hub.example';
const invitationInputs = [
  `${o}/mobile#join=${C}`, `${o}:8443/mobile#join=${C}`, `https://[::1]:7443/mobile#join=${C}`, `https://127.0.0.1:7443/mobile#join=${C}`,
  `HTTPS://HUB.EXAMPLE/mobile#join=${C}`, `${o}:443/mobile#join=${C}`, `  ${o}/mobile#join=${C}\n`, `\n\t${o}/mobile#join=${C}  \r\n`,
  `${o}/mobile#join=${C} `, `${o}/pair#join=${C}`, `${o}/unlock#join=${C}`, `http://127.0.0.1:7777/unlock#join=${C}`,
  `http://hub.example/mobile#join=${C}`, `${o}/mobile/#join=${C}`, `${o}//mobile#join=${C}`, `${o}/mobile?x=1#join=${C}`,
  `${o}/mobile?#join=${C}`, `${o}/Mobile#join=${C}`, `${o}/MOBILE#join=${C}`, `${o}/mobile#JOIN=${C}`, `${o}/mobile#join=${C.slice(1)}`,
  `${o}/mobile#join=${C}A`, `${o}/mobile#join=${C.slice(0, 42)}+`, `${o}/mobile#join=${C.slice(0, 42)}/`, `${o}/mobile#join=${C.slice(0, 42)}=`,
  `${o}/mobile#join=${C.slice(0, 42)}%2D`, `${o}/mobile#join=${C.slice(0, 42)}%5F`, `${o}/mobile#join=${C.slice(0, 42)}%`,
  `${o}/mobile#join=${C.slice(0, 42)}%zz`, `${o}/mobile#x=1&join=${C}`, `${o}/mobile#join=${C}&x=1`, `${o}/mobile#join=${C}&join=${D}`,
  `${o}/mobile#join=bad&join=${C}`, `${o}/mobile#&&join=${C}`, `${o}/mobile#?join=${C}`, `${o}/mobile#join%3D${C}`, `${o}/mobile#jo%69n=${C}`,
  `${o}/mobile#join=${C}#extra`, `${o}/mobile##join=${C}`, `${o}/mobile`, `${o}/mobile#`, `${o}/mobile#join`, `${o}/mobile#join=`,
  `${o}/mobile#=${C}`, `user@hub.example/mobile#join=${C}`, `https://user@hub.example/mobile#join=${C}`, `https://user:pw@hub.example/mobile#join=${C}`,
  `mobile#join=${C}`, `/mobile#join=${C}`, `hub.example/mobile#join=${C}`, `${o}/mobile;x#join=${C}`, `${o}/./mobile#join=${C}`,
  `${o}/x/../mobile#join=${C}`, `${o}/%6Dobile#join=${C}`, `${o}\\mobile#join=${C}`, `${o}/mo\tbile#join=${C}`, `${o}/mobile#jo\nin=${C}`,
  `${o}/mobile #join=${C}`, `${o}/mobile# join=${C}`, `${o}/mobile#join= ${C}`, `https://bücher.example/mobile#join=${C}`,
  `https://xn--bcher-kva.example/mobile#join=${C}`, `${o}/mobile​#join=${C}`, `${o}/mobile#join=${C}​`, `${o}./mobile#join=${C}`,
  `https://017.0.0.1/mobile#join=${C}`, `${o}/mobile#join=${'é'.repeat(43)}`, `${C}`, `join=${C}`, `#join=${C}`, '', '   ', 'hello',
  `${o}/mobile#join=${C}\n${o}/mobile#join=${D}`, `${o}/mobile#join=${C}&`, `${o}/mobile#join=${C};x=1`, `${o}/mobilex#join=${C}`,
  `${o}/xmobile#join=${C}`, `${o}/a/mobile#join=${C}`, `${o}:8443/pair#join=${C}`, `${o}/unlock#join=${C}&x=1`,
];
const invitations = invitationInputs.map(input => ({ input, parsed: jsInvitation(input) }));
fs.writeFileSync(path.join(__dirname, 'origin-vectors.json'), JSON.stringify({ origins: originRows, invitations }, null, 1) + '\n');

console.log('wrote ' + rows.length + ' certificates, ' + digests.length + ' digests, ' + keys2.length + ' keys, ' + macs.length + ' MACs, ' +
  originRows.length + ' origins, ' + invitations.length + ' invitations');
