'use strict';
// Pairing the iPhone / iPad app with the hub ("mobile enrollment"), and the QR code that carries
// its invitation. Every hub here is a loopback fixture with synthetic credentials.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { spawn, execFile: execFileCallback } = require('node:child_process');
const execFile = require('node:util').promisify(execFileCallback);
const { startHub } = require('../../server');
const { Access, validKey, localOperatorLink } = require('../../access');
const { desktopKey, mac } = require('../../desktop-identity');
const transport = require('../../transport');
const QR = require('../../public/qr.js');
const root = path.resolve(__dirname, '../..');
const ORIGIN = 'https://hub.test';
const PROXY = {Host:'hub.test','X-Forwarded-For':'192.168.1.10','X-Forwarded-Proto':'https'};
const REFUSED = {error:'Invitation is invalid, expired or already used.'};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const sha = s => crypto.createHash('sha256').update(s).digest('hex');
const secret = () => crypto.randomBytes(32).toString('base64url');
const until = async (probe, ms = 4000) => { for (const end = Date.now() + ms; Date.now() < end;) { const v = await probe(); if (v) return v; await new Promise(ok => setTimeout(ok, 5)); } assert.fail('Timed out waiting for ' + probe); };

function temp(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-mobile-test-')), closers = [];
  t.after(async () => {
    for (const close of closers.splice(0)) await close();
    if (path.dirname(dir) !== path.resolve(os.tmpdir()) || !path.basename(dir).startsWith('dm-mobile-test-')) throw Error('Unsafe test directory');
    fs.rmSync(dir, {recursive:true,force:true,maxRetries:3});
  });
  return {dir,closers};
}
// Phones reach the hub through its HTTPS origin: `remote` is what a local TLS proxy forwards.
async function fixture(t, options = {}, tmp = temp(t)) {
  const h = await startHub({port:0,dataDir:tmp.dir,fixture:true,publicUrl:ORIGIN, ...options});
  let open = true;
  const close = () => { if (open) { open = false; h.close(); } };
  tmp.closers.push(close);
  const base = 'http://127.0.0.1:' + h.port;
  function call(url, {method='GET',key,body,raw,headers={},remote=false}={}) {
    const data = raw !== undefined ? raw : body !== undefined ? JSON.stringify(body) : undefined;
    return new Promise((resolve,reject) => {
      const req = http.request(base + url, {method,agent:false,headers:{ ...(remote ? PROXY : {}), ...(key ? {Authorization:'Bearer '+key} : {}), ...(data !== undefined ? {'Content-Type':'application/json'} : {}), ...headers}}, async res => {
        try { resolve(new Response(await transport.readBytes(res,4e6),{status:res.statusCode,headers:res.headers})); } catch(e) {reject(e);}
      });
      req.on('error',reject); req.end(data);
    });
  }
  const status = async (url, options) => (await call(url, options)).status;
  const reply = async (url, options) => { const r = await call(url, options); return {status:r.status, json:await r.json()}; };
  async function invite(kind, id, dest = ORIGIN, key = h.localKey, remote = false) {
    const r = await call('/api/invites',{method:'POST',key,remote,body:{kind,origin:dest,id}});
    assert.equal(r.status, 200); const {code} = await r.json(); assert.ok(validKey(code)); return code;
  }
  async function enroll(url, kind, extra = {}) {
    const r = await call(url, {method:'POST',remote:true,key:await invite(kind, extra.id), ...(extra.body ? {body:extra.body} : {})});
    assert.equal(r.status, 200); return r.json();
  }
  const phone = name => enroll('/api/mobile/pair', 'mobile', name === undefined ? {} : {body:{name}});
  const desktop = id => enroll('/api/pair', 'desktop', {id});
  // A browser tab signed in with an invitation from `key` (the hub itself unless a paired device shares one).
  async function browser(key = h.localKey, remote = false) {
    const dest = remote ? ORIGIN : base;
    return (await reply('/api/session', {method:'POST',remote,key:await invite('browser', null, dest, key, remote)})).json.token;
  }
  const phones = (key = h.localKey, remote = false) => reply('/api/mobile', {key,remote});
  return {h,base,call,status,reply,invite,phone,desktop,browser,phones,close,dataDir:tmp.dir};
}
// Resolves once the stream answered; for a live one, after its first event (the snapshot).
function openStream(port, key, remote = true) {
  return new Promise((resolve,reject) => {
    const req = http.get({host:'127.0.0.1',port,path:'/api/stream',agent:false,headers:{Authorization:'Bearer '+key, ...(remote ? PROXY : {})}}, res => {
      const closed = new Promise(done => res.once('close', () => done(Date.now()))), events = [], end = () => req.destroy();
      if (res.statusCode !== 200) { res.resume(); return resolve({status:res.statusCode,events,closed,end}); }
      let pending = '';
      res.setEncoding('utf8'); res.on('error', () => {});
      res.on('data', chunk => {
        pending += chunk;
        for (let cut; (cut = pending.indexOf('\n\n')) >= 0; pending = pending.slice(cut + 2)) events.push(JSON.parse(pending.slice(6, cut)));
        if (events.length) resolve({status:200,events,closed,end});
      });
    });
    req.on('error', reject);
  });
}
const closesWithin = (stream, ms) => Promise.race([stream.closed.then(() => true), new Promise(ok => setTimeout(ok, ms, false))]);
const proofKey = e => desktopKey(sha(e.proof ?? e.agent), sha(e.client));
function challenge(key, origin = ORIGIN) {
  const nonce = secret();
  return {nonce,lookup:mac(key,'lookup'),challenge:mac(key,'desktop',origin,nonce)};
}

test('only the hub operator can invite a phone, over HTTPS, and always as a new identity',async t=>{
  const {h,reply,status,base,phone,desktop,browser,dataDir}=await fixture(t,{headlessInvites:true});
  const issue=(key,body={},options={})=>reply('/api/invites',{method:'POST',key,body:{kind:'mobile',origin:ORIGIN, ...body}, ...options});
  const before=Date.now(), made=await issue(h.localKey);
  assert.equal(made.status,200);assert.deepEqual(Object.keys(made.json).sort(),['code','expires','origin']);
  assert.ok(validKey(made.json.code));assert.equal(made.json.origin,ORIGIN);
  assert.ok(made.json.expires>=before+600000 && made.json.expires<=Date.now()+600000);
  const ticket=new URLSearchParams(new URL(localOperatorLink(dataDir,h.port)).hash.slice(1)).get('join');
  const operator=(await reply('/api/session',{method:'POST',key:ticket})).json.token;
  assert.equal((await issue(operator)).status,200);
  const pc=await desktop(), mobile=await phone('Phone');
  const tab=await browser(), shared=await browser(mobile.client,true), viaDesktop=await browser(pc.client,true);
  for(const [key,remote] of [[pc.client,true],[mobile.client,true],[tab,false],[shared,true],[viaDesktop,true]]){
    assert.deepEqual(await issue(key,{},{remote}),{status:403,json:{error:'Create this invitation on the hub.'}});
  }
  // Neither a reporting credential, nor the phone's proof secret, nor an invitation, nor the
  // operator session away from the hub's own loopback address is a dashboard principal at all.
  for(const key of [pc.agent,mobile.proof,made.json.code,operator,undefined]) assert.equal((await issue(key,{},{remote:true})).status,401);
  assert.deepEqual(await issue(h.localKey,{origin:base}),{status:400,json:{error:'Remote enrollment requires HTTPS.'}});
  assert.equal((await issue(h.localKey,{origin:'https://elsewhere.test'})).status,400);
  h.seedReport({id:'tower',hostname:'Tower'});
  for(const id of ['tower',mobile.id,pc.id,'',0,false,{},'x'.repeat(65)]){
    assert.deepEqual(await issue(h.localKey,{id}),{status:400,json:{error:'A phone or tablet always pairs as a new device.'}},JSON.stringify(id));
  }
  assert.equal((await issue(h.localKey,{id:null})).status,200);
  // The paired phone keeps the one invitation a paired desktop may create: a browser tab.
  for(const kind of ['desktop','agent','mobile']) assert.equal(await status('/api/invites',{method:'POST',remote:true,key:mobile.client,body:{kind,origin:ORIGIN}}),403);
  assert.equal(await status('/api/devices',{key:shared,remote:true}),200);
});

test('redeeming yields two independent secrets, stores only their digests and works once',async t=>{
  const {call,reply,invite,dataDir}=await fixture(t);
  const pair=(code,extra={})=>call('/api/mobile/pair',{method:'POST',remote:true,key:code, ...extra});
  const code=await invite('mobile');
  // The loopback HTTP origin never pairs a phone, and the refusal leaves the invitation unspent.
  assert.deepEqual(await reply('/api/mobile/pair',{method:'POST',key:code,body:{name:'Kitchen iPad'}}),{status:403,json:{error:'HTTPS required'}});
  for(const headers of [{'X-Forwarded-Proto':'http'},{'X-Forwarded-For':'203.0.113.1'},{Host:'other.test'}]) assert.ok((await pair(code,{headers})).status>=400);
  for(const method of ['GET','PUT','DELETE']) assert.notEqual((await call('/api/mobile/pair',{method,remote:true,key:code})).status,200);
  const res=await pair(code,{body:{name:'Kitchen iPad'}});
  assert.equal(res.status,200);assert.equal(res.headers.get('cache-control'),'no-store');assert.equal(res.headers.get('set-cookie'),null);
  assert.match(res.headers.get('content-type'),/^application\/json/);
  const paired=await res.json();
  assert.deepEqual(Object.keys(paired).sort(),['client','id','name','proof']);
  assert.match(paired.id,UUID);assert.ok(validKey(paired.client));assert.ok(validKey(paired.proof));
  assert.notEqual(paired.client,paired.proof);assert.equal(paired.name,'Kitchen iPad');
  for(const extra of [{},{body:{name:'Kitchen iPad'}}]){
    const again=await pair(code,extra);assert.equal(again.status,403);assert.deepEqual(await again.json(),REFUSED);
  }
  const text=fs.readFileSync(path.join(dataDir,'access-v2.json'),'utf8'), row=JSON.parse(text).identities[paired.id];
  assert.deepEqual(Object.keys(row).sort(),['client','mobile','proof']);
  assert.equal(row.client,sha(paired.client));assert.equal(row.proof,sha(paired.proof));
  assert.deepEqual(Object.keys(row.mobile).sort(),['created','name']);assert.equal(row.mobile.name,'Kitchen iPad');
  assert.ok(Math.abs(Date.now()-row.mobile.created)<5000);
  for(const raw of [paired.client,paired.proof,code]) assert.ok(!text.includes(raw));
  if(process.platform!=='win32') assert.equal(fs.statSync(path.join(dataDir,'access-v2.json')).mode & 0o777,0o600);
  // Two phones never share an identity or a secret.
  const other=await (await pair(await invite('mobile'))).json();
  assert.notEqual(other.id,paired.id);assert.equal(new Set([paired.client,paired.proof,other.client,other.proof]).size,4);
  let now=Date.now();
  t.mock.method(Date,'now',()=>now);
  const early=await invite('mobile'), late=await invite('mobile');
  now+=599000;assert.equal((await pair(early)).status,200);
  now+=1001;
  const expired=await pair(late);assert.equal(expired.status,403);assert.deepEqual(await expired.json(),REFUSED);
});

