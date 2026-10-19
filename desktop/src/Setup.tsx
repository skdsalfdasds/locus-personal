import { useEffect, useState } from 'react';
import type { Device, Job, Status } from './types';

interface Preflight {
  trusted:boolean;developerMode:boolean;localDevVPNInstalled:boolean;waypointInstalled:boolean;
  bundledPackage:string|null;protected:boolean;vpnConnected:null;localDevVPNStoreURL:string;
}
interface Props {device?:Device;status:Status|null;jobs:Job[];onJob:(job:Job)=>void;onError:(message:string)=>void;onActivity:()=>void}
const stages=[{name:'Apple verification',from:12},{name:'Code signing',from:27},{name:'Installation',from:45},{name:'Pairing',from:80}];
function hostname(value:string){try{return new URL(value).hostname;}catch{return value;}}
export default function Setup({device,status,jobs,onJob,onError,onActivity}:Props){
  const [preflight,setPreflight]=useState<Preflight|null>(null);
  const [checking,setChecking]=useState(false);
  const [checkVersion,setCheckVersion]=useState(0);
  const [checkError,setCheckError]=useState('');
  const [email,setEmail]=useState('');
  const [password,setPassword]=useState('');
  const [path,setPath]=useState('');
  const [advanced,setAdvanced]=useState(false);
  const [endpoint,setEndpoint]=useState<string|null>(null);
  const [submitting,setSubmitting]=useState(false);
  const [jobId,setJobId]=useState('');
  const job=jobs.find(j=>j.id===jobId);
  const running=submitting||job?.status==='queued'||job?.status==='running';
  const protectedDevice=!!device?.protected||!!preflight?.protected;
  const service=endpoint??status?.settings.anisetteUrl??'';
  const accountReady=!!status?.account;
  const ready=!!device?.trusted&&preflight?.developerMode===true&&!protectedDevice&&!preflight?.waypointInstalled;
  const canInstall=!!(ready&&!running&&status?.nativeReady&&(path||preflight?.bundledPackage)&&(accountReady||status?.platform!=='win32'||service));
  const deviceId=device?.id;
  useEffect(()=>{
    let current=true;
    setPreflight(null);setCheckError('');
    if(!deviceId||!window.waypoint){setChecking(false);return;}
    setChecking(true);
    window.waypoint.call<Preflight>('setup.check',{deviceId}).then(result=>{
      if(current)setPreflight(result);
    }).catch((error:Error)=>{
      if(current)setCheckError(error.message);
    }).finally(()=>{if(current)setChecking(false);});
    return()=>{current=false;};
  },[deviceId,checkVersion]);
  async function start(e:React.FormEvent){
    e.preventDefault();
    if(!window.waypoint||!device||!canInstall)return;
    setSubmitting(true);const secret=password;setPassword('');
    try{
      const job=await window.waypoint.call<Job>('setup.start',{deviceId:device.id,email,password:secret,path:path||preflight?.bundledPackage||undefined,anisetteUrl:service||undefined});
      setJobId(job.id);onJob(job);
    }catch(e){onError((e as Error).message);}
    finally{setSubmitting(false);}
  }
  const deviceName=device?.model==='iPhone17,5'?'iPhone 16e':device?.model?.startsWith('iPad')?'iPad':device?.model?.startsWith('iPhone')?'iPhone':'No device connected';
  const unavailableReason=protectedDevice?'This iPhone is protected from changes.':
    !device?'Connect your iPhone to continue.':
    checking?'Checking your iPhone…':
    !preflight?'Check your device before continuing.':
    preflight.waypointInstalled?'Waypoint is already installed. Use Sideload for an update.':
    !device.trusted?'Unlock your iPhone and trust this computer.':
    !preflight.developerMode?'Enable Developer Mode to continue.':
    !status?.nativeReady?'The signing engine is unavailable.':'';
  return <div className="setup-page">
    <div className="setup-intro">
      <h2>Waypoint for iPhone</h2>
      <p>Sign, install, and pair in one session.</p>
      <span className="setup-version">Version 1.5.2</span>
    </div>

    <section className="setup-row" aria-labelledby="device-heading">
      <div className="setup-label"><h3 id="device-heading">Device</h3></div>
      <div className="setup-body">
        <div className="device-heading">
          <div><strong>{deviceName}</strong><p>{device?'iOS '+(device.osVersion||'—')+' · '+device.transport:'Connect your iPhone with a USB cable, then unlock it.'}</p></div>
          {device&&<button type="button" className="text-button" disabled={checking} onClick={()=>setCheckVersion(value=>value+1)}>{checking?'Checking…':'Check again'}</button>}
        </div>
        {checkError&&<p className="error-text device-check-error" role="alert">{checkError}</p>}
        {protectedDevice&&<div className="active-session"><strong>Active session protected</strong><p>Installation and pairing changes are blocked on this iPhone.</p></div>}
        {device&&<dl className="device-checks">
          <div><dt>Computer trust</dt><dd>{device.trusted?'Trusted':'Required'}</dd></div>
          <div><dt>Developer Mode</dt><dd>{preflight?preflight.developerMode?'Enabled':'Required':checking?'Checking…':'Not checked'}</dd></div>
          <div><dt>LocalDevVPN</dt><dd>{preflight?preflight.localDevVPNInstalled?'Installed':'Not installed':checking?'Checking…':'Not checked'}</dd></div>
        </dl>}
        {preflight&&!preflight.developerMode&&!protectedDevice&&<p className="fine-print">Enable Developer Mode in iPhone Settings under Privacy & Security. iOS requires a restart; Waypoint does not restart your device.</p>}
      </div>
    </section>

    <section className="setup-row" aria-labelledby="account-heading">
      <div className="setup-label"><h3 id="account-heading">{running||job?.status==='succeeded'?'Installation':'Apple account'}</h3>{!running&&job?.status!=='succeeded'&&<p>Used to sign the app.</p>}</div>
      <div className="setup-body">
        {job?.status==='succeeded'?<div className="install-finished page-enter"><h3>Installation complete</h3><p>Open Waypoint on your iPhone, then connect LocalDevVPN and approve its VPN configuration.</p><button className="button" onClick={onActivity}>View installation log</button></div>:running?<div className="setup-running page-enter" role="status"><h3>{job?.stage||'Starting setup…'}</h3><p>Keep your iPhone connected and unlocked.</p><div className="installation-progress"><div><button type="button" className="text-button" onClick={onActivity}>View log</button>{job?.progress!==null&&job?.progress!==undefined&&<span>{Math.round(job.progress)}%</span>}</div>{job?.progress!==null&&job?.progress!==undefined&&<div className="progress-track"><span style={{width:Math.max(2,job.progress)+'%'}}/></div>}</div></div>:<form onSubmit={start} className="install-form">
          {accountReady?<p className="account-connected">Your Apple account is connected.</p>:<>
            <label>Email address<input type="email" autoComplete="username" required value={email} disabled={!!running||protectedDevice} onChange={e=>setEmail(e.target.value)} placeholder="you@icloud.com"/></label>
            <label>Password<input type="password" autoComplete="current-password" required value={password} disabled={!!running||protectedDevice} onChange={e=>setPassword(e.target.value)}/></label>
            <p className="fine-print">Apple may ask for a verification code. Your password is not saved.</p>
          </>}
          <div className="collapsible">
            <button type="button" className="disclosure" aria-expanded={advanced} aria-controls="setup-options" onClick={()=>setAdvanced(!advanced)}><span>Advanced options</span><span>{advanced?'Hide':'Show'}</span></button>
            {advanced&&<div id="setup-options" className="expanded form-stack">
              <label>Apple verification service<input type="url" value={service} disabled={!!running} onChange={e=>setEndpoint(e.target.value)} placeholder="https://your-anisette-v3-server"/></label>
              <p className="fine-print">Windows uses an Anisette v3 service for verification data. Your password is sent to Apple. macOS and Linux can use their local provider.</p>
              <div className="preference"><div><strong>Waypoint package</strong><p>{path?'Custom IPA selected':'Bundled version 1.5.2'}</p></div><button type="button" className="button" disabled={!!running} onClick={async()=>{const selected=await window.waypoint?.chooseFile('ipa');if(selected)setPath(selected);}}>Choose IPA</button></div>
            </div>}
          </div>
          <div className="install-action"><button className="button primary" type="submit" disabled={!canInstall}>{protectedDevice?'Device protected':'Install Waypoint'}</button></div>
          {!running&&unavailableReason&&<p className="install-hint">{unavailableReason}</p>}
          {job&&<div className={'installation-progress '+job.status} role="status"><div><span>{job.stage}</span><button type="button" className="text-button" onClick={onActivity}>View log</button></div>{job.progress!==null&&<div className="progress-track"><span style={{width:Math.max(2,job.progress)+'%'}}/></div>}</div>}
        </form>}
        {job&&<ol className="installation-stages" aria-label="Installation steps">{stages.map(({name,from},index)=>{
          const progress=job.progress||0;
          const complete=job.status==='succeeded'||progress>=(stages[index+1]?.from||100);
          const active=!!running&&progress>=from&&!complete;
          return <li className={complete?'complete':active?'active':''} key={name}><span>{name}</span><small>{complete?'Done':active?'In progress':'Pending'}</small></li>;
        })}</ol>}
        {!running&&job?.status!=='succeeded'&&status?.platform==='win32'&&service&&<p className="verification-provider">Verification: {hostname(service)}<button type="button" className="text-button" onClick={()=>setAdvanced(true)}>Change</button></p>}
      </div>
    </section>

    <div className="setup-footnote"><p>After installation, open Waypoint and connect LocalDevVPN on your iPhone.</p><button className="text-button" onClick={()=>window.waypoint?.openExternal('https://apps.apple.com/us/app/localdevvpn/id6755608044')}>Get LocalDevVPN</button></div>
  </div>;
}
