import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';

const [action, input, ...files] = process.argv.slice(2);
const subscription = process.env.AZURE_SUBSCRIPTION_ID;
const resourceGroup = process.env.AZURE_RESOURCE_GROUP;
const cluster = process.env.CLUSTER_NAME;
if (!subscription || !resourceGroup || !cluster || !input || !['start', 'result'].includes(action)) {
  throw new Error('Set AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, CLUSTER_NAME; use start request.json [files...] or result command-id');
}
const clusterURL = `https://management.azure.com/subscriptions/${encodeURIComponent(subscription)}/resourceGroups/${encodeURIComponent(resourceGroup)}/providers/Microsoft.ContainerService/managedClusters/${encodeURIComponent(cluster)}`;
const stateDirectory = join(tmpdir(), 'karpenter-run-command-state');
mkdirSync(stateDirectory, { recursive: true, mode: 0o700 });

function azure(args) {
  const result = spawnSync('az', ['rest', '--subscription', subscription, ...args, '--output', 'json'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) {
    const errors = args.includes('--verbose')
      ? result.stderr.split('\n').filter(line => line.startsWith('ERROR:')).join('\n')
      : result.stderr.trim();
    throw new Error(errors || `Azure CLI failed with exit code ${result.status}`);
  }
  return result;
}

if (action === 'start') {
  const directory = mkdtempSync(join(tmpdir(), 'karpenter-command-'));
  try {
    const request = JSON.parse(readFileSync(input, 'utf8'));
    if (files.length) {
      if (new Set(files.map(file => basename(file))).size !== files.length) throw new Error('Attached filenames must be unique');
      const archive = join(directory, 'context.zip');
      const zipped = spawnSync('zip', ['-j', '-q', archive, ...files.map(file => resolve(file))], { encoding: 'utf8' });
      if (zipped.status !== 0) throw new Error('Could not create Run Command context archive');
      request.context = readFileSync(archive).toString('base64');
    }
    const body = join(directory, 'request.json');
    writeFileSync(body, JSON.stringify(request), { mode: 0o600 });
    const response = azure(['--method', 'post', '--url', `${clusterURL}/runCommand?api-version=2026-07-01`, '--body', `@${body}`, '--verbose']);
    const resultURL = response.stderr.match(/'Location': '(https:\/\/management\.azure\.com\/[^']+)'/i)?.[1];
    const commandID = resultURL?.match(/\/commandResults\/([a-zA-Z0-9-]+)/)?.[1];
    if (!commandID) throw new Error('ARM did not return a command result ID');
    writeFileSync(join(stateDirectory, `${commandID}.json`), JSON.stringify({ clusterURL, resultURL }), { mode: 0o600 });
    console.log(commandID);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
} else {
  if (!/^[a-zA-Z0-9-]+$/.test(input)) throw new Error('Invalid command ID');
  const stateFile = join(stateDirectory, `${input}.json`);
  let resultURL = `${clusterURL}/commandResults/${input}?api-version=2026-07-01`;
  if (existsSync(stateFile)) {
    const saved = JSON.parse(readFileSync(stateFile, 'utf8'));
    if (saved.clusterURL !== clusterURL) throw new Error('Command belongs to a different cluster');
    resultURL = saved.resultURL;
  }
  const response = azure(['--method', 'get', '--url', resultURL]);
  const result = JSON.parse(response.stdout);
  console.log(JSON.stringify(result.properties ?? result, null, 2));
  const properties = result.properties ?? result;
  if (properties.provisioningState === 'Succeeded' && properties.exitCode === 0) {
    process.exitCode = 0;
  } else if (properties.provisioningState === 'Failed' || (properties.exitCode !== undefined && properties.exitCode !== 0)) {
    process.exitCode = 1;
  } else {
    process.exitCode = 2;
  }
}