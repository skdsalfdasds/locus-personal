const { app, BrowserWindow, ipcMain, dialog, shell, Menu } = require('electron');
const { spawn } = require('node:child_process');
const { createInterface } = require('node:readline');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { fileURLToPath } = require('node:url');

app.setName('Waypoint Desktop');
const ownsWorkspace = app.requestSingleInstanceLock();
if (!ownsWorkspace) app.quit();
let mainWindow, backend, quitting = false;
const pending = new Map();
const pairingMethods=['pairing.inspect','pairing.import','pairing.validate','pairing.destinations'];
const root = path.join(__dirname, '..');
const allowed = new Set(['system.status','settings.get','settings.save','devices.list','apps.list','library.list','jobs.list','jobs.cancel','ipa.inspect','ipa.prepare','ipa.exportSigned','ipa.sign','install.start','pairings.list','pairing.createLockdown','pairing.createRemote','pairing.export','pairing.install','device.enableWireless','account.login','account.logout','account.certificates','account.appIds','identity.import','profile.import','prompt.reply','app.uninstall','app.refresh','setup.check','setup.start']);
for(const method of pairingMethods)allowed.add(method);
function startBackend() {
  const packaged = path.join(process.resourcesPath, 'runtime', 'waypoint-backend', process.platform === 'win32' ? 'waypoint-backend.exe' : 'waypoint-backend');
  const localPython = path.join(root,'.venv',process.platform==='win32'?'Scripts/python.exe':'bin/python');
  const hostedPython = process.env.pythonLocation ? path.join(process.env.pythonLocation,process.platform==='win32'?'python.exe':'bin/python3') : null;
  const devPython = process.env.WAYPOINT_PYTHON || (fs.existsSync(localPython) ? localPython : hostedPython&&fs.existsSync(hostedPython) ? hostedPython : process.platform==='win32'?'python':'python3');
  const command = app.isPackaged ? packaged : devPython;
  const args = app.isPackaged ? [] : ['-m', 'backend.server'];
  backend = spawn(command, args, { cwd: app.isPackaged ? path.dirname(packaged) : root, windowsHide: true, env: { ...process.env, PYTHONUTF8:'1', WAYPOINT_DATA_DIR:app.getPath('userData'), WAYPOINT_BUNDLED_IPA:app.isPackaged ? path.join(process.resourcesPath,'runtime','apps','Waypoint.ipa') : '', WAYPOINT_NATIVE_ENGINE:app.isPackaged ? path.join(process.resourcesPath,'runtime',process.platform==='win32'?'waypoint-engine.exe':'waypoint-engine') : '' }, stdio: ['pipe','pipe','pipe'] });
  createInterface({input:backend.stdout}).on('line', line => {
    try {
      const message = JSON.parse(line);
      if (message.id && pending.has(message.id)) {
        const {resolve,reject,timer} = pending.get(message.id); clearTimeout(timer); pending.delete(message.id);
        message.error ? reject(new Error(message.error.message)) : resolve(message.result);
      } else if (message.event) { mainWindow?.webContents.send('waypoint:event', message); }
    } catch { /* Ignore non-protocol stdout; never echo it into user logs. */ }
  });
  // Diagnostics may carry identifiers. Raw stderr is deliberately not relayed.
  backend.stderr.on('data', () => {});
  backend.on('error', e => failBackend(`Unable to start the device service: ${e.message}`));
  backend.on('exit', () => failBackend('The device service stopped. Reopen Waypoint Desktop to reconnect.'));
}
function failBackend(message) {
  for (const item of pending.values()) { clearTimeout(item.timer); item.reject(new Error(message)); }
  pending.clear(); mainWindow?.webContents.send('waypoint:event',{event:'backendError',message});
}
function callBackend(method, params) {
  if (!backend || backend.exitCode !== null) return Promise.reject(new Error('Device service is not running.'));
  const id = crypto.randomUUID();
  return new Promise((resolve,reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('The operation timed out. Check Activity before retrying.')); }, 910000);
    pending.set(id,{resolve,reject,timer}); backend.stdin.write(JSON.stringify({id,method,params})+'\n');
  });
}
function allowedPage(raw) {
  try {
    const url=new URL(raw);
    if(process.env.WAYPOINT_DEV_URL&&!app.isPackaged)return url.origin==='http://127.0.0.1:5178';
    if(url.protocol!=='file:')return false;
    const actual=path.resolve(fileURLToPath(url)),expected=path.join(root,'dist','index.html');
    return process.platform==='win32'?actual.toLowerCase()===expected.toLowerCase():actual===expected;
  } catch { return false; }
}
function trusted(event) {
  return event.sender===mainWindow?.webContents&&event.senderFrame===event.sender.mainFrame&&allowedPage(event.senderFrame?.url||'');
}
app.on('second-instance', () => {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
});
if (ownsWorkspace) app.whenReady().then(async () => {
  mainWindow = new BrowserWindow({ width:1390,height:920,minWidth:1060,minHeight:740,title:'Waypoint Desktop',backgroundColor:'#f6f7f8',show:false,webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true} });
  Menu.setApplicationMenu(Menu.buildFromTemplate([{label:'Waypoint',submenu:[{label:'About Waypoint',role:'about'},{type:'separator'},{label:'Quit',role:'quit'}]},{label:'Edit',submenu:[{role:'undo'},{role:'redo'},{type:'separator'},{role:'cut'},{role:'copy'},{role:'paste'},{role:'selectAll'}]},{label:'View',submenu:[{role:'reload'},{role:'toggleDevTools'},{type:'separator'},{role:'resetZoom'},{role:'zoomIn'},{role:'zoomOut'}]}]));
  mainWindow.webContents.setWindowOpenHandler(() => ({action:'deny'}));
  mainWindow.webContents.on('will-navigate',(event,url) => { if (!allowedPage(url)) event.preventDefault(); });
  ipcMain.handle('waypoint:call', async (event,method,params) => { if(!trusted(event)||!allowed.has(method)) throw new Error('Unsupported request'); return callBackend(method,params); });
  ipcMain.handle('waypoint:choose', async (event,kind) => {
    if(!trusted(event))return null;
    const filters = {ipa:[{name:'iOS application',extensions:['ipa']}],certificate:[{name:'Signing identity',extensions:['p12','pfx']}],profile:[{name:'Provisioning profile',extensions:['mobileprovision']}],icon:[{name:'App icon',extensions:['png','jpg','jpeg']}],tweak:[{name:'Tweak libraries',extensions:['dylib','deb','zip']}],pairing:[{name:'Pairing record',extensions:['plist','mobiledevicepairing']}]};
    const result=await dialog.showOpenDialog(mainWindow,{properties:['openFile'],filters:filters[kind]||filters.ipa}); return result.canceled?null:result.filePaths[0];
  });
  ipcMain.handle('waypoint:save', async (event,name) => {if(!trusted(event))return null;const result=await dialog.showSaveDialog(mainWindow,{defaultPath:path.basename(name||'Export.ipa')});return result.canceled?null:result.filePath;});
  ipcMain.handle('waypoint:reveal', (event,filename) => {if(trusted(event)&&typeof filename==='string'&&fs.existsSync(filename))shell.showItemInFolder(filename);});
  ipcMain.handle('waypoint:external', (event,url) => {if(trusted(event)&&typeof url==='string'&&url.startsWith('https://'))return shell.openExternal(url);});
  startBackend();
  if(process.env.WAYPOINT_DEV_URL)await mainWindow.loadURL('http://127.0.0.1:5178/');else await mainWindow.loadFile(path.join(root,'dist','index.html'));
  mainWindow.show();
  if (process.argv.includes('--smoke-test')) {
    await new Promise(r=>setTimeout(r,5000));
    const status = await callBackend('system.status',{});
    const devices = await callBackend('devices.list',{});
    const output=process.env.WAYPOINT_SMOKE_OUTPUT || path.join(app.isPackaged ? app.getPath('userData') : root,'outputs');
    fs.mkdirSync(output,{recursive:true});
    const image=await mainWindow.webContents.capturePage();fs.writeFileSync(path.join(output,'desktop.png'),image.toPNG());
    fs.writeFileSync(path.join(output,'desktop-smoke.json'),JSON.stringify({status:{version:status.version,platform:status.platform,nativeReady:status.nativeReady},devices:devices.map(d=>({transport:d.transport,osVersion:d.osVersion,trusted:d.trusted,protected:d.protected})),rendered:await mainWindow.webContents.executeJavaScript('document.body.innerText')},null,2));
    app.quit();
  }
});
app.on('before-quit',()=>{quitting=true;backend?.stdin.end();setTimeout(()=>backend?.kill(),1000).unref();});
app.on('window-all-closed',()=>{if(process.platform!=='darwin')app.quit();});