test('the access store keeps phones apart from reporting identities and rolls back failed saves',t=>{
  const file=path.join(temp(t).dir,'config.json'), access=new Access({},file), rows=access.config.identities;
  const saved=()=>JSON.parse(fs.readFileSync(path.join(path.dirname(file),'access-v2.json'),'utf8')).identities;
  assert.throws(()=>access.issue('mobile',ORIGIN,'desk-1'),/Invalid enrollment/);
  assert.throws(()=>access.issue('tablet',ORIGIN),/Invalid enrollment/);
  const desk=access.redeem(access.issue('desktop',ORIGIN,'desk-1'),'desktop',ORIGIN);
  const agent=access.redeem(access.issue('agent',ORIGIN,'box-1'),'agent',ORIGIN);
  const phone=access.redeem(access.issue('mobile',ORIGIN),'mobile',ORIGIN,{name:'Phone'});
  // Existing kinds keep their exact record and principal shapes.
  assert.deepEqual(rows['desk-1'],{agent:sha(desk.agent),client:sha(desk.client)});assert.deepEqual(rows['box-1'],{agent:sha(agent.agent)});
  assert.deepEqual(desk,{id:'desk-1',agent:desk.agent,client:desk.client});assert.deepEqual(agent,{id:'box-1',agent:agent.agent});
  assert.deepEqual(access.principal(desk.client),{role:'client',id:'desk-1'});assert.deepEqual(access.principal(desk.agent),{role:'agent',id:'desk-1'});
  assert.deepEqual(access.principal(agent.agent),{role:'agent',id:'box-1'});
  assert.deepEqual(access.principal(phone.client),{role:'client',id:phone.id,mobile:true});
  assert.deepEqual(access.principal(phone.client,true),{role:'client',id:phone.id,mobile:true});
  assert.equal(access.principal(phone.proof),null);assert.equal(access.principal(phone.proof,true),null);
  assert.ok(!access.index.has(sha(phone.proof)));assert.equal([...access.index.values()].filter(v=>v.id===phone.id).length,1);
  const key=desktopKey(sha(phone.proof),sha(phone.client));
  assert.deepEqual(access.desktopKeys.get(mac(key,'lookup')),key);assert.equal(access.desktopKeys.size,2);
  assert.equal(access.isMobile(phone.id),true);
  for(const id of ['desk-1','box-1','missing','__proto__','constructor','toString',undefined,null,7]) assert.equal(access.isMobile(id),false);
  assert.deepEqual(access.mobiles(),[{id:phone.id,name:'Phone',created:rows[phone.id].mobile.created}]);
  // A phone invitation cannot land on an existing identity, nor a device invitation on a phone.
  const forged=access.issue('mobile',ORIGIN);[...access.invites.values()].at(-1).id='desk-1';
  assert.equal(access.redeem(forged,'mobile',ORIGIN),null);assert.deepEqual(access.principal(desk.client),{role:'client',id:'desk-1'});
  for(const kind of ['desktop','agent']) assert.equal(access.redeem(access.issue(kind,ORIGIN,phone.id),kind,ORIGIN),null);
  assert.deepEqual(access.principal(phone.client),{role:'client',id:phone.id,mobile:true});assert.deepEqual(saved()[phone.id],rows[phone.id]);
  // Sessions and invitations shared from the phone belong to it.
  const tab=access.redeem(access.issue('browser',ORIGIN,null,phone.id),'browser',ORIGIN).token, pendingTab=access.issue('browser',ORIGIN,null,phone.id);
  assert.deepEqual(access.principal(tab),{role:'browser',id:phone.id});
  const pending=access.issue('mobile',ORIGIN), snapshot=JSON.stringify(rows), indexed=access.index.size;
  assert.equal(access.invited(pending,'mobile',ORIGIN),true);
  for(const [code,kind,audience] of [[pending,'desktop',ORIGIN],[pending,'mobile','https://other.test'],[secret(),'mobile',ORIGIN],['short','mobile',ORIGIN],[undefined,'mobile',ORIGIN]]) assert.equal(access.invited(code,kind,audience),false);
  t.mock.method(access,'save',()=>{throw new Error('disk full');});
  assert.throws(()=>access.redeem(pending,'mobile',ORIGIN,{name:'Lost'}),/disk full/);
  assert.equal(JSON.stringify(rows),snapshot);assert.equal(access.index.size,indexed);assert.equal(access.desktopKeys.size,2);
  assert.throws(()=>access.revoke(phone.id),/disk full/);
  assert.deepEqual(access.principal(phone.client),{role:'client',id:phone.id,mobile:true});assert.ok(access.desktopKeys.has(mac(key,'lookup')));
  access.save.mock.restore();
  access.revoke(phone.id);
  assert.equal(access.principal(phone.client),null);assert.equal(access.principal(tab),null);assert.equal(access.redeem(pendingTab,'browser',ORIGIN),null);
  assert.ok(!access.desktopKeys.has(mac(key,'lookup')));assert.equal(access.isMobile(phone.id),false);assert.deepEqual(access.mobiles(),[]);
  assert.deepEqual(Object.keys(saved()).sort(),['box-1','desk-1']);
  assert.deepEqual(access.principal(desk.client),{role:'client',id:'desk-1'});
  for(let i=Object.keys(rows).length;i<250;i++) rows['filler-'+i]={agent:sha('filler-'+i)};
  assert.throws(()=>access.redeem(access.issue('mobile',ORIGIN),'mobile',ORIGIN),/Too many enrolled devices/);
});

test('records written by any version load without trusting their contents',t=>{
  const dir=temp(t).dir, s=Array.from({length:10},secret);
  const identities={
    'old-desktop':{agent:sha(s[0]),client:sha(s[1])}, 'old-agent':{agent:sha(s[2])},
    'phone':{client:sha(s[3]),proof:sha(s[4]),mobile:{name:' Hall\u0000 iPad ',created:5}},
    'phone-without-proof':{client:sha(s[5]),mobile:{}},
    // Hand-edited or damaged: a phone row can still never yield a reporting credential.
    'phone-with-agent':{agent:sha(s[6]),client:sha(s[7]),proof:sha(s[8]),mobile:{name:7,created:'yesterday'}},
  };
  fs.writeFileSync(path.join(dir,'access-v2.json'),JSON.stringify({localKey:s[9],identities}));
  const access=new Access({},path.join(dir,'config.json'));
  assert.deepEqual(access.principal(s[0]),{role:'agent',id:'old-desktop'});assert.deepEqual(access.principal(s[1]),{role:'client',id:'old-desktop'});
  assert.deepEqual(access.principal(s[2]),{role:'agent',id:'old-agent'});
  assert.deepEqual(access.principal(s[3]),{role:'client',id:'phone',mobile:true});
  assert.deepEqual(access.principal(s[5]),{role:'client',id:'phone-without-proof',mobile:true});
  assert.deepEqual(access.principal(s[7]),{role:'client',id:'phone-with-agent',mobile:true});
  for(const proofOrAgent of [s[4],s[6],s[8]]) assert.equal(access.principal(proofOrAgent),null);
  assert.deepEqual(access.mobiles(),[{id:'phone-without-proof',name:'iPhone',created:null},{id:'phone-with-agent',name:'iPhone',created:null},{id:'phone',name:'Hall iPad',created:5}]);
  assert.deepEqual([...access.desktopKeys.values()].map(k=>k.toString('hex')).sort(),
    [desktopKey(sha(s[0]),sha(s[1])),desktopKey(sha(s[4]),sha(s[3])),desktopKey(sha(s[8]),sha(s[7]))].map(k=>k.toString('hex')).sort());
  for(const id of ['phone','phone-without-proof','phone-with-agent']) access.revoke(id);
  assert.equal(access.desktopKeys.size,1);assert.equal(access.index.size,3);assert.deepEqual(access.mobiles(),[]);
  // What an earlier hub release does with the same file: a row is { agent?, client? } to it. A phone
  // row has no agent, so that reader sees a dashboard credential and nothing that can report.
  const stored=JSON.parse(fs.readFileSync(path.join(dir,'access-v2.json'),'utf8')).identities;
  assert.deepEqual(stored,{'old-desktop':identities['old-desktop'],'old-agent':identities['old-agent']});
  const fresh=new Access({},path.join(dir,'config.json')), paired=fresh.redeem(fresh.issue('mobile',ORIGIN),'mobile',ORIGIN);
  const row=fresh.config.identities[paired.id];
  assert.equal(row.agent,undefined);assert.match(row.client,/^[0-9a-f]{64}$/);assert.equal(desktopKey(row.agent,row.client),null);
});

test('invitation kinds cannot be confused in either direction',async t=>{
  const {call,status,invite,base,h}=await fixture(t);
  const at=(url,code,method='POST')=>status(url,{method,remote:true,key:code});
  const mobile=await invite('mobile');
  for(const url of ['/api/pair','/api/session']) assert.equal(await at(url,mobile),403);
  for(const url of ['/install.sh','/install.ps1']) assert.equal(await at(url,mobile,'GET'),403);
  // An invitation is no dashboard credential either.
  for(const url of ['/api/devices','/api/mobile','/api/stream']) assert.equal(await at(url,mobile,'GET'),401);
  const codes={desktop:await invite('desktop'),agent:await invite('agent'),browser:await invite('browser'),loopbackBrowser:await invite('browser',null,base)};
  for(const code of Object.values(codes)){
    const r=await call('/api/mobile/pair',{method:'POST',remote:true,key:code,body:{name:'Confused'}});
    assert.equal(r.status,403);assert.deepEqual(await r.json(),REFUSED);
  }
  assert.equal(await at('/api/mobile/pair',h.localKey),403);
  assert.equal(await status('/api/mobile/pair',{method:'POST',remote:true}),403);
  assert.deepEqual((await call('/api/mobile',{key:h.localKey}).then(r=>r.json())),[]);
  // Each invitation is still good for exactly what it was issued for.
  const phone=await call('/api/mobile/pair',{method:'POST',remote:true,key:mobile}).then(r=>r.json());
  assert.deepEqual(Object.keys(phone).sort(),['client','id','name','proof']);
  const desktop=await call('/api/pair',{method:'POST',remote:true,key:codes.desktop}).then(r=>r.json());
  assert.deepEqual(Object.keys(desktop).sort(),['agent','client','id']);
  assert.equal(await at('/install.sh',codes.agent,'GET'),200);
  assert.equal(await at('/api/session',codes.browser),200);
  assert.equal(await status('/api/session',{method:'POST',key:codes.loopbackBrowser}),200);
});

