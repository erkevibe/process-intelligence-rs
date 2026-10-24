'use strict';
const {spawn} = require('node:child_process');
const mode = process.argv[2];
if (mode === 'argv') {
  process.stdout.write(JSON.stringify(process.argv.slice(3)));
  process.stderr.write('fixture-stderr\n');
} else if (mode === 'exit7') {
  process.stderr.write('expected-exit7\n');
  process.exitCode = 7;
} else if (mode === 'flood') {
  process.stdout.write('x'.repeat(1024 * 1024));
  setInterval(() => {}, 1000);
} else if (mode === 'orphan') {
  const child = spawn(process.execPath, ['-e', 'setTimeout(()=>{},60000)'], {stdio: 'inherit', windowsHide: true});
  process.stdout.write(JSON.stringify({parent: process.pid, descendant: child.pid}) + '\n');
  child.unref();
} else if (mode === 'hang') {
  const child = spawn(process.execPath, ['-e', 'setTimeout(()=>{},60000)'], {stdio: 'ignore', windowsHide: true});
  process.stdout.write(JSON.stringify({parent: process.pid, descendant: child.pid}) + '\n');
  setInterval(() => {}, 1000);
} else {
  throw new Error('unknown fixture mode');
}
