import { readFile, stat, unlink } from 'node:fs/promises';
import { openSync, closeSync, writeFileSync, unlinkSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// All browser checks reuse this existing profile. Run them serially.
// Reports and fixture data may be per-run; browser identity must persist.
export const browserProfile = fileURLToPath(new URL('../../artifacts/browser-profile/edge/', import.meta.url));
if (!(await stat(browserProfile)).isDirectory()) throw new Error('固定浏览器配置不存在；请恢复原目录，不会新建配置。');
const ownerFile = join(browserProfile, '..', 'automation-owner.json');
const processAlive = pid => {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; }
  catch (error) { if (error.code === 'ESRCH') return false; throw error; }
};
let lease;
try { lease = openSync(ownerFile, 'wx'); }
catch (error) {
  if (error.code !== 'EEXIST') throw error;
  const owner = JSON.parse(await readFile(ownerFile, 'utf8'));
  if (processAlive(owner.pid) || processAlive(owner.browserPid))
    throw new Error('固定浏览器配置正在使用，请等待当前自动化结束；不会强退浏览器或另建配置。');
  unlinkSync(ownerFile); // Our stale runner record, never a browser lock.
  lease = openSync(ownerFile, 'wx');
}
let browser;
const saveOwner = () => writeFileSync(ownerFile, JSON.stringify({ pid: process.pid, browserPid: browser?.pid || null }));
saveOwner();
process.on('exit', () => {
  closeSync(lease);
  if (browser && browser.exitCode === null && browser.signalCode === null) return;
  unlinkSync(ownerFile);
});
const portFile = join(browserProfile, 'DevToolsActivePort');
let address;
try { address = (await readFile(portFile, 'utf8')).trim().split(/\r?\n/); }
catch (error) { if (error.code !== 'ENOENT') throw error; }
if (address) {
  let running;
  try {
    const value = await (await fetch(`http://127.0.0.1:${Number(address[0])}/json/version`, { signal: AbortSignal.timeout(1000) })).json();
    running = value.webSocketDebuggerUrl?.endsWith(address[1]);
  } catch (error) {
    // A timeout is not evidence that the existing browser has stopped.
    if (error.cause?.code !== 'ECONNREFUSED') throw error;
    running = false;
  }
  if (running) throw new Error('固定浏览器配置正在使用，请复用现有会话或串行运行。不会创建新配置。');
  // This is stale endpoint metadata, not cookies, login state or a browser lock.
  await unlink(portFile);
}

export function launchSharedBrowser(executable, args, options) {
  if (browser && browser.exitCode === null && browser.signalCode === null)
    throw new Error('同一配置只能串行启动一个浏览器。');
  if (!args.includes(`--user-data-dir=${browserProfile}`))
    throw new Error('浏览器必须使用已确定的固定配置。');
  if(args.some(arg=>/^--(incognito|inprivate|guest)(=|$)/i.test(arg)))
    throw new Error('浏览器自动化不能使用临时身份。');
  browser = spawn(executable, args, options);
  // Retain a separate PID record if the runner crashes before browser exit.
  saveOwner();
  return browser;
}

export async function closeSharedBrowser(child) {
  if (!child) return;
  const forgetEndpoint=async()=>{try{await unlink(portFile);}catch(error){if(error.code!=='ENOENT')throw error;}};
  if(child.exitCode!==null || child.signalCode!==null){await forgetEndpoint();return;}
  let socket;
  let timer;
  const exited = new Promise((resolve,reject) => {
    child.once('exit',resolve);
    timer=setTimeout(()=>reject(new Error('浏览器尚未退出，保留配置占用；不强退或切换配置。')),10000);
  });
  try {
    let current;
    try {current=(await readFile(portFile,'utf8')).trim().split(/\r?\n/);}
    catch(error){if(error.code!=='ENOENT')throw error;}
    if(current && child.exitCode===null && child.signalCode===null){
      socket=new WebSocket(`ws://127.0.0.1:${Number(current[0])}${current[1]}`);
      socket.addEventListener('open',()=>socket.send(JSON.stringify({id:1,method:'Browser.close'})),{once:true});
      socket.addEventListener('error',()=>{/* The same browser may already be closing. */},{once:true});
    }
    await exited;
    await forgetEndpoint();
  } finally { clearTimeout(timer);socket?.close(); }
}
