import { build } from 'esbuild';
import { cp, mkdir, rm, readFile, readdir } from 'node:fs/promises';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const source = fileURLToPath(new URL('../Sources/AccountWebTest/Workbench/Resources/Chart/', import.meta.url));
const output = fileURLToPath(new URL('../.build/chart-host/', import.meta.url));
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
const result = await build({ entryPoints: [source + 'chart.js'], outfile: output + 'chart.js', metafile: true,
  bundle: true, minify: true, format: 'iife', target: ['safari17'],
  nodePaths: [fileURLToPath(new URL('node_modules', import.meta.url))], legalComments: 'eof' });
for (const name of ['index.html', 'chart.css']) await cp(source + name, output + name);
await mkdir(output + 'licenses', { recursive: true });
for (const name of ['LICENSE', 'NOTICE']) await cp(new URL(`node_modules/@luxalgo/vela/${name}`, import.meta.url), output + `licenses/Vela-${name}.txt`);
// Retain notices for every package actually included in the JS bundle.
const packages = new Set();
for (const input of Object.keys(result.metafile.inputs).filter(path => path.includes('node_modules/'))) {
  let directory = dirname(resolve(input));
  while (directory.includes('node_modules')) {
    try {
      const pkg = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
      if (!packages.has(pkg.name)) {
        packages.add(pkg.name);
        for (const name of await readdir(directory)) {
          if (/^(license|notice)(\.|$)/i.test(name)) await cp(join(directory, name), output + `licenses/${pkg.name.replaceAll('/', '-')}-${name}.txt`);
        }
      }
      break;
    } catch (error) { if (error.code !== 'ENOENT') throw error; directory = dirname(directory); }
  }
}
console.log('Built local Vela chart host (including license and attribution notices).');
