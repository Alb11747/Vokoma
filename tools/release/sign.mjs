import {createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign} from 'node:crypto';
import {readFileSync, writeFileSync, readdirSync, statSync} from 'node:fs';
import {basename, join} from 'node:path';
const dir = process.argv[2];
const dryRun = process.argv.includes('--dry-run');
const privateKey = dryRun ? generateKeyPairSync('ed25519').privateKey : createPrivateKey(process.env.UPDATE_SIGNING_KEY);
const publicKey = createPublicKey(privateKey);
const expected = dryRun ? publicKey.export({type:'spki',format:'der'}) : createPublicKey(readFileSync('tools/release/update-public.pem')).export({type:'spki',format:'der'});
if (!publicKey.export({type:'spki',format:'der'}).equals(expected)) throw Error('Signing key does not match compiled public key');
const files = readdirSync(dir);
const windows = files.find(x => x.endsWith('-full.nupkg'));
const android = files.find(x => x.endsWith('.apk'));
if (!windows || !android) throw Error('Missing packages');
const assets = {};
for (const [platform, file] of Object.entries({windows,android})) {
  const path = join(dir,file);
  assets[platform] = {name:basename(file), size:statSync(path).size, sha256:createHash('sha256').update(readFileSync(path)).digest('hex')};
}
const bytes = Buffer.from(JSON.stringify({schema:1, channel:process.env.CHANNEL, version:process.env.VERSION, assets}));
writeFileSync(join(dir,'update.json'), bytes);
writeFileSync(join(dir,'update.json.sig'), sign(null, bytes, privateKey));

if (dryRun) writeFileSync(join(dir,'update-test-public.pem'),publicKey.export({type:'spki',format:'pem'}));
