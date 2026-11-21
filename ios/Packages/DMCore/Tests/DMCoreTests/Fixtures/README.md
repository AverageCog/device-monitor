Test fixtures. `models/` holds JSON captured from a real hub (`startHub({ fixture: true })`);
`transport/` holds certificates and HMAC vectors produced by the hub's own JavaScript, so the Swift
ports are checked against the implementation they must interoperate with. `presentation/` holds
what the dashboard page itself renders and computes for the same payloads (recorded by running
`public/index.html` and the hub's modules in Node), which the presentation layer must reproduce;
each of its folders has its own README.
