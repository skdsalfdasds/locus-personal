const { contextBridge, ipcRenderer, webUtils } = require('electron');
contextBridge.exposeInMainWorld('waypoint', {
  call: (method, params = {}) => ipcRenderer.invoke('waypoint:call', method, params),
  chooseFile: (kind) => ipcRenderer.invoke('waypoint:choose', kind),
  saveFile: (name) => ipcRenderer.invoke('waypoint:save', name),
  pathForFile: (file) => webUtils.getPathForFile(file),
  reveal: (path) => ipcRenderer.invoke('waypoint:reveal', path),
  openExternal: (url) => ipcRenderer.invoke('waypoint:external', url),
  onEvent: (listener) => { const handler = (_, event) => listener(event); ipcRenderer.on('waypoint:event', handler); return () => ipcRenderer.removeListener('waypoint:event', handler); },
  platform: process.platform,
});
