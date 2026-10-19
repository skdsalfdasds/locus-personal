const { test } = require('node:test');
const assert = require('node:assert/strict');
const { _electron } = require('playwright');
const path = require('node:path');
const fs = require('node:fs');

test('desktop navigation and protected-device controls', {timeout:60000}, async () => {
  const env={...process.env};delete env.ELECTRON_RUN_AS_NODE;
  const application=await _electron.launch({args:[path.join(__dirname,'..'),...(process.env.CI&&process.platform==='linux'?['--no-sandbox']:[])],env});
  try {
    const page=await application.firstWindow();
    await page.getByRole('heading',{name:'Install Waypoint',exact:true}).waitFor();
    await page.waitForFunction(()=>document.querySelector('.statusbar')?.textContent.includes('Device service online'));
    const devices=await page.evaluate(()=>window.waypoint.call('devices.list'));
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
      await page.screenshot({path:path.join(__dirname,'../outputs/desktop-dark.png'),fullPage:true});
    }finally{await page.evaluate(theme=>window.waypoint.call('settings.save',{theme}),settings.theme);}
    const issues=await page.evaluate(()=>({width:document.documentElement.scrollWidth,viewport:innerWidth}));
    assert.ok(issues.width<=issues.viewport,'Layout must not scroll horizontally');
  }finally{await application.close();}
});
