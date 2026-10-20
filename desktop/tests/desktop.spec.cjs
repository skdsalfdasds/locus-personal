const { test } = require('node:test');
const assert = require('node:assert/strict');
const { _electron } = require('playwright');
const path = require('node:path');
const fs = require('node:fs');

test('desktop navigation and protected-device controls', {timeout:60000}, async () => {
  const env={...process.env};delete env.ELECTRON_RUN_AS_NODE;
  if(process.env.CI)env.DEBUG='pw:browser*';
  const application=await _electron.launch({args:[path.join(__dirname,'..'),...(process.env.CI&&process.platform==='linux'?['--no-sandbox']:[])],env,timeout:20000});
  try {
    const page=await application.firstWindow({timeout:20000});
    await page.getByRole('heading',{name:'Install Waypoint',exact:true}).waitFor();
    await page.waitForFunction(()=>document.querySelector('.statusbar')?.textContent.includes('Device service online'));
    // A machine without Apple device drivers must still run the desktop UI.
    const discovery=await page.evaluate(async()=>{
      try{return {devices:await window.waypoint.call('devices.list')};}
      catch(error){return {devices:[],error:error.message};}
    });
    const devices=discovery.devices;
    if(discovery.error)await page.getByRole('alert').waitFor();
    const protectedDevice=devices.some(d=>d.protected);
    if(protectedDevice){
      await page.getByText('Active session protected',{exact:true}).waitFor({timeout:20000});
      assert.equal(await page.getByRole('button',{name:'Device protected',exact:true}).isDisabled(),true);
    }else if(!devices.length){
      assert.equal(await page.locator('.install-action button').isDisabled(),true);
    }
    assert.equal(await page.locator('svg,img').count(),0,'Interface must not render decorative icons or imagery');
    for(const [name,heading] of [['Sideload an app','Sideload an app'],['Applications','Applications'],['Pairing','Pairing'],['Accounts','Accounts & signing'],['Activity','Activity'],['Settings','Settings']]){
      await page.locator('.sidebar').getByRole('button',{name,exact:true}).click();
      await page.getByRole('heading',{name:heading,exact:true,level:1}).waitFor();
      if(name==='Pairing'){
        if(protectedDevice||!devices.length){
          assert.equal(await page.getByRole('button',{name:'Create remote pairing',exact:true}).isDisabled(),true);
          assert.equal(await page.getByRole('switch',{name:'Wireless debugging'}).isDisabled(),true);
        }
      }
    }
    const settings=await page.evaluate(()=>window.waypoint.call('settings.get'));
    try{
      await page.getByRole('button',{name:'Dark',exact:true}).click();
      await page.waitForFunction(()=>document.documentElement.dataset.theme==='dark');
      await page.locator('.sidebar').getByRole('button',{name:'Install Waypoint',exact:true}).click();
      if(protectedDevice)await page.getByText('Active session protected',{exact:true}).waitFor();
      assert.equal(await page.locator('svg,img').count(),0);
      fs.mkdirSync(path.join(__dirname,'../outputs'),{recursive:true});
      await page.waitForFunction(()=>getComputedStyle(document.querySelector('main')).opacity==='1');
      await page.screenshot({path:path.join(__dirname,'../outputs/desktop-dark.png'),fullPage:true,animations:'disabled'});
    }finally{await page.evaluate(theme=>window.waypoint.call('settings.save',{theme}),settings.theme);}
    const issues=await page.evaluate(()=>({width:document.documentElement.scrollWidth,viewport:innerWidth}));
    assert.ok(issues.width<=issues.viewport,'Layout must not scroll horizontally');
    // Exercise the offline export path with an absent Apple device service.
    // All IPC below is synthetic; no file chooser or phone operation is invoked.
    await application.evaluate(({ipcMain})=>{
      global.waypointTestCalls=[];
      global.waypointTestManaged=false;
      for(const channel of ['waypoint:call','waypoint:choose','waypoint:save'])ipcMain.removeHandler(channel);
      ipcMain.handle('waypoint:choose',()=>'/synthetic.ipa');
      ipcMain.handle('waypoint:save',()=>'/synthetic-export.ipa');
      ipcMain.handle('waypoint:call',async(_,method,params)=>{
        global.waypointTestCalls.push({method,params});
        if(method==='system.status')return {version:'0.1.0',platform:'win32',nativeReady:true,account:global.waypointTestManaged?{email:'test@example.invalid'}:null,settings:{theme:'light',hideSensitive:true}};
        if(method==='devices.list'){
          if(global.waypointTestManaged)return [{id:'synthetic-phone',name:'Synthetic phone',model:'iPhone17,5',trusted:true,transport:'USB'}];
          throw Error('Synthetic Apple device service unavailable');
        }
        if(method==='setup.check')return {trusted:true,developerMode:true,localDevVPNInstalled:true,waypointInstalled:true};
        if(method==='apps.list'&&global.waypointTestManaged)return [{bundleId:'org.example.synthetic.TESTTEAM',name:'Synthetic app',version:'1.0',managed:true,managedId:'synthetic-managed-app',refreshable:true,sourceAvailable:true,expires:'2030-01-02T00:00:00+00:00',fileSharing:true}];
        if(['jobs.list','pairings.list','apps.list'].includes(method))return [];
        if(method==='ipa.inspect')return {path:'/synthetic.ipa',filename:'synthetic.ipa',name:'Synthetic app',version:'1.0',size:1024,extensions:[],bundleId:'org.example.synthetic'};
        if(method==='ipa.exportSigned')return {signatureMode:'adhoc',appleProvisioned:false};
        if(method==='app.refresh')return {id:'synthetic-refresh',name:'Refresh synthetic app',status:'queued',stage:'Waiting',started:new Date().toISOString(),progress:null,logs:[],deviceId:'synthetic-phone'};
        throw Error('Unexpected preview operation: '+method);
      });
    });
    await page.reload();
    await page.waitForFunction(()=>document.querySelector('.statusbar')?.textContent.includes('Device service online'));
    await page.getByRole('alert').getByText('Synthetic Apple device service unavailable').waitFor();
    await page.locator('.sidebar').getByRole('button',{name:'Sideload an app',exact:true}).click();
    await page.getByRole('button',{name:'Choose IPA',exact:true}).click();
    await page.getByRole('combobox',{name:'Signing method',exact:true}).selectOption('adhoc');
    await page.getByLabel('Custom entitlements',{exact:true}).fill('{"get-task-allow":true}');
    await page.getByRole('button',{name:'Export ad-hoc IPA',exact:true}).click();
    await page.getByRole('status').getByText('Ad-hoc signed IPA exported. No Apple provisioning was added.').waitFor();
    const calls=await application.evaluate(()=>global.waypointTestCalls);
    assert.ok(!calls.some(call=>call.method==='install.start'||call.method==='setup.start'));
    assert.deepEqual(calls.find(call=>call.method==='ipa.exportSigned').params.entitlements,{'get-task-allow':true});
    await application.evaluate(()=>{global.waypointTestManaged=true;});
    await page.reload();
    await page.waitForFunction(()=>document.querySelector('.statusbar')?.textContent.includes('Device service online'));
    await page.locator('.sidebar').getByRole('button',{name:'Applications',exact:true}).click();
    await page.getByRole('table').getByText('Synthetic app',{exact:true}).waitFor();
    assert.equal(await page.locator('time[datetime="2030-01-02T00:00:00+00:00"]').count(),1);
    await page.getByRole('table').getByRole('button',{name:'Refresh',exact:true}).click();
    await page.getByRole('heading',{name:'Activity',exact:true,level:1}).waitFor();
    const refreshed=await application.evaluate(()=>global.waypointTestCalls.find(call=>call.method==='app.refresh'));
    assert.deepEqual(refreshed.params,{libraryId:'synthetic-managed-app'});
  }catch(error){
    if(process.env.CI){
      const page=application.windows()[0];
      fs.mkdirSync(path.join(__dirname,'../outputs'),{recursive:true});
      if(page&&!page.isClosed())await page.screenshot({path:path.join(__dirname,'../outputs/desktop-failure.png'),animations:'disabled'}).catch(()=>{});
    }
    throw error;
  }finally{
    // Electron can remain alive after a failed window/driver handshake. Bound
    // cleanup so CI reports the failure instead of waiting until its job limit.
    const timeout=setTimeout(()=>application.process().kill('SIGKILL'),5000);
    try{await application.close();}finally{clearTimeout(timeout);}
  }
});
