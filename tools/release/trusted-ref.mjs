import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

export function assertTrustedRef(ref, git) {
  if (ref !== 'refs/heads/main' && !/^refs\/tags\/v\d+\.\d+\.\d+$/.test(ref)) {
    throw Error('Production signing requires main or a vX.Y.Z tag');
  }
  git(['merge-base','--is-ancestor','HEAD','refs/remotes/origin/main']);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  execFileSync('git',['fetch','origin','main'],{stdio:'inherit'});
  assertTrustedRef(process.env.GITHUB_REF,args => execFileSync('git',args,{stdio:'inherit'}));
}
