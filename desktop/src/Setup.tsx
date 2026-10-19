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
  const ready=!!device?.trusted&&preflight?.developerMode===true&&!protectedDevice;
  async function check(){
    if(!device||!window.waypoint)return;
    setChecking(true);
    try{setPreflight(await window.waypoint.call<Preflight>('setup.check',{deviceId:device.id}));}
    catch(e){onError((e as Error).message);}
    finally{setChecking(false);}
  }
  useEffect(()=>{setPreflight(null);check();},[device?.id]);
  async function start(e:React.FormEvent){
    e.preventDefault();
    if(!window.waypoint||!device||protectedDevice)return;
    setSubmitting(true);const secret=password;setPassword('');
    try{
      const job=await window.waypoint.call<Job>('setup.start',{deviceId:device.id,email,password:secret,path:path||preflight?.bundledPackage||undefined,anisetteUrl:service||undefined});
      setJobId(job.id);onJob(job);
    }catch(e){onError((e as Error).message);}
    finally{setSubmitting(false);}
  }
  const deviceName=device?.model==='iPhone17,5'?'iPhone 16e':device?.model?.startsWith('iPad')?'iPad':device?.model?.startsWith('iPhone')?'iPhone':'No device connected';
  return <div className="setup-page">
    <div className="setup-summary"><div><h2>Waypoint <span>1.5.2</span></h2><p>Sign in to install the app and transfer its pairing record.</p></div><span className="package-label">iOS application</span></div>
    <div className="setup-columns">
      <section className="setup-main">
        {job?.status==='succeeded'?<div className="install-finished page-enter"><h3>Installation complete</h3><p>Waypoint and its pairing file are on your iPhone. Open Waypoint, then connect LocalDevVPN and approve the VPN configuration.</p><button className="button" onClick={onActivity}>View installation log</button></div>:<form onSubmit={start} className="install-form">
          <div className="section-title"><h3>Apple account</h3><span>{accountReady?'Connected':'Required for signing'}</span></div>
          {accountReady?<p className="account-connected">Your Apple account is connected.</p>:<>
            <label>Email address<input type="email" autoComplete="username" required value={email} disabled={!!running||protectedDevice} onChange={e=>setEmail(e.target.value)} placeholder="you@icloud.com"/></label>
            <label>Password<input type="password" autoComplete="current-password" required value={password} disabled={!!running||protectedDevice} onChange={e=>setPassword(e.target.value)} placeholder="Apple account password"/></label>
            <p className="fine-print">Apple may send a verification code to your trusted device. This build does not save your password.</p>
          </>}
          <div className="install-action"><button className="button primary" type="submit" disabled={!ready||!!running||!status?.nativeReady||(!path&&!preflight?.bundledPackage)||(!accountReady&&status?.platform==='win32'&&!service)}>{protectedDevice?'Device protected':running?'Installing…':'Install Waypoint'}</button><span>Signing and pairing are automatic.</span></div>
          {job&&<div className={'installation-progress '+job.status} role="status"><div><span>{job.stage}</span><button type="button" className="text-button" onClick={onActivity}>View log</button></div>{job.progress!==null&&<div className="progress-track"><span style={{width:Math.max(2,job.progress)+'%'}}/></div>}</div>}
          <div className="collapsible"><button type="button" className="disclosure" aria-expanded={advanced} onClick={()=>setAdvanced(!advanced)}><span>Setup options</span><span>{advanced?'Hide':'Show'}</span></button>
            {advanced&&<div className="expanded form-stack"><label>Apple verification service<input type="url" value={service} disabled={!!running} onChange={e=>setEndpoint(e.target.value)} placeholder="https://your-anisette-v3-server"/></label><p className="fine-print">Windows uses an Anisette v3 service for verification data. Your password is sent to Apple, not to this service. macOS and Linux can use their local provider.</p><div className="preference"><div><strong>Waypoint package</strong><p>{path?'Custom IPA selected':'Bundled version 1.5.2'}</p></div><button type="button" className="button" onClick={async()=>{const selected=await window.waypoint?.chooseFile('ipa');if(selected)setPath(selected);}}>Choose IPA</button></div></div>}
          </div>
          {status?.platform==='win32'&&service&&<p className="verification-provider">Verification service: {hostname(service)}<button type="button" className="text-button" onClick={()=>setAdvanced(true)}>Change</button></p>}
        </form>}
        <ol className="installation-stages" aria-label="Installation steps">{stages.map(({name,from},index)=>{
          const progress=job?.progress||0;
          const complete=job?.status==='succeeded'||progress>=(stages[index+1]?.from||100);
          const active=!!running&&progress>=from&&!complete;
          return <li className={complete?'complete':active?'active':''} key={name}><span className="stage-number">{String(index+1).padStart(2,'0')}</span><span>{name}</span><small>{complete?'Done':active?'In progress':''}</small></li>;
        })}</ol>
      </section>
      <aside className="setup-device-pane">
        <div className="section-title"><h3>Selected device</h3><button className="text-button" onClick={check}>{checking?'Checking…':'Check again'}</button></div>
        <div className="connected-device"><strong>{deviceName}</strong><p>{device?'iOS '+(device.osVersion||'—')+' · '+device.transport:'Connect an iPhone using a USB cable.'}</p></div>
        {protectedDevice&&<div className="active-session"><strong>Active session protected</strong><p>Installation and pairing changes are blocked on this iPhone. Your current Waypoint session is left alone.</p></div>}
        <dl className="requirements"><div><dt>Computer trust</dt><dd>{device?.trusted?'Trusted':device?'Required':'No device'}</dd></div><div><dt>Developer Mode</dt><dd>{preflight?preflight.developerMode?'Enabled':'Required':device?'Checking…':'Not checked'}</dd></div><div><dt>LocalDevVPN</dt><dd>{preflight?preflight.localDevVPNInstalled?'Installed':'Not installed':device?'Checking…':'Not checked'}</dd></div></dl>
        {preflight&&!preflight.developerMode&&<p className="fine-print">Enable Developer Mode in iPhone Settings → Privacy & Security. iOS requires a restart. This app does not restart your device.</p>}
        <div className="device-note"><h3>On your iPhone</h3><p>Keep your phone unlocked during installation. When it finishes, open Waypoint and connect LocalDevVPN.</p><button className="text-button" onClick={()=>window.waypoint?.openExternal('https://apps.apple.com/us/app/localdevvpn/id6755608044')}>LocalDevVPN on the App Store</button><p className="fine-print">VPN connection status is checked inside Waypoint.</p></div>
        {preflight?.waypointInstalled&&!protectedDevice&&<p className="fine-print">Waypoint is already installed. Automatic setup won’t replace an existing installation; use Sideload for an explicit update.</p>}
      </aside>
    </div>
  </div>;
}