test('a phone views and manages the dashboard, but its secrets can neither report nor enroll',async t=>{
  const {h,call,status,reply,phone,desktop,browser}=await fixture(t);
  h.seedReport({id:'tower',hostname:'Tower',cpu:{usage:12}});h.seedReport({id:'nas',hostname:'NAS'});
  const pc=await desktop(), mobile=await phone('Phone'), as=(key,extra={})=>({key,remote:true, ...extra});
  // The proof secret opens nothing, anywhere.
  for(const url of ['/api/devices','/api/mobile','/api/stream','/api/alerts','/api/history/tower','/api/remote']) assert.equal(await status(url,as(mobile.proof)),401,url);
  for(const [url,method] of [['/api/invites','POST'],['/api/report','POST'],['/api/order','PUT'],['/api/devices/tower','DELETE'],['/api/mobile/'+mobile.id,'DELETE'],['/api/logout','POST']]){
    assert.equal(await status(url,as(mobile.proof,{method,body:{}})),401,url);
  }
  assert.deepEqual((await reply('/api/info',as(mobile.proof))).json,{app:'device-monitor',locked:true});
  const info=(await reply('/api/info',as(mobile.client))).json;
  assert.equal(info.app,'device-monitor');assert.equal(info.canEnroll,false);assert.equal(info.canShare,true);assert.equal(info.origin,ORIGIN);assert.equal(info.localOrigin,null);
  // Same view and the same management a paired desktop has.
  const mine=(await reply('/api/devices',as(mobile.client))).json, theirs=(await reply('/api/devices',as(pc.client))).json;
  assert.deepEqual(mine.map(d=>d.id),['tower','nas']);assert.deepEqual(mine.map(d=>d.id),theirs.map(d=>d.id));
  for(const url of ['/api/alerts','/api/energy/settings','/api/history/tower?range=1h','/api/remote','/api/energy?bounds=0,1']) assert.equal(await status(url,as(mobile.client)),200,url);
  const live=await openStream(h.port,mobile.client);
  try{
    assert.equal(live.status,200);assert.equal(live.events[0].type,'snapshot');assert.deepEqual(live.events[0].devices.map(d=>d.id),['tower','nas']);
    const renamed=await reply('/api/devices/tower',as(mobile.client,{method:'PATCH',body:{name:'Workshop'}}));
    assert.equal(renamed.status,200);assert.equal(renamed.json.name,'Workshop');
    assert.equal(await status('/api/order',as(mobile.client,{method:'PUT',body:{ids:['nas','tower']}})),200);
    assert.ok((await until(()=>live.events.find(e=>e.type==='order'))).order.nas===0);
    assert.equal(live.events.find(e=>e.type==='device').device.name,'Workshop');
    assert.equal(await status('/api/devices/nas',as(mobile.client,{method:'DELETE'})),200);
    assert.equal((await until(()=>live.events.find(e=>e.type==='removed'))).id,'nas');
  }finally{live.end();}
  assert.equal(await status('/api/devices',{key:await browser(mobile.client,true),remote:true}),200);
  // No credential a phone holds is a reporting credential, whatever identity the body claims.
  const before=(await reply('/api/devices',{key:h.localKey})).json;
  for(const key of [mobile.client,mobile.proof]) for(const id of [mobile.id,'tower','brand-new']){
    const r=await reply('/api/report',as(key,{method:'POST',body:{id,hostname:'spoofed',cpu:{usage:99}}}));
    assert.deepEqual(r,{status:401,json:{error:'Re-enroll this agent to obtain a device credential.'}});
  }
  const after=(await reply('/api/devices',{key:h.localKey})).json;
  assert.deepEqual(after.map(d=>[d.id,d.hostname,d.lastSeen]),before.map(d=>[d.id,d.hostname,d.lastSeen]));
  for(const kind of ['desktop','agent','mobile']) assert.equal(await status('/api/invites',as(mobile.client,{method:'POST',body:{kind,origin:ORIGIN}})),403);
  // Hub-only controls stay on the hub.
  assert.equal(await status('/api/sessions/revoke',as(mobile.client,{method:'POST'})),403);
  assert.equal(await status('/api/remote/https',as(mobile.client,{method:'POST',body:{enable:true}})),403);
  assert.equal((await call('/api/remote',as(mobile.client)).then(r=>r.json())).canConfigure,false);
});

async function selfSigned(dir, name) {
  const windowsSSL=path.join(process.env.ProgramFiles||'C:/Program Files','Git','usr','bin','openssl.exe');
  const openssl=process.platform==='win32' && fs.existsSync(windowsSSL)?windowsSSL:'openssl';
  const config=path.join(dir,name+'.cnf'), key=path.join(dir,name+'.key'), cert=path.join(dir,name+'.crt');
  fs.writeFileSync(config,'[req]\ndistinguished_name = dn\nx509_extensions = test\nprompt = no\n[dn]\nCN = synthetic-hub\n[test]\nsubjectAltName = DNS:hub.test\n');
  await execFile(openssl,['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',config,'-keyout',key,'-out',cert],{windowsHide:true});
  return fs.readFileSync(cert);
}
test('a phone verifies the hub across a TLS rotation with its proof secret and nothing else',async t=>{
  const tmp=temp(t), certs=[await selfSigned(tmp.dir,'first'),await selfSigned(tmp.dir,'second')], proxyCertFile=path.join(tmp.dir,'served.pem');
  const pins=certs.map(pem=>transport.publicKeyPin(new crypto.X509Certificate(pem)));
  assert.notEqual(pins[0],pins[1]);
  fs.writeFileSync(proxyCertFile,certs[0]);
  const data=temp(t), {call,reply,phone,desktop,phones,h}=await fixture(t,{proxyCertFile},data);
  const mobile=await phone('Phone'), other=await phone('Other'), pc=await desktop();
  const prove=(body,remote=true)=>reply('/api/desktop/tls-proof',{remote,method:'POST',body});
  const key=proofKey(mobile);
  assert.deepEqual(key,desktopKey(sha(mobile.proof),sha(mobile.client)));
  const first=challenge(key);
  assert.deepEqual(await prove(first),{status:200,json:{proof:mac(key,'hub',ORIGIN,first.nonce,pins[0])}});
  // The hub attests the key it serves now, never one the caller names.
  fs.writeFileSync(proxyCertFile,certs[1]);
  const second=challenge(key), rotated=await prove({...second,pin:pins[0]});
  assert.deepEqual(rotated,{status:200,json:{proof:mac(key,'hub',ORIGIN,second.nonce,pins[1])}});
  assert.notEqual(rotated.json.proof,mac(key,'hub',ORIGIN,second.nonce,pins[0]));
  const wrong=[
    desktopKey(sha(mobile.client),sha(mobile.proof)),   // digests swapped
    desktopKey(sha(mobile.client),sha(mobile.client)),  // the bearer alone is not enough
    desktopKey(sha(other.proof),sha(mobile.client)), desktopKey(sha(mobile.proof),sha(other.client)),
    desktopKey(sha(secret()),sha(mobile.client)), crypto.randomBytes(32),
  ];
  for(const k of wrong) assert.deepEqual(await prove(challenge(k)),{status:403,json:{error:'Desktop proof refused'}});
  const mixed=challenge(key);
  assert.equal((await prove({...mixed,challenge:mac(wrong[0],'desktop',ORIGIN,mixed.nonce)})).status,403);
  assert.equal((await prove({...mixed,nonce:secret()})).status,403);
  assert.equal((await prove(challenge(key,'https://other.test'))).status,403);
  assert.deepEqual(await prove(challenge(key),false),{status:403,json:{error:'HTTPS required'}});
  // The challenge carries no bearer, so it is not a sign of life and cannot authenticate anything.
  assert.deepEqual((await phones()).json.map(m=>m.lastSeen),[null,null]);
  for(const part of Object.values(challenge(key))) assert.equal((await call('/api/devices',{key:part,remote:true})).status,401);
  // An enrolled desktop proves the hub exactly as before, with its agent digest in the same place.
  const dk=desktopKey(sha(pc.agent),sha(pc.client)), third=challenge(dk);
  assert.deepEqual(await prove(third),{status:200,json:{proof:mac(dk,'hub',ORIGIN,third.nonce,pins[1])}});
  assert.equal((await call('/api/mobile/'+mobile.id,{method:'DELETE',key:h.localKey})).status,200);
  assert.equal((await prove(challenge(key))).status,403);
  assert.equal((await prove(challenge(proofKey(other)))).status,200);
});

test('the operator lists every phone and a phone sees only itself',async t=>{
  const {h,call,reply,status,phone,desktop,browser,phones,dataDir}=await fixture(t,{headlessInvites:true});
  const a=await phone('Phone A'), b=await phone('Tablet B'), pc=await desktop();
  const all=await phones();
  assert.equal(all.status,200);assert.deepEqual(all.json.map(m=>[m.id,m.name,m.lastSeen]),[[a.id,'Phone A',null],[b.id,'Tablet B',null]]);
  for(const m of all.json){ assert.deepEqual(Object.keys(m).sort(),['created','id','lastSeen','name']);assert.ok(Math.abs(Date.now()-m.created)<5000); }
  assert.ok(!JSON.stringify(all.json).includes(sha(a.client)) && !JSON.stringify(all.json).includes(sha(a.proof)));
  const ticket=new URLSearchParams(new URL(localOperatorLink(dataDir,h.port)).hash.slice(1)).get('join');
  const operator=(await reply('/api/session',{method:'POST',key:ticket})).json.token;
  assert.deepEqual((await phones(operator)).json,all.json);
  const asked=Date.now(), own=await phones(a.client,true);
  assert.equal(own.status,200);assert.deepEqual(own.json.map(m=>[m.id,m.name]),[[a.id,'Phone A']]);
  assert.ok(own.json[0].lastSeen>=asked && own.json[0].lastSeen<=Date.now());
  assert.deepEqual((await phones()).json.map(m=>m.lastSeen===null),[false,true]);
  const forbidden={status:403,json:{error:'Manage phones and tablets on the hub.'}};
  for(const key of [pc.client,await browser(),await browser(a.client,true),await browser(pc.client,true)]) assert.deepEqual(await phones(key,true),forbidden);
  for(const key of [pc.agent,a.proof,undefined]) assert.equal((await phones(key,true)).status,401);
  // An open stream is one long request: the phone counts as active for as long as it lasts.
  const live=await openStream(h.port,b.client);
  await new Promise(ok=>setTimeout(ok,30));
  const during=Date.now(), seenB=async()=>(await phones()).json.find(m=>m.id===b.id).lastSeen;
  assert.ok(await seenB()>=during);
  live.end();await live.closed;
  // Once it ends, the time stops moving and stays.
  const frozen=await until(async()=>{const one=await seenB();await new Promise(ok=>setTimeout(ok,5));return await seenB()===one && one;});
  assert.ok(frozen>=during && frozen<=Date.now());
  assert.equal(await status('/api/mobile',{method:'POST',key:h.localKey,body:{}}),404);
});

