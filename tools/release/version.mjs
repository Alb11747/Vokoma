import {execFileSync} from 'node:child_process';
import {appendFileSync} from 'node:fs';
const ref = process.env.GITHUB_REF ?? '';
const stable = /^refs\/tags\/v(\d+\.\d+\.\d+)$/.exec(ref);
if (ref.startsWith('refs/tags/') && !stable) throw Error('Stable tags must be vX.Y.Z');
const tags = execFileSync('git', ['tag', '--list', 'v*'], {encoding:'utf8'}).trim().split('\n')
  .filter(x => /^v\d+\.\d+\.\d+$/.test(x)).map(x => x.slice(1).split('.').map(Number))
  .sort((a,b) => a[0]-b[0] || a[1]-b[1] || a[2]-b[2]);
const base = tags.at(-1) ?? [0,1,0];
const name = stable ? stable[1] : `${base[0]}.${base[1]}.${base[2]+1}`;
// One workflow counter is shared by both channels; reruns reproduce the same code.
const build = Number(process.env.GITHUB_RUN_NUMBER) + 1;
if (!Number.isSafeInteger(build) || build > 2100000000) throw Error('Invalid Android build code');
const channel = stable ? 'stable' : 'nightly';
appendFileSync(process.env.GITHUB_OUTPUT, `name=${name}\nbuild=${build}\nversion=${stable ? name : `${name}.${build}`}
manifest_version=${name}.${build}\nchannel=${channel}\n`);
