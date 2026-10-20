const { contextBridge, ipcRenderer, webUtils } = require('electron');
async function invoke(channel,...args){
  try{return await ipcRenderer.invoke(channel,...args);}
  catch(error){throw new Error(String(error?.message||error).replace(/^Error invoking remote method '[^']+': (?:Error: )?/,''));}
}
contextBridge.exposeInMainWorld('waypoint', {
  call: (method, params = {}) => invoke('waypoint:call', method, params),
  chooseFile: (kind) => invoke('waypoint:choose', kind),
  saveFile: (name) => invoke('waypoint:save', name),
  pathForFile: (file) => webUtils.getPathForFile(file),
  reveal: (path) => invoke('waypoint:reveal', path),
  openExternal: (url) => invoke('waypoint:external', url),
  onEvent: (listener) => { const handler = (_, event) => listener(event); ipcRenderer.on('waypoint:event', handler); return () => ipcRenderer.removeListener('waypoint:event', handler); },
  platform: process.platform,
});
