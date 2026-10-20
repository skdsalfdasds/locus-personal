const { test }=require('node:test');
const assert=require('node:assert/strict');
const { _electron }=require('playwright');
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const crypto=require('node:crypto');
const { execFile,execFileSync }=require('node:child_process');

const root=path.resolve(__dirname,'..');
function executable(){
  const release=path.join(root,'release');
  const product=require('../package.json').build.productName;
  const candidates=process.platform==='win32'?[path.join(release,'win-unpacked',product+'.exe')]:
    process.platform==='linux'?[path.join(release,'linux-unpacked','waypoint-desktop'),path.join(release,'linux-unpacked',product)]:
    [process.arch==='arm64'?'mac-arm64':'mac',process.arch==='arm64'?'mac':'mac-x64']
      .map(folder=>path.join(release,folder,product+'.app','Contents','MacOS',product));
  const found=candidates.find(file=>fs.existsSync(file));
  assert.ok(found,'Build the platform package before testing the assembled app');
  return found;
}
function python(){
  const local=path.join(root,'.venv',process.platform==='win32'?'Scripts/python.exe':'bin/python');
  const hosted=process.env.pythonLocation&&path.join(process.env.pythonLocation,process.platform==='win32'?'python.exe':'bin/python3');
  return process.env.WAYPOINT_VERIFY_PYTHON||(fs.existsSync(local)?local:hosted&&fs.existsSync(hosted)?hosted:process.platform==='win32'?'python':'python3');
}
async function deadline(promise,ms){
  let timer;
  try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Packaged export timed out')),ms);})]);}
  finally{clearTimeout(timer);}
}

test('assembled desktop launches its bundled services and exports a verified IPA offline',{timeout:120000},async()=>{
  const env={...process.env};delete env.ELECTRON_RUN_AS_NODE;
  const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'waypoint-packaged-check-'));
  let application;
  try{
    application=await _electron.launch({executablePath:executable(),
      args:[`--user-data-dir=${path.join(temporary,'profile')}`,...(process.env.CI&&process.platform==='linux'?['--no-sandbox']:[])],
      env,timeout:20000});
    const page=await application.firstWindow({timeout:20000});
    await page.getByRole('heading',{name:'Install Waypoint',exact:true}).waitFor();
    const built=await application.evaluate(({app})=>({packaged:app.isPackaged,resources:process.resourcesPath}));
    assert.equal(built.packaged,true,'This check must run the assembled application');
    const status=await page.evaluate(()=>window.waypoint.call('system.status'));
    assert.equal(status.nativeReady,true);
    // A second launch must hand focus to this instance and exit, rather than
    // create another backend that could race an installation or renewal.
    await new Promise((resolve,reject)=>execFile(executable(),
      [`--user-data-dir=${path.join(temporary,'profile')}`,...(process.env.CI&&process.platform==='linux'?['--no-sandbox']:[])],
      {env,windowsHide:true,timeout:15000},error=>error?reject(error):resolve()));
    assert.equal((await page.evaluate(()=>window.waypoint.call('system.status'))).nativeReady,true);
    if(process.platform==='win32')assert.ok(fs.existsSync(path.join(built.resources,'runtime','VCRUNTIME140.dll')));
    const source=path.join(built.resources,'runtime','apps','Waypoint.ipa');
    const digest=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    const before=digest(source);
    const metadata=await page.evaluate(source=>window.waypoint.call('ipa.inspect',{path:source}),source);
    assert.equal(metadata.desktopSetupVersion,1);
    assert.equal(metadata.profileSignatureVerified,false);
    const destination=path.join(temporary,'export.ipa');
    const result=await deadline(page.evaluate(({source,destination})=>window.waypoint.call('ipa.exportSigned',{
      path:source,destination,entitlements:{'get-task-allow':true}}),{source,destination}),60000);
    assert.equal(result.signatureMode,'adhoc');assert.equal(result.appleProvisioned,false);
    assert.equal(digest(source),before);
    const independent=JSON.parse(execFileSync(python(),[path.join(root,'scripts/verify-adhoc.py'),destination,'--expect-task-allow'],
      {encoding:'utf8',windowsHide:true,timeout:30000}));
    const evidence={platform:process.platform,architecture:process.arch,assembledApp:true,nativeReady:true,singleInstance:true,
      sourcePreserved:true,verifiedBinaries:result.verifiedBinaries,...independent};
    fs.mkdirSync(path.join(root,'outputs'),{recursive:true});
    fs.writeFileSync(path.join(root,'outputs',`packaged-${process.platform}-${process.arch}.json`),JSON.stringify(evidence,null,2));
    if(process.env.CI){
      await page.waitForFunction(()=>getComputedStyle(document.querySelector('main')).opacity==='1');
      await page.screenshot({path:path.join(root,'outputs',`packaged-${process.platform}-${process.arch}.png`),animations:'disabled'});
    }
  }finally{
    if(application){
      const timeout=setTimeout(()=>application.process().kill('SIGKILL'),5000);
      try{await application.close();}finally{clearTimeout(timeout);}
    }
    const resolved=path.resolve(temporary);
    assert.equal(path.dirname(resolved),path.resolve(os.tmpdir()));
    assert.ok(path.basename(resolved).startsWith('waypoint-packaged-check-'));
    fs.rmSync(resolved,{recursive:true,force:true,maxRetries:30,retryDelay:100});
  }
});
