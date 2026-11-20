Fixtures for the security and transport tests. Everything here is synthetic.

| File | What it is |
|---|---|
| `certs/*.der` | Certificates of every key type a hub may present (RSA 2048/3072/4096, RSA-PSS, EC P-256/P-384/P-521, Ed25519, Ed448), plus an X.509 v1 certificate, a CA-issued leaf and one above 64 KiB. No private keys are kept. |
| `spki-pins.json` | For each certificate, the pin `transport.js` `publicKeyPin()` computes and the SubjectPublicKeyInfo Node exports. |
| `identity-vectors.json` | `credentialDigest`, `desktopKey` and `mac` outputs from `desktop-identity.js`, including the exact `JSON.stringify` text each MAC covers. |
| `origin-vectors.json` | What `transport.js` `origin()` and `pairWithHub()`'s checks (with the mobile path) make of normal and hostile inputs. |
| `generate-fixtures.cjs` | Regenerates all of the above from the hub's own code: `node generate-fixtures.cjs` (needs OpenSSL 3). New keys are generated each time, so commit the whole set together. |
| `e2e-hub.cjs` | Helper process for `TransportE2ETests`: the real hub behind a TLS front with a throwaway CA. |

The end-to-end suite only runs when `DM_HUB_E2E` is the repository root (it needs `node` and `openssl`):

```
cd ios/Packages/DMCore && DM_HUB_E2E="$(git rev-parse --show-toplevel)" swift test --filter TransportE2ETests
```