test('removing a phone closes its stream at once and ends everything derived from it',async t=>{
  const {h,call,reply,status,invite,phone,desktop,browser,phones,dataDir}=await fixture(t);
  h.seedReport({id:'tower',hostname:'Tower'});
  const a=await phone('Phone A'), b=await phone('Tablet B'), pc=await desktop();
  const remove=(id,key,remote=true)=>reply('/api/mobile/'+id,{method:'DELETE',key,remote});
  const tab=await browser(a.client,true), unspent=await invite('browser',null,ORIGIN,a.client,true), bTab=await browser(b.client,true);
  const forbidden={status:403,json:{error:'Manage phones and tablets on the hub.'}};
  // Nobody but the operator removes somebody else, and the refusal says nothing about what exists.
  for(const key of [b.client,pc.client,tab,bTab,await browser()]) for(const id of [a.id,'missing',pc.id]) assert.deepEqual(await remove(id,key),forbidden);
  for(const key of [pc.agent,a.proof,b.proof,undefined]) assert.equal((await remove(a.id,key)).status,401);
  for(const id of ['missing',pc.id,'tower','pair','__proto__','constructor','%zz','x'.repeat(65),'a%2Fb','%00']) assert.deepEqual(await remove(id,h.localKey,false),{status:404,json:{error:'not found'}},id);
  assert.equal(await status('/api/devices/'+a.id,{method:'DELETE',key:h.localKey}),404);
  assert.equal(await status('/api/devices',{key:a.client,remote:true}),200);assert.equal(await status('/api/devices',{key:pc.client,remote:true}),200);
  const live=await openStream(h.port,a.client), tabLive=await openStream(h.port,tab), bLive=await openStream(h.port,b.client);
  assert.deepEqual([live.status,tabLive.status,bLive.status],[200,200,200]);
  assert.deepEqual(await remove(a.id,h.localKey,false),{status:200,json:{ok:true}});
  // Well inside the three-second heartbeat that would otherwise be the first chance to notice.
  for(const stream of [live,tabLive]) assert.equal(await closesWithin(stream,1000),true);
  assert.equal(await status('/api/devices',{key:a.client,remote:true}),401);assert.equal(await status('/api/info',{key:a.client,remote:true}),200);
  assert.deepEqual((await reply('/api/info',{key:a.client,remote:true})).json,{app:'device-monitor',locked:true});
  assert.equal((await openStream(h.port,a.client)).status,401);
  assert.equal(await status('/api/devices',{key:tab,remote:true}),401);
  assert.equal(await status('/api/session',{method:'POST',remote:true,key:unspent}),403);
  assert.equal(await status('/api/desktop/tls-proof',{method:'POST',remote:true,body:challenge(proofKey(a))}),403);
  assert.deepEqual((await phones()).json.map(m=>m.id),[b.id]);
  assert.ok(!Object.hasOwn(JSON.parse(fs.readFileSync(path.join(dataDir,'access-v2.json'),'utf8')).identities,a.id));
  assert.deepEqual(await remove(a.id,h.localKey,false),{status:404,json:{error:'not found'}});
  assert.deepEqual(await remove(a.id,a.client),{status:401,json:{error:'Open a fresh dashboard invitation.'}});
  // The other phone, its shared tab and the desktop are untouched.
  assert.equal(await status('/api/devices',{key:b.client,remote:true}),200);assert.equal(await status('/api/devices',{key:bTab,remote:true}),200);
  assert.equal(await status('/api/devices',{key:pc.client,remote:true}),200);
  assert.equal(await closesWithin(bLive,100),false);
  // "Disconnect" in the app: the phone removes itself.
  assert.deepEqual(await remove(b.id,b.client),{status:200,json:{ok:true}});
  assert.equal(await closesWithin(bLive,1000),true);
  assert.equal(await status('/api/devices',{key:b.client,remote:true}),401);assert.equal(await status('/api/devices',{key:bTab,remote:true}),401);
  assert.equal((await remove(b.id,b.client)).status,401);
  assert.deepEqual((await phones()).json,[]);
  assert.equal(await status('/api/devices',{key:pc.client,remote:true}),200);
  // A fresh pairing starts with no history of the removed one.
  const again=await phone('Phone A');
  assert.notEqual(again.id,a.id);assert.deepEqual((await phones()).json.map(m=>[m.name,m.lastSeen]),[['Phone A',null]]);
});

test('phones stay paired across a hub restart',async t=>{
  const tmp=temp(t);
  let hub=await fixture(t,{},tmp);
  const mobile=await hub.phone('Hall iPad'), pc=await hub.desktop();
  assert.equal(await hub.status('/api/devices',{key:mobile.client,remote:true}),200);
  const before=(await hub.phones()).json, records=fs.readFileSync(path.join(tmp.dir,'access-v2.json'),'utf8');
  hub.close();
  hub=await fixture(t,{},tmp);
  assert.equal(fs.readFileSync(path.join(tmp.dir,'access-v2.json'),'utf8'),records);
  assert.deepEqual((await hub.phones()).json,[{...before[0],lastSeen:null}]);
  assert.equal(await hub.status('/api/devices',{key:mobile.client,remote:true}),200);
  assert.equal(await hub.status('/api/devices',{key:mobile.proof,remote:true}),401);
  assert.equal(await hub.status('/api/devices',{key:pc.client,remote:true}),200);
  assert.equal(await hub.status('/api/report',{method:'POST',remote:true,key:pc.agent,body:{id:pc.id,hostname:'desk'}}),200);
  assert.equal(typeof (await hub.phones()).json[0].lastSeen,'number');
  // Both proof keys were rebuilt from the stored digests (503: accepted, but this fixture serves no TLS to attest).
  for(const e of [mobile,pc]) assert.equal(await hub.status('/api/desktop/tls-proof',{method:'POST',remote:true,body:challenge(proofKey(e))}),503);
  assert.equal(await hub.status('/api/desktop/tls-proof',{method:'POST',remote:true,body:challenge(desktopKey(sha(mobile.client),sha(mobile.proof)))}),403);
  assert.equal(await hub.status('/api/mobile/'+mobile.id,{method:'DELETE',remote:true,key:mobile.client}),200);
  hub.close();
  hub=await fixture(t,{},tmp);
  assert.deepEqual((await hub.phones()).json,[]);
  assert.equal(await hub.status('/api/devices',{key:mobile.client,remote:true}),401);
  assert.equal(await hub.status('/api/devices',{key:pc.client,remote:true}),200);
});

test('phone names are cleaned, capped and default to iPhone; the body is bounded',async t=>{
  const {h,call,reply,invite,phones}=await fixture(t);
  const pair=(code,extra)=>reply('/api/mobile/pair',{method:'POST',remote:true,key:code, ...extra});
  const cases=[
    ['  Matt\u2019s iPhone \n','Matt\u2019s iPhone'],['a\u0000b\u001fc\u007fd\te','abcde'],['x'.repeat(200),'x'.repeat(60)],
    ['<img src=x onerror=alert(1)>','<img src=x onerror=alert(1)>'],['\ud83d\udcf1 B\u00fcro','\ud83d\udcf1 B\u00fcro'],
    // Sixty UTF-16 units would end inside the last emoji: the name stays well-formed text.
    ['y'.repeat(59)+'\ud83d\udcf1','y'.repeat(59)],['lone \ud83d surrogate','lone \ufffd surrogate'],
    ['','iPhone'],[' \t\n ','iPhone'],['\u0000','iPhone'],[42,'iPhone'],[null,'iPhone'],[true,'iPhone'],[{a:1},'iPhone'],[['iPad'],'iPhone'],
  ];
  const expected=[];
  for(const [name,stored] of cases){
    const r=await pair(await invite('mobile'),{body:{name}});
    assert.equal(r.status,200);assert.equal(r.json.name,stored,JSON.stringify(name));expected.push(stored);
  }
  for(const raw of [undefined,'','{}','null','[]','"iPad"','7','{"label":"iPad"}']){
    const r=await pair(await invite('mobile'),{raw});
    assert.equal(r.status,200);assert.equal(r.json.name,'iPhone',String(raw));expected.push('iPhone');
  }
  assert.deepEqual((await phones()).json.map(m=>m.name),expected);
  assert.ok((await phones()).json.every(m=>m.name===m.name.toWellFormed() && m.name.length<=60));
  // A bad body costs the caller nothing but the request: the invitation stays good.
  const code=await invite('mobile');
  assert.equal((await pair(code,{raw:'{"name":'})).status,400);
  assert.equal((await pair(code,{body:{name:'n',padding:'p'.repeat(1100)}})).status,413);
  assert.equal((await call('/api/mobile/pair',{method:'POST',remote:true,key:code,raw:'{"name":"'+'q'.repeat(1100)+'"}',headers:{'Transfer-Encoding':'chunked'}})).status,400);
  assert.deepEqual((await pair(code,{body:{name:'Fine'}})).json.name,'Fine');
  // Without a live invitation the hub answers before any body arrives.
  const early=await new Promise((resolve,reject)=>{
    const req=http.request({host:'127.0.0.1',port:h.port,path:'/api/mobile/pair',method:'POST',timeout:2000,headers:{...PROXY,Authorization:'Bearer '+code,'Content-Length':900}},res=>{res.resume();resolve(res.statusCode);req.destroy();});
    req.on('error',reject);req.on('timeout',()=>req.destroy(Error('Server awaited an unauthenticated body')));req.flushHeaders();
  });
  assert.equal(early,403);
});

test('an existing desktop enrollment behaves exactly as before beside phones',async t=>{
  const {h,call,status,reply,invite,phone,desktop,phones,dataDir}=await fixture(t);
  const mobile=await phone('Phone'), pc=await desktop();
  const records=()=>JSON.parse(fs.readFileSync(path.join(dataDir,'access-v2.json'),'utf8')).identities;
  assert.deepEqual(records()[pc.id],{agent:sha(pc.agent),client:sha(pc.client)});assert.deepEqual(Object.keys(pc).sort(),['agent','client','id']);
  assert.equal(await status('/api/report',{method:'POST',remote:true,key:pc.agent,body:{id:pc.id,hostname:'Desk'}}),200);
  assert.equal(await status('/api/report',{method:'POST',remote:true,key:pc.client,body:{id:pc.id}}),401);
  assert.equal(await status('/api/devices',{key:pc.client,remote:true}),200);assert.equal(await status('/api/devices',{key:pc.agent,remote:true}),401);
  assert.deepEqual((await phones()).json.map(m=>m.id),[mobile.id]);
  // Reconnect rotates the desktop in place; the phone and its record are not involved.
  const phoneRow=JSON.stringify(records()[mobile.id]);
  const replacement=await call('/api/pair',{method:'POST',remote:true,key:await invite('desktop',pc.id)}).then(r=>r.json());
  assert.equal(replacement.id,pc.id);assert.equal(await status('/api/devices',{key:pc.client,remote:true}),401);assert.equal(await status('/api/devices',{key:replacement.client,remote:true}),200);
  assert.equal(JSON.stringify(records()[mobile.id]),phoneRow);assert.equal(await status('/api/devices',{key:mobile.client,remote:true}),200);
  // A phone may remove a device from the dashboard, as a desktop may. That revokes the device, not the phone.
  assert.equal(await status('/api/devices/'+pc.id,{method:'DELETE',remote:true,key:mobile.client}),200);
  assert.equal(await status('/api/devices',{key:replacement.client,remote:true}),401);assert.equal(await status('/api/devices',{key:mobile.client,remote:true}),200);
  assert.deepEqual(Object.keys(records()),[mobile.id]);
  assert.deepEqual((await reply('/api/info',{key:h.localKey})).json.canEnroll,true);
});

test('the hub serves the phone landing text and the encoder, and the dashboard loads it under its nonce',async t=>{
  const {call}=await fixture(t);
  for(const remote of [true,false]){
    const landing=await call('/mobile',{remote});
    assert.equal(landing.status,200);assert.match(landing.headers.get('content-type'),/^text\/plain/);
    const text=await landing.text();assert.match(text,/Device Monitor app/);assert.match(text,/Scan invitation/);
  }
  assert.equal((await call('/mobile',{method:'POST',remote:true})).status,401);
  const script=await call('/qr.js',{remote:true});
  assert.equal(script.status,200);assert.match(script.headers.get('content-type'),/^text\/javascript/);assert.equal(script.headers.get('x-content-type-options'),'nosniff');
  assert.equal(await script.text(),fs.readFileSync(path.join(root,'public/qr.js'),'utf8'));
  const page=await call('/'), html=await page.text(), nonce=/script-src 'nonce-([^']+)'/.exec(page.headers.get('content-security-policy'))[1];
  assert.ok(html.includes('<script nonce="'+nonce+'" src="/qr.js"></script>'));
  assert.match(html,/<button data-os="mobile">iPhone \/ iPad app<\/button>/);
  // The desktop app serves the same page from its own bundle, so it must serve the encoder too.
  assert.match(fs.readFileSync(path.join(root,'main.js'),'utf8'),/u\.pathname === '\/qr\.js'.*public','qr\.js'/);
  assert.ok(JSON.parse(fs.readFileSync(path.join(root,'package.json'),'utf8')).build.files.includes('public/**'));
});

