import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {createHash, generateKeyPairSync, verify} from 'node:crypto';

const versionScript = resolve('tools/release/version.mjs');
const signScript = resolve('tools/release/sign.mjs');

test('release versions survive numeric tag ordering and stable promotion', () => {
  const cwd = mkdtempSync(join(tmpdir(), 'vokoma-release-test-'));
  const git = (...args) => execFileSync('git', args, {cwd, stdio:'pipe'});
  git('init');
  git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-m','fixture');
  git('tag','v0.9.99'); git('tag','v0.10.0'); git('tag','unrelated');
  function version(ref) {
    const output = join(cwd, 'output'); writeFileSync(output,'');
    const result = spawnSync(process.execPath,[versionScript],{cwd,env:{...process.env,GITHUB_REF:ref,GITHUB_RUN_NUMBER:'97',GITHUB_OUTPUT:output}});
    return {result, values:Object.fromEntries(readFileSync(output,'utf8').trim().split('\n').map(line=>line.split('=')))};
  }
  assert.deepEqual(version('refs/heads/main').values,{name:'0.10.1-nightly.98',build:'98',version:'0.10.1-nightly.98',channel:'nightly'});
  assert.deepEqual(version('refs/tags/v0.10.1').values,{name:'0.10.1',build:'98',version:'0.10.1',channel:'stable'});
  assert.notEqual(version('refs/tags/v0.10.invalid').result.status,0);
});

test('CI signer binds complete payload bytes and refuses a mismatched secret', () => {
  const cwd = mkdtempSync(join(tmpdir(), 'vokoma-sign-test-'));
  const {publicKey,privateKey} = generateKeyPairSync('ed25519');
  // The real signer reads its expected public key relative to the checkout.
  mkdirSync(join(cwd,'tools/release'),{recursive:true});
  writeFileSync(join(cwd,'tools/release/update-public.pem'),publicKey.export({type:'spki',format:'pem'}));
  const apk = Buffer.from('generated APK fixture');
  writeFileSync(join(cwd,'Vokoma.apk'),apk);
  writeFileSync(join(cwd,'Vokoma-full.nupkg'),'generated Windows fixture');
  const env = {...process.env, UPDATE_SIGNING_KEY:privateKey.export({type:'pkcs8',format:'pem'}),CHANNEL:'nightly',VERSION:'0.1.1-nightly.98'};
  execFileSync(process.execPath,[signScript,cwd],{cwd,env});
  const bytes = readFileSync(join(cwd,'update.json'));
  const signature = readFileSync(join(cwd,'update.json.sig'));
  assert(verify(null,bytes,publicKey,signature));
  const manifest = JSON.parse(bytes);
  assert.equal(manifest.assets.android.sha256,createHash('sha256').update(apk).digest('hex'));
  assert.equal(manifest.assets.android.size,apk.length);
  assert.equal(manifest.channel,'nightly');
  assert.equal(manifest.version,'0.1.1-nightly.98');
  const changed = Buffer.from(bytes); changed[0] ^= 1;
  assert(!verify(null,changed,publicKey,signature));
  const wrong = generateKeyPairSync('ed25519').privateKey;
  const result = spawnSync(process.execPath,[signScript,cwd],{cwd,env:{...env,UPDATE_SIGNING_KEY:wrong.export({type:'pkcs8',format:'pem'})}});
  assert.notEqual(result.status,0);
});

test('production signing rejects branch refs and tags outside main history', async () => {
  const {assertTrustedRef} = await import('./trusted-ref.mjs');
  const cwd = mkdtempSync(join(tmpdir(),'vokoma-trust-test-'));
  const git = args => execFileSync('git',args,{cwd,stdio:'pipe'});
  git(['init']);
  const commit = () => git(['-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-m','fixture']);
  commit(); git(['update-ref','refs/remotes/origin/main','HEAD']);
  assert.doesNotThrow(()=>assertTrustedRef('refs/heads/main',git));
  assert.doesNotThrow(()=>assertTrustedRef('refs/tags/v1.2.3',git));
  assert.throws(()=>assertTrustedRef('refs/heads/untrusted',git));
  commit();
  assert.throws(()=>assertTrustedRef('refs/tags/v1.2.3',git));
});

test('dry runs sign with a throwaway key without consulting the production secret', () => {
  const cwd=mkdtempSync(join(tmpdir(),'vokoma-dry-test-'));
  writeFileSync(join(cwd,'Vokoma.apk'),'debug fixture');
  writeFileSync(join(cwd,'Vokoma-full.nupkg'),'windows fixture');
  // No public key file exists here and an invalid production secret must be ignored.
  execFileSync(process.execPath,[signScript,cwd,'--dry-run'],{cwd,env:{...process.env,UPDATE_SIGNING_KEY:'must not read this',CHANNEL:'nightly',VERSION:'0.1.1-nightly.98'}});
  const bytes=readFileSync(join(cwd,'update.json'));
  const signature=readFileSync(join(cwd,'update.json.sig'));
  assert(verify(null,bytes,readFileSync(join(cwd,'update-test-public.pem')),signature));
  assert(!verify(null,bytes,readFileSync('tools/release/update-public.pem'),signature));
});

test('publication exposes complete drafts before images and prunes only after success', async () => {
  const {publish}=await import('./publish.mjs');
  const events=[];
  const releases=Array.from({length:5},(_,i)=>({tagName:`nightly-build-${5-i}`,isDraft:false,isPrerelease:true,publishedAt:`2026-01-0${5-i}T00:00:00Z`}));
  await publish({files:['release/update.json','release/Vokoma.apk'],channel:'nightly',version:'build-5',sha:'fixture',
    gh:async args=>{events.push(args);return args[1]==='list'?JSON.stringify(releases):'';},pushImage:async()=>events.push(['image'])});
  assert(events[0].includes('--draft')); assert(events[0].includes('release/Vokoma.apk'));
  assert(events[1].includes('--draft=false')); assert.equal(events[2][0],'image');
  assert.deepEqual(events.filter(e=>e[1]==='delete').map(e=>e[2]),['nightly-build-2','nightly-build-1']);
  for (const failing of ['create','edit']) {
    const failed=[];
    await assert.rejects(publish({files:['fixture'],channel:'nightly',version:'new',sha:'fixture',
      gh:async args=>{failed.push(args);if(args[1]===failing)throw Error('upload/publication failed');return '';},
      pushImage:async()=>failed.push(['image'])}));
    assert(!failed.some(e=>e[0]==='image'||e[1]==='delete'));
  }
});
