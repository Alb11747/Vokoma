import {execFileSync} from 'node:child_process';
import {readdirSync} from 'node:fs';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';

// The previous public nightly stays untouched until the new draft is complete.
// Image publication follows the release's transition to public.
export async function publish({gh, files, channel, version, sha, stableTag, pushImage}) {
  const tag = channel === 'nightly' ? `nightly-${version}` : stableTag;
  await gh(['release','create',tag,...files,'--draft','--target',sha,'--title',`${channel} ${version}`,'--notes',`Automated build ${sha}`]);
  await gh(['release','edit',tag,'--draft=false',...(channel === 'nightly' ? ['--prerelease','--latest=false'] : ['--latest'])]);
  await pushImage();
  if (channel === 'nightly') {
    const releases = JSON.parse(await gh(['release','list','--limit','100','--json','tagName,isPrerelease,isDraft,publishedAt']));
    const nightlies = releases.filter(r => r.tagName.startsWith('nightly-') || r.tagName === 'nightly')
      .sort((a,b) => (b.publishedAt ?? '').localeCompare(a.publishedAt ?? ''));
    const keep = new Set(nightlies.filter(r => !r.isDraft).slice(0,3).map(r => r.tagName));
    keep.add(tag);
    for (const old of nightlies) {
      if (!keep.has(old.tagName)) await gh(['release','delete',old.tagName,'--cleanup-tag','--yes']);
    }
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const run = (command,args) => execFileSync(command,args,{encoding:'utf8',stdio:['ignore','pipe','inherit']});
  const image = `ghcr.io/${process.env.GITHUB_REPOSITORY_OWNER.toLowerCase()}/vokoma-server`;
  await publish({gh:args => run('gh',args),files:readdirSync('release').map(f=>join('release',f)),
    channel:process.env.CHANNEL,version:process.env.VERSION,sha:process.env.GITHUB_SHA,stableTag:process.env.GITHUB_REF_NAME,
    pushImage:async () => {
      run('docker',['load','--input','server-image.tar.gz']);
      for (const tag of [process.env.VERSION,process.env.CHANNEL]) {
        run('docker',['tag','vokoma-server:release',`${image}:${tag}`]);
        run('docker',['push',`${image}:${tag}`]);
      }
    }});
}
