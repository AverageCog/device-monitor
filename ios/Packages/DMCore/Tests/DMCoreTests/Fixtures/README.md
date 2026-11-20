Test fixtures. `models/` holds JSON captured from a real hub (`startHub({ fixture: true })`);
`transport/` holds certificates and HMAC vectors produced by the hub's own JavaScript, so the Swift
ports are checked against the implementation they must interoperate with.
