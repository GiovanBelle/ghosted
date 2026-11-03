// Stand-in for Claude Code: reads raw console input, runs the prompt hook with "/ghosted test-keys" the way
// Claude Code runs hooks (through a shell, piped stdio, no window), and passes once the marker text arrives.
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const [out, data] = process.argv.slice(2);
let got = '';
process.stdin.setRawMode(true);
process.stdin.on('data', d => {
  got += d.toString('utf8');
  if (got.includes('ghosted_ typing works')) finish(0);
});
let reply = '', errors = '';
function finish(code) {
  fs.writeFileSync(out, JSON.stringify({ code, received: got, hook: reply, stderr: errors }));
  process.exit(code);
}
const hook = spawn(`"${process.execPath}" "${path.join(__dirname, '..', '..', 'hooks', 'ghosted.js')}" prompt`, {
  shell: true, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
  env: { ...process.env, CLAUDE_PLUGIN_DATA: data, GHOSTED_DRY_TYPE: '', GHOSTED_DEBUG: '1' },
});
hook.stdin.end(JSON.stringify({ prompt: '/ghosted test-keys', cwd: process.cwd(), session_id: 'ci' }));
hook.stdout.on('data', d => { reply += d; });
hook.stderr.on('data', d => { errors += d; });
hook.on('exit', () => { process.stdout.write(`hook: ${reply}\n`); });
setTimeout(() => finish(1), 45000);