// ---- The add-device dialog, driven against a real hub with a stand-in for the DOM ----
function dialog(t, hubFetch) {
  // A Windows checkout has CRLF line endings.
  const html=fs.readFileSync(path.join(root,'public/index.html'),'utf8').replace(/\r/g,''), code=/<script>\n([\s\S]*)<\/script>/.exec(html)[1];
  new vm.Script(code,{filename:'index.html'});   // the whole page script still parses
  const section=code.slice(code.indexOf('// ---------- add device dialog ----------'),code.indexOf('// ---------- card chart range'));
  assert.ok(section.length>2000);
  const elements=new Map(), drawn=[];
  const element=id=>{
    if(!elements.has(id)) elements.set(id,{id,textContent:'',innerHTML:'',hidden:/\shidden[\s>]/.test(new RegExp('<[a-z]+[^>]* id="'+id+'"[^>]*>').exec(html)[0]),disabled:false,style:{},dataset:{},options:[],listeners:{},
      classList:{toggle(){}}, get value(){return this.options[0]?.value||'';}, add(o){this.options.push(o);}, replaceChildren(...o){this.options=o;},
      addEventListener(type,fn){this.listeners[type]=fn;}, showModal(){this.open=true;}, close(){this.open=false;this.listeners.close?.();},
      getContext(){return {fillStyle:'',fillRect(x,y,w,h){drawn.push([this.fillStyle,x,y,w,h]);}};},
      get children(){return this.id==='osTabs'?['win','app','linux','mobile'].map(tab):[];},
    });
    return elements.get(id);
  };
  const tabs=new Map(), tab=os=>tabs.get(os)||tabs.set(os,{dataset:{os},classList:{toggle(){}}}).get(os);
  const timers=new Set();
  const context=vm.createContext({URL,console,hubFetch,QR,info:null,devices:new Map(),answers:[],asked:[],
    $:selector=>{assert.match(selector,/^#\w+$/);assert.ok(html.includes(' id="'+selector.slice(1)+'"'),'the page has no '+selector);return element(selector.slice(1));},
    Option:function(text,value){this.text=text;this.value=value;},
    confirm:message=>{context.asked.push(message);return context.answers.shift()===true;},
    setTimeout:(fn,ms)=>{const timer=setTimeout(()=>{timers.delete(timer);fn();},ms);timer.unref();timers.add(timer);return timer;},
    clearTimeout:timer=>{clearTimeout(timer);timers.delete(timer);},
    navigator:{},document:{},
  });
  context.window=context;context.devicePixelRatio=2;
  vm.runInContext(/^const esc = .*$/m.exec(code)[0]+'\n'+/^function ago\(ms\) \{[\s\S]*?^\}/m.exec(code)[0]+'\n'+section,context,{filename:'index.html#add-device'});
  t.after(()=>{element('addDlg').close();for(const timer of timers)clearTimeout(timer);});
  return {element,drawn,timers,context,
    open:()=>element('addBtn').listeners.click(),
    choose:os=>element('osTabs').listeners.click({target:{closest:()=>tab(os)}}),
    poll:()=>vm.runInContext('loadPhones(invitationRequest)',context),
    clickPhone:id=>element('phoneList').listeners.click({target:{closest:()=>id==null?null:{dataset:{id},disabled:false}}}),
  };
}
// A hubFetch that can hold one answer back, so a test can act while the page still waits for it.
// `busy` counts what the page is waiting for. Between two macrotasks every continuation of the page
// has run, so that is where the count is read: 0 there means nothing is left to arrive or to act on.
function held(fetch) {
  const holds=new Set(); let busy=0;
  const track=async work=>{busy++;try{return await work;}finally{busy--;}};
  const between=probe=>new Promise(ok=>setImmediate(ok)).then(()=>until(probe));
  return {
    fetch:(resource,options={})=>track((async()=>{
      const res=await fetch(resource,options), request=(options.method||'GET')+' '+resource+' '+(options.body||'');
      for(const hold of holds) if(hold.request.test(request)){holds.delete(hold);hold.waiting=true;await hold.released;break;}
      const json=res.json.bind(res);res.json=()=>track(json());   // reading an answer is part of taking it in
      return res;
    })()),
    // Holds the next answer to a matching request until release().
    hold(request){const hold={request,waiting:false};hold.released=new Promise(ok=>hold.release=ok);holds.add(hold);return hold;},
    parked:hold=>between(()=>hold.waiting&&busy===1),   // the held answer is all the page still waits for
    settled:()=>between(()=>busy===0),
  };
}
test('the add-device dialog pairs a phone by QR code, lists it and removes it',async t=>{
  const {h,call,status,phone,desktop}=await fixture(t);
  const fetchAs=(key,remote)=>(resource,options={})=>call(resource,{key,remote,method:options.method,raw:options.body});
  const ui=dialog(t,fetchAs(h.localKey,false)), {element}=ui;
  await ui.open();
  assert.deepEqual(element('hubSel').options.map(o=>o.value),[ORIGIN,'http://127.0.0.1:'+h.port]);
  assert.match(element('cmd').textContent,/^irm .*\/install\.ps1' \| iex$/);assert.equal(element('mobileRow').hidden,true);assert.equal(element('enrollRow').hidden,false);
  assert.equal(element('phoneList').hidden,true);assert.equal(element('pairRow').hidden,true);
  ui.choose('mobile');
  const link=await until(()=>element('mobileCode').textContent);
  assert.match(link,/^https:\/\/hub\.test\/mobile#join=[A-Za-z0-9_-]{43}$/);
  assert.equal(element('mobileRow').hidden,false);assert.equal(element('enrollRow').hidden,true);assert.equal(element('cmdRow').style.display,'none');
  assert.equal(element('pairRow').hidden,true);assert.equal(element('phoneList').hidden,false);assert.equal(element('cmdHint').textContent,'');
  assert.equal(element('cmd').textContent,'');assert.equal(element('pairCode').textContent,'');
  assert.match(element('viewUrl').textContent,/^https:\/\/hub\.test\/unlock#join=/);
  assert.match(element('phoneList').innerHTML,/^<h4>Paired phones and tablets<\/h4><div class="hint">No phone or tablet is paired yet\.<\/div>$/);
  // What was painted is the invitation: white first, a four-module quiet zone, whole device pixels, about 220 CSS px.
  const canvas=element('mobileQr'), expected=QR.encode(link), n=expected.size+8, k=canvas.width/n;
  assert.equal(canvas.hidden,false);assert.equal(canvas.height,canvas.width);assert.ok(Number.isInteger(k) && k>=4);
  assert.equal(canvas.style.width,canvas.width/2+'px');assert.ok(canvas.width/2<=220 && canvas.width/2>180);
  assert.deepEqual(ui.drawn[0],['#fff',0,0,n*k,n*k]);
  const painted=new Uint8Array(expected.size**2);
  for(const [color,x,y,w,hh] of ui.drawn.slice(1)){ assert.equal(color,'#000');assert.deepEqual([w,hh],[k,k]);painted[(y/k-4)*expected.size+(x/k-4)]=1; }
  assert.deepEqual(painted,expected.modules);
  // The app redeems it; the dialog notices, retires the spent code and lists the phone, escaped.
  const name='<img src=x onerror=alert(1)> & "Matt\'s"';
  const paired=await call('/api/mobile/pair',{method:'POST',remote:true,key:new URL(link).hash.slice(6),body:{name}}).then(r=>r.json());
  assert.equal(await status('/api/devices',{key:paired.client,remote:true}),200);
  await ui.poll();
  assert.equal(element('mobileRow').hidden,true);assert.equal(element('mobileCode').textContent,'');
  assert.equal(element('cmdHint').textContent,'\u201c'+name.slice(0,60)+'\u201d is paired. Choose iPhone / iPad app again to pair another device.');
  const rows=element('phoneList').innerHTML;
  assert.ok(rows.includes('&lt;img src=x onerror=alert(1)&gt; &amp; &quot;Matt&#39;s&quot;'));assert.ok(!rows.includes('<img'));
  assert.ok(rows.includes('<button class="btn" data-id="'+paired.id+'">Remove</button>'));assert.match(rows,/Paired [^<]+ · active now</);
  // Declining the confirmation removes nothing; accepting signs the phone out.
  await ui.clickPhone(null);await ui.clickPhone('unknown');assert.deepEqual(ui.context.asked,[]);
  await ui.clickPhone(paired.id);
  assert.equal(ui.context.asked.length,1);assert.ok(ui.context.asked[0].includes(name.slice(0,60)));
  assert.equal(await status('/api/devices',{key:paired.client,remote:true}),200);
  ui.context.answers.push(true);await ui.clickPhone(paired.id);
  assert.equal(await status('/api/devices',{key:paired.client,remote:true}),401);
  await until(()=>element('phoneList').innerHTML.includes('No phone or tablet is paired yet.'));
  // Choosing the tab again issues a fresh code; a phone paired earlier is not mistaken for a new one.
  const earlier=await phone('Earlier');
  ui.choose('mobile');
  const second=await until(()=>element('mobileCode').textContent);
  assert.notEqual(second,link);await ui.poll();assert.equal(element('mobileRow').hidden,false);
  assert.match(element('phoneList').innerHTML,/Earlier<\/div><div class="set-v hint">Paired [^<]* · not seen since the hub started</);
  // Changing tabs at once leaves only the tab chosen last on screen (the next test leaves mid-request).
  ui.choose('mobile');ui.choose('app');
  assert.match(await until(()=>element('pairCode').textContent),/^https:\/\/hub\.test\/pair#join=/);
  await new Promise(ok=>setTimeout(ok,50));
  assert.equal(element('mobileRow').hidden,true);assert.equal(element('mobileCode').textContent,'');assert.equal(element('phoneList').hidden,true);
  assert.equal(element('enrollRow').hidden,false);assert.equal(element('pairRow').hidden,false);
  // Phones pair through HTTPS only: with the loopback address selected there is a hint, not a code.
  element('hubSel').options.reverse();ui.choose('mobile');
  await until(()=>element('cmdHint').textContent.startsWith('Choose the hub\u2019s HTTPS address above.'));
  assert.equal(element('mobileRow').hidden,true);assert.equal(element('phoneList').hidden,false);
  // Closing the dialog stops the list refresh.
  element('addDlg').close();assert.equal(ui.timers.size,0);
  await new Promise(ok=>setTimeout(ok,30));assert.equal(ui.timers.size,0);
  // A paired desktop can share a browser link but neither invite nor manage phones.
  const pc=await desktop(), guest=dialog(t,fetchAs(pc.client,true));
  await guest.open();guest.choose('mobile');
  await until(()=>guest.element('cmdHint').textContent.startsWith('Create device enrollments on the hub.'));
  assert.equal(guest.element('mobileRow').hidden,true);assert.equal(guest.element('phoneList').hidden,true);assert.equal(guest.element('mobileCode').textContent,'');
  assert.match(guest.element('viewUrl').textContent,/^https:\/\/hub\.test\/unlock#join=/);assert.equal(guest.timers.size,0);
  void earlier;
});
test('an answer that arrives after the phone tab was left changes nothing on screen',async t=>{
  const {h,call}=await fixture(t);
  const gate=held((resource,options={})=>call(resource,{key:h.localKey,method:options.method,raw:options.body})), ui=dialog(t,gate.fetch), {element}=ui;
  const shown=due=>[due,...['viewUrl','pairCode','pairHint','mobileCode','cmd','cmdHint'].map(id=>element(id).textContent),
    ...['mobileRow','phoneList','pairRow','enrollRow'].map(id=>element(id).hidden),element('phoneList').innerHTML,element('cmdRow').style.display,ui.drawn.length,ui.timers.size];
  await ui.open();
  // The phone tab waits for the hub three times. Whichever answer is still due when the tab is left, the
  // rest of that request must neither paint into the tab chosen since nor keep the phone list refreshing.
  for(const [due,request] of [['browser link',/^POST \/api\/invites .*"kind":"browser"/],['paired list',/^GET \/api\/mobile /],['phone invitation',/^POST \/api\/invites .*"kind":"mobile"/]]){
    await gate.settled();
    const hold=gate.hold(request);
    ui.choose('mobile');await gate.parked(hold);
    ui.choose('app');
    assert.match(await until(()=>element('pairCode').textContent),/^https:\/\/hub\.test\/pair#join=[A-Za-z0-9_-]{43}$/);
    const before=shown(due);
    hold.release();await gate.settled();
    assert.equal(element('mobileRow').hidden,true,due);assert.equal(element('mobileCode').textContent,'',due);assert.equal(element('phoneList').hidden,true,due);
    assert.equal(ui.drawn.length,0,due);assert.equal(ui.timers.size,0,due);
    assert.deepEqual(shown(due),before);
  }
  // Left alone, the same request does show its code, so the checks above were not passing on a dead page.
  ui.choose('mobile');
  assert.match(await until(()=>element('mobileCode').textContent),/^https:\/\/hub\.test\/mobile#join=[A-Za-z0-9_-]{43}$/);
  assert.equal(element('mobileRow').hidden,false);assert.ok(ui.drawn.length>1);assert.equal(ui.timers.size,1);
});
test('without an HTTPS address the phone tab explains what to enable first',async t=>{
  const {h,call}=await fixture(t,{publicUrl:null});
  const ui=dialog(t,(resource,options={})=>call(resource,{key:h.localKey,method:options.method,raw:options.body})), {element}=ui;
  await ui.open();ui.choose('mobile');
  await until(()=>element('viewUrl').textContent && element('phoneList').innerHTML);
  await new Promise(ok=>setTimeout(ok,30));
  assert.match(element('cmdHint').textContent,/^The iPhone and iPad app pairs through the hub\u2019s HTTPS address\. Enable Tailscale HTTPS/);
  assert.equal(element('enableHttps').hidden,false);assert.equal(element('mobileRow').hidden,true);assert.equal(element('mobileCode').textContent,'');
  assert.equal(element('phoneList').hidden,false);assert.match(element('phoneList').innerHTML,/No phone or tablet is paired yet/);
  assert.equal((await call('/api/invites',{method:'POST',key:h.localKey,body:{kind:'mobile',origin:'http://127.0.0.1:'+h.port}})).status,400);
});

// ---- build/test/mobile-hub.js, the hub the iOS Simulator tests run against ----
test('the simulator fixture hub pairs over real TLS, proves a rotated key and obeys its control port',async t=>{
  const tmp=temp(t), reservation=net.createServer();
  await new Promise(ok=>reservation.listen(0,'127.0.0.1',ok));
  const port=reservation.address().port;await new Promise(ok=>reservation.close(ok));
  const child=spawn(process.execPath,[path.join(__dirname,'mobile-hub.js'),'--port',String(port),'--control','0','--dir',tmp.dir,'--interval','100'],{stdio:['ignore','pipe','pipe'],windowsHide:true});
  tmp.closers.push(()=>child.exitCode!==null||new Promise(ok=>{child.once('exit',ok);child.kill();}));
  let out='', err='';
  child.stderr.on('data',c=>{err+=c;});
  const line=await new Promise((ok,no)=>{
    child.stdout.on('data',c=>{out+=c;if(out.includes('\n'))ok(out.slice(0,out.indexOf('\n')));});
    child.once('exit',code=>no(Error('The fixture hub exited with '+code+': '+err)));
  });
  const ready=JSON.parse(line), origin='https://localhost:'+port, control='http://127.0.0.1:'+ready.controlPort;
  assert.deepEqual(Object.keys(ready).sort(),['ca','controlPort','dataDir','invitation','origin','pin']);
  assert.equal(ready.origin,origin);assert.equal(ready.ca,path.join(tmp.dir,'ca.pem'));
  assert.match(ready.invitation,new RegExp('^https://localhost:'+port+'/mobile#join=[A-Za-z0-9_-]{43}$'));
  const caPem=fs.readFileSync(ready.ca), authority=new crypto.X509Certificate(caPem);
  assert.equal(authority.ca,true);
  if(process.platform!=='win32') assert.equal(fs.statSync(path.join(tmp.dir,'ca.key')).mode & 0o777,0o600);
  const tls=(resource,{method='GET',key,body}={})=>new Promise((resolve,reject)=>{
    const data=body===undefined?undefined:JSON.stringify(body);
    const req=https.request(origin+resource,{method,agent:false,ca:caPem,headers:{...(key?{Authorization:'Bearer '+key}:{}),...(data?{'Content-Type':'application/json'}:{})}},async res=>{
      try{
        const served=res.socket.getPeerX509Certificate(), text=(await transport.readBytes(res,8e6)).toString();
        resolve({status:res.statusCode,served,pin:transport.publicKeyPin(served),json:/json/.test(res.headers['content-type'])?JSON.parse(text):text});
      }catch(e){reject(e);}
    });
    req.on('error',reject);req.end(data);
  });
  const ctl=(resource,method='POST',headers={})=>new Promise((resolve,reject)=>{
    http.request(control+resource,{method,agent:false,headers},res=>{let s='';res.on('data',c=>{s+=c;}).on('end',()=>resolve({status:res.statusCode,body:/json/.test(res.headers['content-type'])?JSON.parse(s):s}));}).on('error',reject).end();
  });
  // A certificate the Simulator accepts once ca.pem is trusted: issued by that CA for localhost, serverAuth, under 398 days.
  const probe=await tls('/api/info'), leaf=probe.served;
  assert.deepEqual(probe.json,{app:'device-monitor',locked:true});assert.equal(probe.pin,ready.pin);
  assert.equal(leaf.checkIssued(authority),true);assert.equal(leaf.verify(authority.publicKey),true);assert.equal(leaf.ca,false);
  assert.equal(leaf.checkHost('localhost'),'localhost');assert.equal(leaf.checkIP('127.0.0.1'),'127.0.0.1');
  assert.ok(leaf.keyUsage.includes('1.3.6.1.5.5.7.3.1'));assert.ok(Date.parse(leaf.validTo)-Date.parse(leaf.validFrom)<398*86400e3);
  assert.equal(leaf.publicKey.asymmetricKeyType,'ec');
  await assert.rejects(new Promise((ok,no)=>https.get(origin+'/api/info',{agent:false},ok).on('error',no)),/certificate|issuer/i);
  assert.match((await tls('/mobile')).json,/Device Monitor app/);
  // The app's side of pairing, then everything it shows.
  const paired=await tls('/api/mobile/pair',{method:'POST',key:new URL(ready.invitation).hash.slice(6),body:{name:'Simulator'}});
  assert.equal(paired.status,200);assert.deepEqual(Object.keys(paired.json).sort(),['client','id','name','proof']);
  const key=paired.json.client, devices=(await tls('/api/devices',{key})).json, by=Object.fromEntries(devices.map(d=>[d.id,d]));
  assert.deepEqual(devices.map(d=>d.id).sort(),['gaming','htpc','mbp','nas','server','spark','studio']);
  assert.deepEqual(devices.filter(d=>!d.online).map(d=>d.id),['htpc']);assert.equal(by.htpc.latest,null);assert.equal(by.htpc.macs.length,1);
  assert.deepEqual([...devices].sort((a,b)=>a.order-b.order).map(d=>d.id),['gaming','spark','mbp','server','studio','nas','htpc']);
  assert.equal(by.gaming.latest.platform,'windows');assert.equal(by.gaming.latest.gpus.length,1);assert.equal(by.gaming.latest.gpus[0].vendor,'nvidia');
  assert.ok(by.gaming.latest.temps.length>=4 && by.gaming.latest.fans.length>=4 && by.gaming.latest.gpus[0].fan>0);assert.deepEqual(by.gaming.latest.ai,[]);
  assert.match(by.gaming.latest.appVersion,/^\d+\.\d+\.\d+$/);assert.equal(by.studio.latest.appVersion,'1.2.30');assert.equal(by.spark.latest.appVersion,null);
  assert.ok(by.spark.latest.ai.length===2 && by.spark.latest.ai[0].models.length===3);assert.ok(by.spark.latest.power.cpu>0);assert.equal(by.spark.latest.powerEst.cpuMeasured,true);
  assert.equal(by.mbp.latest.formFactor,'laptop');assert.equal(by.mbp.latest.gpus[0].temp,null);assert.equal(by.mbp.latest.platform,'macos');
  assert.deepEqual(by.server.latest.gpus,[]);assert.equal(by.server.latest.platform,'linux');
  assert.equal(by.studio.latest.gpus.length,2);assert.ok(by.studio.latest.gpus[0].memTotal>by.studio.latest.gpus[1].memTotal);
  assert.equal(by.nas.macs.length,1);
  const alerts=(await tls('/api/alerts',{key})).json;
  assert.equal(alerts.priceSet,true);assert.ok(alerts.events.some(e=>e.state==='firing' && e.type==='disk' && e.device==='server'));
  assert.deepEqual(alerts.active.map(a=>[a.type,a.device]).sort(),[['disk','server'],['offline','htpc']]);
  assert.deepEqual((await tls('/api/energy/settings',{key})).json,{region:'US-CA',rate:0.316,currency:'USD'});
  const week=(await tls('/api/history/spark?range=7d&points=600',{key})).json.points;
  assert.ok(week.length>400);assert.equal(week.filter((p,i)=>i && p.t-week[i-1].t>2*3600e3).length,1,'one offline gap');
  assert.ok((await tls('/api/energy?bounds='+(Date.now()-7*86400e3)+','+Date.now(),{key})).json.devices.every(d=>d.wh>0 && d.cost>0));
  // The control port: reports stop and resume, an alert fires and resolves, and web pages are refused.
  assert.equal((await until(async()=>{const s=(await ctl('/state','GET')).body;return s.devices.nas==='paused' && s;})).pin,ready.pin);
  const nasSeen=async()=>(await tls('/api/devices',{key})).json.find(d=>d.id==='nas').lastSeen, stopped=await nasSeen();
  await new Promise(ok=>setTimeout(ok,300));assert.equal(await nasSeen(),stopped);
  assert.deepEqual((await ctl('/device/nas/online')).body,{id:'nas',state:'reporting'});
  await until(async()=>await nasSeen()>stopped);
  assert.deepEqual((await ctl('/device/gaming/offline')).body,{id:'gaming',state:'paused'});
  assert.equal((await ctl('/alert')).status,409);assert.equal((await ctl('/device/htpc/online')).status,404);
  assert.deepEqual((await ctl('/device/gaming/online')).body,{id:'gaming',state:'reporting'});
  assert.deepEqual((await ctl('/alert?seconds=1')).body,{ok:true,device:'gaming',seconds:1});
  const log=async()=>(await tls('/api/alerts',{key})).json.events.filter(e=>e.device==='gaming' && e.type==='disk').map(e=>e.state);
  assert.equal((await until(async()=>{const states=await log();return states.length && states;})).at(-1),'firing');
  assert.deepEqual(await until(async()=>{const states=await log();return states.length===2 && states;}),['resolved','firing']);
  const invitation=(await ctl('/invite','GET')).body;
  assert.match(invitation,new RegExp('^https://localhost:'+port+'/mobile#join=[A-Za-z0-9_-]{43}$'));assert.notEqual(invitation,ready.invitation);
  for(const headers of [{Origin:'https://example.test'},{Host:'example.test'}]) assert.equal((await ctl('/revoke-mobile','POST',headers)).status,403);
  assert.equal((await ctl('/nothing')).status,404);
  // Rotation, end to end, through the reference client the app mirrors (transport.js desktopTrust): the
  // phone's proof secret stands where a desktop's agent credential does. Real CA and hostname checks apply.
  const client=[
    "const t=require(process.argv[1]),assert=require('node:assert/strict'),http=require('node:http');",
    "const {origin,control,invitation}=JSON.parse(process.env.DM_FIXTURE);",
    "const post=path=>new Promise((ok,no)=>http.request(control+path,{method:'POST'},res=>{let s='';res.on('data',c=>{s+=c;}).on('end',()=>ok(JSON.parse(s)));}).on('error',no).end());",
    "(async()=>{",
    "  const {pin}=await t.hubJson(origin,'/api/info');",
    "  const {json:e}=await t.hubJson(origin,'/api/mobile/pair',{method:'POST',pin,token:new URL(invitation).hash.slice(6),body:JSON.stringify({name:'Reference client'})});",
    "  const enrollment={pin,client:e.client,agent:e.proof};let saves=0;",
    "  const trust=t.desktopTrust(origin,enrollment,()=>{saves++;}), devices=()=>t.hubJson(origin,'/api/devices',{trust,token:e.client});",
    "  assert.equal((await devices()).json.length,7);",
    "  for(const key of ['rsa','ec','ec']){",
    "    const rotated=await post('/rotate-tls?key='+key);assert.equal(rotated.previous,enrollment.pin);assert.notEqual(rotated.pin,rotated.previous);assert.equal(rotated.key,key);",
    "    assert.equal((await devices()).json.length,7);assert.equal(enrollment.pin,rotated.pin);",
    "  }",
    "  assert.equal(saves,3);",
    "  const impostor=t.desktopTrust(origin,{pin:pin,client:e.client,agent:e.client},()=>assert.fail('accepted without the proof secret'));",
    "  await assert.rejects(t.hubJson(origin,'/api/devices',{trust:impostor,token:e.client}),/Desktop proof refused/);impostor.close();",
    "  assert.deepEqual(await post('/revoke-mobile'),{revoked:2});",
    "  await assert.rejects(devices(),/fresh dashboard invitation/);trust.close();",
    "})().catch(e=>{console.error(e.stack);process.exitCode=1;});",
  ].join('\n');
  await execFile(process.execPath,['-e',client,path.join(root,'transport.js')],{env:{...process.env,NODE_EXTRA_CA_CERTS:ready.ca,DM_FIXTURE:JSON.stringify({origin,control,invitation})},windowsHide:true,timeout:30000});
  const after=await tls('/api/devices',{key});
  assert.equal(after.status,401);assert.notEqual(after.pin,ready.pin);assert.equal(after.pin,(await ctl('/state','GET')).body.pin);
  assert.deepEqual((await ctl('/state','GET')).body.phones,[]);
});

// ---- QR encoder ----
// Matrices below were rendered to PNG and decoded back to exactly `text` by Apple's Vision
// (VNDetectBarcodesRequest) and CoreImage (CIDetector) on macOS 27.2, as were codes at the exact
// capacity of every version from 1 to 40. `bits` is the matrix row by row, most significant bit first.
const KNOWN = [
  { name: 'short', version: 1, mask: 2, text: 'Device Monitor',
    bits: '/jP8ERButLt1tduorsFVB/qv4BQAvgvnKbt3xxzYqs05NQBj8/h8UFGNutod1rwurpkEuc/uMQA=' },
  { name: 'invitation', version: 6, mask: 2, text: 'https://gaming-pc.tail1a2b3c.ts.net/mobile#join=A1b2C3d4E5f6G7h8I9j0K_L-M1n2O3p4Q5r6S7t8U9v',
    bits: '/n1UY7/BDKY4UG6i35Brt17ytMXbrYPwkuwWKXPhB/qqqqr+AY8KYQC+E2NEPjiaTKf9Z/PbLTZXD/ThN43zBr7ccCvgALVNvXW+aVmovA4kUY+NQbfTBNOFxp7J/qimqhy1ggY9HGAy+Enw5mCrT+0/U7LKEIhrT0H54s7L9FfmHJjXlhitWI4mH7UFtjegb/kEWWYgiXb59n5y0QmtWZt9VfmKYXqo/wBw6jFGf4WxHypQWo/qcbuueVovldRBWHaC60QwZekEqB8RUv7osuV+AA==' },
  { name: 'port', version: 6, mask: 6, text: 'https://monitor.home.example:8443/mobile#join=A1b2C3d4E5f6G7h8I9j0K_L-M1n2O3p4Q5r6S7t8U9v',
    bits: '/pSOFz/BcSwG0G6lPSLLt05RQ3XbqN4uMuwQqw8lB/qqqqr+AO8WkgCfl9G8S56oG4uckuwL3ATFmUgEtYo3mkkGH0fU4TNR7Jpmz6Ky1VYRtYOQQBNECpEuQKYYxVxebrSuoYjxyj4T3Ycn7e7YuvIckT3AADtgowubJhqSoON0mUCddebq/6XxLIZAFWf1aSiEEEbr/04b251DrT13+nQB8kzD4eyF+oBcbT1HP6JBVeuQUGcrsZurnOz/3daXOeC66Zhg0WsEs9ZUVf7N6sCsAA==' },
  { name: 'localhost', version: 5, mask: 2, text: 'https://localhost:8443/mobile#join=A1b2C3d4E5f6G7h8I9j0K_L-M1n2O3p4Q5r6S7t8U9v',
    bits: '/l5SA/wRWlaQbrErjrt1qcXV26411q7BSNYdB/qqqq/gFNDFAL5d2SPlaYp82K6lYC8GUaIJFRWh8Sxv0PpetIjtBzjHO4uH5vNXwTtLveptm+CL5wkXH9FJHwmSow4samhrLtQk/U8AR2ALzrfxa+uYZr+mGd7IJ67rhP9avjoqCf/UNf0Act78a/h8q6qwXAKBGbqdLt+91oyxNG6sG6wPBP1vEZ/tLgULgA==' },
  { name: 'long150', version: 8, mask: 2, text: 'https://hub.example/mobile#join=DKRYfmt07CJQXelsz6BIPWdkry5AHOVcjqx4_GNUbipw3-FMTahov29ELSZgnu18DKRYfmt07CJQXelsz6BIPWdkry5AHOVcjqx4_GNUbipw3-FMTahov2',
    bits: '/icRxxi/wQmGhJfQbqYICwhrt1TWdqOl26lwf2BC7BT/kQkRB/qqqqqq/gH8TFQwAL4uf+c/Pn5G0u+GPp6t+i7bkq6TZTMQIZU1BhxTqX7vJ/J4yTiuVbHfvkcQmXE25GFS4f+RWPBQgjiHYjRMnjdcaFt5lqgpSxcC5+XKFa4uR86SMIPrf0BPo6/ycaxcczcaWobuolurnEgpF4xFu/g1/Ln+Y7bNY1RwNC44Rxfa0qnPLzxsozhfKx6Hl/gvA1ANoBsnWrdf0Y4Wm8fKaEyaWMFDDXK0e1830wSj3pxluD8Ffr/4bYkcCzsBze7hlk872QHi6nPlO/yAewsfQkQ/lRqpiivwWnjHEpELr6O+Yc/d1+8zuuTO6gInJOTJBPTjlEjB/oaoQzuHgA==' },
  { name: 'utf8', version: 3, mask: 0, text: 'Ger\u00e4t \u00fcberwacht \u2013 \u76e3\u8996 \u2713',
    bits: '/kSz/BYdEG6Rsrt0nqXbqyWuwS4NB/qqr+AL1ACqC2CXDNqSjcEflPsCZvhhDPCYgssGXW7u4IfQAAqT7lgOGnDsixaO0uAmmeKC+YBOvGv4L2rwS/sWuttvrdJaju6hbnMEKB7v7621gA==' },
];
// ISO/IEC 18004 tables, restated here so the reader below shares nothing with the encoder.
const M_BYTES = [14,26,42,62,84,106,122,152,180,213,251,287,331,362,412,450,504,560,624,666,711,779,857,911,997,1059,1125,1190,1264,1370,1452,1538,1628,1722,1809,1911,1989,2099,2213,2331];
const M_BLOCKS = [[10,1],[16,1],[26,1],[18,2],[24,2],[16,4],[18,4],[22,4],[22,5],[26,5],[30,5],[22,8],[22,9],[24,9],[24,10],[28,10],[28,11],[26,13],[26,14],[26,16],
  [26,17],[28,17],[28,18],[28,20],[28,21],[28,23],[28,25],[28,26],[28,28],[28,29],[28,31],[28,33],[28,35],[28,37],[28,38],[28,40],[28,43],[28,45],[28,47],[28,49]];
const ALIGN = [[],[6,18],[6,22],[6,26],[6,30],[6,34],[6,22,38],[6,24,42],[6,26,46],[6,28,50],[6,30,54],[6,32,58],[6,34,62],[6,26,46,66],[6,26,48,70],[6,26,50,74],[6,30,54,78],[6,30,56,82],[6,30,58,86],[6,34,62,90],
  [6,28,50,72,94],[6,26,50,74,98],[6,30,54,78,102],[6,28,54,80,106],[6,32,58,84,110],[6,30,58,86,114],[6,34,62,90,118],[6,26,50,74,98,122],[6,30,54,78,102,126],[6,26,52,78,104,130],[6,30,56,82,108,134],
  [6,34,60,86,112,138],[6,30,58,86,114,142],[6,34,62,90,118,146],[6,30,54,78,102,126,150],[6,24,50,76,102,128,154],[6,28,54,80,106,132,158],[6,32,58,84,110,136,162],[6,26,54,82,110,138,166],[6,30,58,86,114,142,170]];
const VERSION_WORDS = {7:0x07C94,8:0x085BC,9:0x09A99,10:0x0A4D3,20:0x149A6,32:0x209D5,40:0x28C69};
const FINDER = ['1111111','1000001','1011101','1011101','1011101','1000001','1111111'], ALIGNMENT = ['11111','10001','10101','10001','11111'];
const UNMASK = [(i,j)=>(i+j)%2===0,(i,j)=>i%2===0,(i,j)=>j%3===0,(i,j)=>(i+j)%3===0,(i,j)=>(Math.floor(i/2)+Math.floor(j/3))%2===0,
  (i,j)=>(i*j)%2+(i*j)%3===0,(i,j)=>((i*j)%2+(i*j)%3)%2===0,(i,j)=>((i+j)%2+(i*j)%3)%2===0];   // i: row, j: column
const filler = n => Array.from({length:n},(_,i)=>'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'[(i*7+3)%64]).join('');
const gmul = (a,b) => { let r=0; for(;b;b>>=1,a=(a<<1)^(a&128?0x11D:0)) if(b&1) r^=a; return r; };
const bchRemainder = (word,poly,degree,bits) => { for(let i=bits-1;i>=degree;i--) if(word>>>i&1) word^=poly<<(i-degree); return word; };
// Reads a symbol the way a decoder does, checking every structural rule on the way. No error
// correction: a correct symbol has all-zero Reed-Solomon syndromes, so anything else fails.
function readSymbol({size,modules}) {
  const version=(size-17)/4, at=(x,y)=>modules[y*size+x], fn=new Uint8Array(size*size);
  assert.ok(Number.isInteger(version) && version>=1 && version<=40);assert.equal(modules.length,size*size);
  const reserve=(x,y,w,h)=>{for(let j=y;j<y+h;j++)for(let i=x;i<x+w;i++)fn[j*size+i]=1;};
  const patch=(x,y,rows,what)=>rows.forEach((row,j)=>[...row].forEach((c,i)=>assert.equal(at(x+i,y+j),+c,`${what} at ${x+i},${y+j} in version ${version}`)));
  for(const [x,y] of [[0,0],[size-7,0],[0,size-7]]) patch(x,y,FINDER,'finder');
  for(let i=0;i<8;i++) for(const [x,y] of [[7,i],[i,7],[size-8,i],[size-8+i,7],[7,size-8+i],[i,size-8]]) assert.equal(at(x,y),0,'separator');
  reserve(0,0,9,9);reserve(size-8,0,8,9);reserve(0,size-8,9,8);
  for(let i=8;i<size-8;i++){ assert.equal(at(i,6),(i+1)%2,'timing row');assert.equal(at(6,i),(i+1)%2,'timing column'); }
  reserve(6,0,1,size);reserve(0,6,size,1);
  assert.equal(at(8,size-8),1,'dark module');
  const centers=ALIGN[version-1];
  for(const cx of centers) for(const cy of centers){
    if((cx===6&&cy===6)||(cx===6&&cy===size-7)||(cx===size-7&&cy===6)) continue;
    patch(cx-2,cy-2,ALIGNMENT,'alignment');reserve(cx-2,cy-2,5,5);
  }
  // Format: two copies, BCH(15,5) with generator 10100110111 under the fixed 101010000010010 mask.
  const a=[], b=[];
  for(let i=0;i<=5;i++) a.push(at(8,i)); a.push(at(8,7),at(8,8),at(7,8)); for(let i=9;i<15;i++) a.push(at(14-i,8));
  for(let i=0;i<8;i++) b.push(at(size-1-i,8)); for(let i=8;i<15;i++) b.push(at(8,size-15+i));
  const word=bits=>bits.reduce((v,bit,i)=>v|bit<<i,0), format=word(a)^0x5412;
  assert.equal(word(b),word(a),'format copies');assert.equal(bchRemainder(format,0x537,10,15),0,'format BCH');
  const level=format>>>13, mask=format>>>10&7;
  if(version>=7){
    let one=0, two=0;
    for(let i=0;i<18;i++){ one|=at(size-11+i%3,Math.floor(i/3))<<i;two|=at(Math.floor(i/3),size-11+i%3)<<i; }
    assert.equal(one,two,'version copies');assert.equal(one>>>12,version);assert.equal(bchRemainder(one,0x1F25,12,18),0,'version BCH');
    if(VERSION_WORDS[version]) assert.equal(one,VERSION_WORDS[version]);
    reserve(size-11,0,3,6);reserve(0,size-11,6,3);
  }
  const stream=[];
  for(let col=size-1,up=true;col>0;col-=2,up=!up){
    if(col===6) col--;
    for(let n=0;n<size;n++){ const row=up?size-1-n:n; for(const c of [col,col-1]) if(!fn[row*size+c]) stream.push(at(c,row)^UNMASK[mask](row,c)); }
  }
  const [ecc,blocks]=M_BLOCKS[version-1], total=stream.length>>3, words=Array.from({length:total},(_,i)=>stream.slice(i*8,i*8+8).reduce((v,bit)=>v<<1|bit,0));
  assert.ok(stream.length-total*8<8);assert.ok(stream.slice(total*8).every(bit=>bit===0),'remainder bits');
  const short=blocks-total%blocks, dataLen=Math.floor(total/blocks)-ecc, parts=Array.from({length:blocks},()=>[]);
  let next=0;
  for(let i=0;i<=dataLen;i++) for(let p=0;p<blocks;p++) if(i<dataLen||p>=short) parts[p].push(words[next++]);
  for(let i=0;i<ecc;i++) for(let p=0;p<blocks;p++) parts[p].push(words[next++]);
  assert.equal(next,total);
  for(const part of parts) for(let j=0,root=1;j<ecc;j++,root=gmul(root,2)) assert.equal(part.reduce((s,c)=>gmul(s,root)^c,0),0,`Reed-Solomon syndrome ${j} in version ${version}`);
  const data=parts.flatMap(part=>part.slice(0,part.length-ecc)), bit=n=>data[n>>3]>>>(7-(n&7))&1, take=(from,count)=>{let v=0;for(let i=0;i<count;i++)v=v<<1|bit(from+i);return v;};
  const countBits=version<10?8:16, length=take(4,countBits), bytes=Buffer.from(Array.from({length},(_,i)=>take(4+countBits+i*8,8)));
  assert.equal(take(0,4),4,'byte mode');
  let cursor=4+countBits+length*8;
  const capacityBits=data.length*8, terminator=Math.min(4,capacityBits-cursor);
  assert.equal(take(cursor,terminator),0,'terminator');cursor+=terminator;
  while(cursor%8){ assert.equal(bit(cursor),0);cursor++; }
  for(let pad=0xEC;cursor<capacityBits;cursor+=8,pad^=0xFD) assert.equal(take(cursor,8),pad,'padding');
  return {version,level,mask,bytes,dataCodewords:data.length};
}
const unpack = ({version,bits}) => { const size=version*4+17, packed=Buffer.from(bits,'base64'); return Uint8Array.from({length:size*size},(_,i)=>packed[i>>3]>>>(7-(i&7))&1); };

test('QR codes match matrices that Apple Vision and CoreImage decoded',()=>{
  for(const known of KNOWN){
    const code=QR.encode(known.text);
    assert.deepEqual([code.version,code.size,code.mask],[known.version,known.version*4+17,known.mask],known.name);
    assert.deepEqual(code.modules,unpack(known),known.name);
    assert.equal(readSymbol(code).bytes.toString('utf8'),known.text);
    assert.deepEqual(QR.encode(new TextEncoder().encode(known.text)).modules,code.modules);
  }
  // The independent reader accepts the verified matrices themselves, and rejects any single flipped module.
  const verified={size:41,modules:unpack(KNOWN[1])};
  assert.equal(readSymbol(verified).bytes.toString(),KNOWN[1].text);
  for(const index of [0,8*41+2,20*41+20,30*41+35,41*41-1]){
    const damaged={size:41,modules:verified.modules.slice()};damaged.modules[index]^=1;
    assert.throws(()=>readSymbol(damaged),assert.AssertionError,'module '+index);
  }
});
test('QR version selection follows the byte capacity of error-correction level M',()=>{
  assert.deepEqual(Array.from({length:40},(_,i)=>QR.capacity(i+1)),M_BYTES);
  assert.equal(QR.encode('').version,1);assert.equal(QR.encode([]).version,1);assert.equal(readSymbol(QR.encode('')).bytes.length,0);
  for(let v=1;v<=40;v++){
    const fits=QR.encode(filler(M_BYTES[v-1]));
    assert.deepEqual([fits.version,fits.size],[v,v*4+17]);
    if(v<40) assert.equal(QR.encode(filler(M_BYTES[v-1]+1)).version,v+1);
  }
  assert.throws(()=>QR.encode(filler(2332)),RangeError);
  // Capacity counts bytes, not characters.
  assert.equal(QR.encode('\u00e4'.repeat(7)).version,1);assert.equal(QR.encode('\u00e4'.repeat(8)).version,2);
  // The invitations the hub issues stay small enough to scan easily from a screen.
  assert.equal(QR.encode('https://'+'a'.repeat(63)+'.tail1a2b3c.ts.net/mobile#join='+secret()).version,8);
  assert.ok(QR.encode('https://hub.tail1a2b3c.ts.net/mobile#join='+secret()).version<=6);
});
test('QR symbols of every version hold their structure and read back through an independent decoder',()=>{
  const masks=new Set();
  for(let v=1;v<=40;v++){
    for(const length of new Set([M_BYTES[v-1],v===1?0:M_BYTES[v-2]+1,Math.max(0,M_BYTES[v-1]-2)])){
      const text=filler(length), code=QR.encode(text), read=readSymbol(code);
      assert.equal(read.version,v);assert.equal(read.level,0,'level M is 00');assert.equal(read.mask,code.mask);
      assert.equal(read.bytes.toString('latin1'),text);assert.equal(read.dataCodewords,M_BYTES[v-1]+(v<10?2:3));
      assert.ok(code.modules.every(m=>m===0||m===1));
      masks.add(code.mask);
    }
  }
  // Arbitrary binary payloads, reproducible from run to run.
  for(let i=0;i<60;i++){
    const bytes=crypto.createHash('shake256',{outputLength:1+i*9}).update('qr payload '+i).digest(), read=readSymbol(QR.encode(bytes));
    assert.deepEqual(read.bytes,bytes);masks.add(read.mask);
  }
  assert.equal(masks.size,8,'every mask pattern was chosen and read back at least once');
});
test('QR painting is dark on white with a four-module quiet zone in whole device pixels',()=>{
  const code=QR.encode(KNOWN[1].text);
  function paint(options){
    const rects=[], canvas={style:{},getContext:kind=>{assert.equal(kind,'2d');return {fillStyle:'',fillRect(x,y,w,h){rects.push([this.fillStyle,x,y,w,h]);}};}};
    QR.paint(canvas,code,options);return {canvas,rects};
  }
  for(const [ratio,k] of [[1,4],[2,8],[3,13],[1.5,6]]){
    const {canvas,rects}=paint({size:220,ratio}), n=code.size+8;
    assert.equal(canvas.width,n*k);assert.equal(canvas.height,n*k);assert.equal(canvas.style.width,n*k/ratio+'px');assert.equal(canvas.style.height,canvas.style.width);
    assert.ok(n*k/ratio<=220 && n*k/ratio>190);
    assert.deepEqual(rects[0],['#fff',0,0,n*k,n*k]);
    const seen=new Uint8Array(code.size**2);
    for(const [color,x,y,w,h] of rects.slice(1)){
      assert.equal(color,'#000');assert.deepEqual([w,h],[k,k]);
      assert.ok(x>=4*k && y>=4*k && x+w<=(n-4)*k && y+h<=(n-4)*k,'the quiet zone stays white');
      seen[(y/k-4)*code.size+(x/k-4)]++;
    }
    assert.deepEqual(seen,code.modules);
  }
  assert.equal(paint().canvas.width,(code.size+8)*4);
  const big=QR.encode(filler(2331)), tiny={style:{},getContext:()=>({fillRect(){}})};
  QR.paint(tiny,big,{size:100});assert.equal(tiny.width,big.size+8);
});
