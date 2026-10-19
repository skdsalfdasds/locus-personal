import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import Setup from './Setup';
import type { App as InstalledApp, Device, Job, Package, Pairing, Settings, Status } from './types';

type Page = 'setup'|'sideload'|'applications'|'pairing'|'accounts'|'activity'|'settings';
const navigation: {id:Page;label:string}[] = [
  {id:'setup',label:'Install Waypoint'}, {id:'sideload',label:'Sideload an app'},
  {id:'applications',label:'Applications'}, {id:'pairing',label:'Pairing'},
  {id:'accounts',label:'Accounts'}, {id:'activity',label:'Activity'},
];
const pageTitles:Record<Page,string>={setup:'Install Waypoint',sideload:'Sideload an app',applications:'Applications',pairing:'Pairing',accounts:'Accounts & signing',activity:'Activity',settings:'Settings'};
const deviceName=(d?:Device)=>d?.model==='iPhone17,5'?'iPhone 16e':d?.model?.startsWith('iPad')?'iPad':d?.model?.startsWith('iPhone')?'iPhone':d?.name||'No device';
const size=(n:number)=>(n/1024/1024).toFixed(1)+' MB';
const stateName=(s:Job['status'])=>({queued:'Queued',running:'In progress',succeeded:'Completed',failed:'Failed',cancelled:'Cancelled'}[s]);
function Button({children,kind='',...props}:React.ButtonHTMLAttributes<HTMLButtonElement>&{kind?:string}){
  return <button {...props} className={('button '+kind+' '+(props.className||'')).trim()}>{children}</button>;
}
function Toggle({title,description,value,onChange,disabled=false}:{title:string;description?:string;value:boolean;onChange:()=>void;disabled?:boolean}){
  return <div className="preference"><div><strong>{title}</strong>{description&&<p>{description}</p>}</div><button className="toggle" role="switch" aria-label={title} aria-checked={value} disabled={disabled} onClick={onChange}>{value?'On':'Off'}</button></div>;
}
function Dialog({title,description,onClose,children,wide=false}:{title:string;description?:string;onClose:()=>void;children:ReactNode;wide?:boolean}){
  const ref=useRef<HTMLDialogElement>(null);
  useEffect(()=>{ref.current?.showModal();},[]);
  return <dialog ref={ref} className={'dialog '+(wide?'wide':'')} onCancel={e=>{e.preventDefault();onClose();}}>
    <div className="dialog-heading"><div><h2>{title}</h2>{description&&<p>{description}</p>}</div><button className="text-button muted" onClick={onClose}>Close</button></div>{children}
  </dialog>;
}
function Empty({title,children}:{title:string;children?:ReactNode}){
  return <div className="empty"><h3>{title}</h3>{children&&<p>{children}</p>}</div>;
}

export default function App(){
  const [page,setPage]=useState<Page>('setup');
  const [status,setStatus]=useState<Status|null>(null);
  const [devices,setDevices]=useState<Device[]>([]);
  const [selected,setSelected]=useState('');
  const [apps,setApps]=useState<InstalledApp[]>([]);
  const [jobs,setJobs]=useState<Job[]>([]);
  const [pairings,setPairings]=useState<Pairing[]>([]);
  const [error,setError]=useState('');
  const [notice,setNotice]=useState('');
  const [busy,setBusy]=useState('');
  const [search,setSearch]=useState('');
  const [pkg,setPkg]=useState<Package|null>(null);
  const [mode,setMode]=useState('appleId');
  const [options,setOptions]=useState<Record<string,any>>({});
  const [plistText,setPlistText]=useState('');
  const [advanced,setAdvanced]=useState(false);
  const [login,setLogin]=useState(false);
  const [email,setEmail]=useState('');
  const [password,setPassword]=useState('');
  const [prompt,setPrompt]=useState<any>(null);
  const [code,setCode]=useState('');
  const [certificate,setCertificate]=useState('');
  const [certificatePassword,setCertificatePassword]=useState('');
  const [identityId,setIdentityId]=useState('');
  const [profileId,setProfileId]=useState('');
  const [pairKind,setPairKind]=useState<'remote'|'lockdown'>('remote');
  const [pairTarget,setPairTarget]=useState<Pairing|null>(null);
  const [targetBundle,setTargetBundle]=useState('');
  const [targetFilename,setTargetFilename]=useState('pairingFile.plist');
  const [pairDestinations,setPairDestinations]=useState<{bundleId:string;name:string;recommendedPath:string|null;supportedPaths:string[]}[]>([]);
  const [deleteApp,setDeleteApp]=useState<InstalledApp|null>(null);
  const [details,setDetails]=useState<Job|null>(null);
  const [accountData,setAccountData]=useState<any>(null);
  const device=devices.find(d=>d.id===selected)||devices[0];
  const hidden=status?.settings.hideSensitive??true;
  const blocked=!!device?.protected;
  const running=jobs.filter(j=>j.status==='running'||j.status==='queued');
  const call=useCallback(async<T,>(method:string,params:Record<string,unknown>={}):Promise<T>=>{
    if(!window.waypoint)throw new Error('Open Waypoint Desktop to use device services.');
    return window.waypoint.call<T>(method,params);
  },[]);
  const addJob=(job:Job)=>setJobs(items=>[job,...items.filter(j=>j.id!==job.id)]);
  async function perform(name:string,fn:()=>Promise<unknown>){
    setBusy(name);setError('');
    try{return await fn();}catch(e){setError((e as Error).message);}finally{setBusy('');}
  }
  const refresh=useCallback(async()=>{
    try{
      const [s,d,j,p]=await Promise.all([call<Status>('system.status'),call<Device[]>('devices.list'),call<Job[]>('jobs.list'),call<Pairing[]>('pairings.list')]);
      setStatus(s);setDevices(d);setJobs(j);setPairings(p);
    }catch(e){setError((e as Error).message);}
  },[call]);
  useEffect(()=>{refresh();const timer=setInterval(refresh,10000);return()=>clearInterval(timer);},[refresh]);
  useEffect(()=>{
    if(!device){setApps([]);return;}
    let current=true;
    call<InstalledApp[]>('apps.list',{deviceId:device.id}).then(data=>{if(current)setApps(data);}).catch(e=>setError(e.message));
    return()=>{current=false;};
  },[device?.id,call]);
  useEffect(()=>window.waypoint?.onEvent(event=>{
    if(event.event==='job')addJob(event.job);
    if(event.event==='prompt'){setPrompt(event);setCode('');}
    if(event.event==='backendError')setError(event.message);
  }),[]);
  useEffect(()=>{
    const theme=status?.settings.theme;
    document.documentElement.dataset.theme=theme==='dark'||(theme==='system'&&matchMedia('(prefers-color-scheme: dark)').matches)?'dark':'light';
  },[status?.settings.theme]);
  useEffect(()=>{if(!notice)return;const timer=setTimeout(()=>setNotice(''),5000);return()=>clearTimeout(timer);},[notice]);
  async function saveSettings(update:Partial<Settings>){
    const settings=await call<Settings>('settings.save',update);
    setStatus(s=>s?{...s,settings}:s);
  }
  async function loadPackage(path?:string){
    const chosen=path||await window.waypoint?.chooseFile('ipa');if(!chosen)return;
    await perform('inspect',async()=>{
      const data=await call<Package>('ipa.inspect',{path:chosen});
      setPkg(data);setOptions({});setPlistText('');setPage('sideload');
    });
  }
  async function install(){
    if(!pkg)return;
    await perform('install',async()=>{
      let custom={};
      if(plistText.trim()){
        custom=JSON.parse(plistText);
        if(!custom||Array.isArray(custom)||typeof custom!=='object')throw new Error('Info.plist changes must be a JSON object.');
      }
      const allOptions={...options,...(Object.keys(custom).length?{plistChanges:custom}:{})};
      if(mode==='export'){
        const destination=await window.waypoint?.saveFile(pkg.name+'-modified.ipa');if(!destination)return;
        await call('ipa.prepare',{path:pkg.path,destination,options:allOptions});
        setNotice('Modified IPA exported. Sign it before installation.');return;
      }
      if(!device)return;
      if(mode==='appleId'&&!status?.account){setLogin(true);return;}
      const job=await call<Job>('install.start',{path:pkg.path,name:pkg.name,deviceId:device.id,deviceName:device.name,mode,identityId,profileId:profileId||undefined,options:Object.keys(allOptions).length?allOptions:undefined});
      addJob(job);setPage('activity');
    });
  }
  async function signIn(e:React.FormEvent){
    e.preventDefault();const secret=password;setPassword('');
    await perform('login',async()=>{
      await call('account.login',{email,password:secret,anisetteUrl:status?.settings.anisetteUrl||undefined});
      setLogin(false);setNotice('Signed in to Apple.');await refresh();
    });
  }
  async function importIdentity(e:React.FormEvent){
    e.preventDefault();const secret=certificatePassword;setCertificatePassword('');
    await perform('identity',async()=>{
      const result=await call<any>('identity.import',{path:certificate,password:secret});
      setIdentityId(result.identity?.id||'');setCertificate('');setNotice('Signing certificate imported.');
    });
  }
  async function importProfile(){
    const path=await window.waypoint?.chooseFile('profile');if(!path)return;
    await perform('profile',async()=>{
      const result=await call<any>('profile.import',{path,deviceId:device?.id});
      setProfileId(result.profile?.uuid||'');setNotice('Provisioning profile imported.');
    });
  }
  async function importPairing(){
    const path=await window.waypoint?.chooseFile('pairing');if(!path)return;
    await perform('importPairing',async()=>{
      const record=await call<Pairing>('pairing.import',{path,deviceId:device?.id});
      setPairings(items=>[record,...items.filter(p=>p.id!==record.id)]);
      setNotice('Pairing record imported locally. Validate it on its device before transferring.');
    });
  }
  async function showPairingDestinations(pair:Pairing){
    if(!device)return;
    await perform('destinations',async()=>{
      const destinations=await call<typeof pairDestinations>('pairing.destinations',{kind:pair.kind,deviceId:device.id});
      setPairDestinations(destinations);setTargetBundle('');setTargetFilename('pairingFile.plist');setPairTarget(pair);
    });
  }
  const dropZone=<div className="drop-zone" onDragOver={e=>{e.preventDefault();e.currentTarget.dataset.drag='true';}} onDragLeave={e=>delete e.currentTarget.dataset.drag} onDrop={e=>{
    e.preventDefault();delete e.currentTarget.dataset.drag;const file=e.dataTransfer.files[0];
    if(file&&window.waypoint)loadPackage(window.waypoint.pathForFile(file));
  }}><h3>{busy==='inspect'?'Reading package…':'Drop an IPA here'}</h3><p>Or choose a file from your computer.</p><Button onClick={()=>loadPackage()}>Choose IPA</Button></div>;
  const filteredApps=apps.filter(a=>(a.name+' '+a.bundleId).toLowerCase().includes(search.toLowerCase()));

  return <div className="app-shell">
    <aside className="sidebar">
      <div className="wordmark">Waypoint<span>Desktop</span></div>
      <nav aria-label="Workspace">{navigation.map(({id,label})=><button key={id} className={page===id?'selected':''} aria-current={page===id?'page':undefined} onClick={()=>{setPage(id);setSearch('');}}><span>{label}</span>{id==='activity'&&running.length>0&&<small>{running.length}</small>}</button>)}</nav>
      <div className="sidebar-bottom"><button className={page==='settings'?'selected':''} onClick={()=>setPage('settings')}>Settings</button><button onClick={()=>window.waypoint?.openExternal('https://github.com/jkcoxson/idevice_pair#usage')}>Help & documentation</button><p>Version {status?.version||'0.1.0'}<span>Development build</span></p></div>
    </aside>
    <div className="workspace">
      <header className="workspace-header"><h1>{pageTitles[page]}</h1><div><button className="text-button muted" onClick={()=>perform('refresh',refresh)}>{busy==='refresh'?'Checking…':'Refresh'}</button><select aria-label="Selected device" value={device?.id||''} onChange={e=>setSelected(e.target.value)}><option value="" disabled>No device connected</option>{devices.map(d=><option key={d.id} value={d.id}>{hidden?deviceName(d):d.name}</option>)}</select></div></header>
      <main key={page} className="page-enter">
        {error&&<div className="message error" role="alert"><p>{error}</p><button className="text-button" onClick={()=>setError('')}>Dismiss</button></div>}
        {blocked&&page!=='setup'&&<div className="protection-strip">This iPhone is protected. Installation, pairing changes, and device settings changes are disabled.</div>}
        {page==='setup'&&<Setup device={device} status={status} jobs={jobs} onJob={addJob} onError={setError} onActivity={()=>setPage('activity')}/>}
        {page==='sideload'&&<div className="split-layout"><section className="content-column">
          <div className="section-title"><h2>Application package</h2>{pkg&&<button className="text-button" onClick={()=>loadPackage()}>Change file</button>}</div>
          {pkg?<><div className="package-name"><strong>{pkg.name}</strong><span>{pkg.version}</span></div><dl className="facts"><div><dt>Bundle ID</dt><dd className="mono">{pkg.bundleId}</dd></div><div><dt>Size</dt><dd>{size(pkg.size)}</dd></div><div><dt>Minimum iOS</dt><dd>{pkg.minimumOS||'Not specified'}</dd></div><div><dt>Extensions</dt><dd>{pkg.extensions.length}</dd></div><div><dt>Provisioning</dt><dd>{pkg.signed?'Embedded profile found':'No embedded profile'}</dd></div><div><dt>File</dt><dd>{pkg.filename}</dd></div></dl></>:dropZone}
          <div className="collapsible"><button className="disclosure" aria-expanded={advanced} onClick={()=>setAdvanced(!advanced)}><span>Customization</span><span>{advanced?'Hide':'Show'}</span></button>
          {advanced&&<div className="expanded form-stack">
            <div className="field-grid">{[['appName','App name',pkg?.name],['bundleId','Bundle identifier',pkg?.bundleId],['version','App version',pkg?.version],['minimumOS','Minimum iOS',pkg?.minimumOS]].map(([key,label,placeholder])=><label key={key}>{label}<input value={options[key!]||''} placeholder={placeholder||'Keep original'} onChange={e=>setOptions({...options,[key!]:e.target.value})}/></label>)}</div>
            <Toggle title="File sharing" description="Expose the app’s Documents folder." value={!!options.fileSharing} onChange={()=>setOptions({...options,fileSharing:!options.fileSharing})}/>
            <Toggle title="Remove device restrictions" description="Changes metadata, not code compatibility." value={!!options.removeDeviceRestrictions} onChange={()=>setOptions({...options,removeDeviceRestrictions:!options.removeDeviceRestrictions})}/>
            <Toggle title="Remove all extensions" value={!!options.removeAllExtensions} onChange={()=>setOptions({...options,removeAllExtensions:!options.removeAllExtensions})}/>
            {!!pkg?.extensions.length&&<fieldset><legend>Remove individual extensions</legend>{pkg.extensions.map(ext=><label className="checkbox" key={ext.path}><input type="checkbox" checked={(options.removeExtensions||[]).includes(ext.path)} onChange={e=>setOptions({...options,removeExtensions:e.target.checked?[...(options.removeExtensions||[]),ext.path]:(options.removeExtensions||[]).filter((p:string)=>p!==ext.path)})}/>{ext.name}</label>)}</fieldset>}
            <div className="preference"><div><strong>App icon file</strong><p>{options.iconPath?'Replacement image selected':'Keep the package’s existing image.'}</p></div><Button onClick={async()=>{const path=await window.waypoint?.chooseFile('icon');if(path)setOptions({...options,iconPath:path});}}>Choose image</Button></div>
            <label>Info.plist changes<textarea value={plistText} onChange={e=>setPlistText(e.target.value)} spellCheck={false} placeholder={'{ "ExampleKey": true }'}/><small>JSON object. Executable and package identity keys are protected.</small></label>
            <p className="muted-text">Tweak injection, custom entitlements, and ad-hoc signing are not implemented in this build.</p>
          </div>}</div>
        </section><aside className="detail-column">
          <h2>Signing & installation</h2><label>Method<select value={mode} onChange={e=>setMode(e.target.value)}><option value="appleId">Apple account</option><option value="certificate">Certificate and profile</option><option value="existing">Install as signed</option><option value="export">Export modified IPA</option></select></label>
          {mode==='appleId'&&<div className="detail-row"><span>{status?.account?'Apple account connected':'No account connected'}</span><button className="text-button" onClick={()=>setLogin(true)}>{status?.account?'Change':'Sign in'}</button></div>}
          {mode==='certificate'&&<div className="form-stack"><Button onClick={async()=>setCertificate(await window.waypoint?.chooseFile('certificate')||'')}>{identityId?'Certificate selected':'Import certificate'}</Button><Button onClick={importProfile}>{profileId?'Profile selected':'Import profile'}</Button></div>}
          <dl className="facts"><div><dt>Device</dt><dd>{deviceName(device)}</dd></div><div><dt>Connection</dt><dd>{device?.transport||'Disconnected'}</dd></div></dl>
          <Button kind="primary full" disabled={!pkg||!!busy||(mode!=='export'&&(!device||blocked))||(mode!=='existing'&&mode!=='export'&&!status?.nativeReady)||(mode==='certificate'&&!identityId)} onClick={install}>{busy==='install'?'Working…':mode==='export'?'Export IPA':blocked?'Device protected':'Install application'}</Button>
          <p className="fine-print">{mode==='export'?'Exports an unsigned copy. The original file is preserved.':'A free developer profile typically needs renewal every seven days. Apple account limits apply.'}</p>
        </aside></div>}
        {page==='applications'&&<section><div className="list-toolbar"><span>{apps.length} applications</span><input aria-label="Search installed apps" placeholder="Filter applications" value={search} onChange={e=>setSearch(e.target.value)}/></div>
          {apps.length?<div className="table-scroll"><table><thead><tr><th>Application</th><th>Version</th><th>Managed by</th><th>File sharing</th><th/></tr></thead><tbody>{filteredApps.map(app=><tr key={app.bundleId}><td><strong>{app.name}</strong>{!hidden&&<small className="mono">{app.bundleId}</small>}</td><td>{app.version||'—'}</td><td>{app.managed?'Waypoint':'—'}</td><td>{app.fileSharing?'Available':'—'}</td><td><button className="text-button danger" disabled={blocked} onClick={()=>setDeleteApp(app)}>Uninstall</button></td></tr>)}</tbody></table>{filteredApps.length===0&&<Empty title="No matching applications"/>}</div>:<Empty title="No applications to show">Connect a trusted device to view its apps.</Empty>}
        </section>}
        {page==='pairing'&&<div className="split-layout"><section className="content-column"><h2>Create a pairing record</h2><p className="section-description">Choose the format required by the app you’re pairing.</p>
          <div className="segmented">{(['remote','lockdown'] as const).map(kind=><button className={pairKind===kind?'selected':''} key={kind} onClick={()=>setPairKind(kind)}>{kind==='remote'?'Remote pairing':'Lockdown'}</button>)}</div>
          <p className="muted-text">{pairKind==='remote'?'Used by Waypoint and apps that connect through a developer tunnel. Requires iOS 17.4 or later.':'Standard pairing for compatible sideloaders and trusted device tools.'}</p>
          <Button kind="primary" disabled={!device||blocked||!!busy||(pairKind==='remote'&&!status?.nativeReady)} onClick={()=>device&&perform('pairing',async()=>{
            const pair=await call<Pairing>(pairKind==='remote'?'pairing.createRemote':'pairing.createLockdown',{deviceId:device.id});setPairings(items=>[pair,...items]);setNotice('Pairing record saved on this computer.');
          })}>{busy==='pairing'?'Creating…':pairKind==='remote'?'Create remote pairing':'Create lockdown pairing'}</Button>
          <p className="fine-print">Pairing records contain private credentials. Export only to apps you trust.</p>
          <div className="section-rule"><h2>Connection settings</h2><Toggle title="Wireless debugging" description="Requires an initial trusted USB connection." value={!!device?.wirelessDebugging} disabled={!device||blocked||!!busy} onChange={()=>device&&perform('wireless',async()=>{await call('device.enableWireless',{deviceId:device.id,enabled:!device.wirelessDebugging});await refresh();})}/><div className="detail-row"><span>Developer Mode</span><span>{device?.developerMode?'Enabled':'Not confirmed'}</span></div></div>
          <p className="muted-text">Pairing validation authenticates the saved record without creating a new pairing. Network PIN onboarding is still in development.</p>
        </section><aside className="detail-column"><div className="section-title"><h2>Saved records <span className="count">{pairings.length}</span></h2><button className="text-button" disabled={!!busy} onClick={importPairing}>{busy==='importPairing'?'Importing…':'Import record'}</button></div>
          {pairings.length?pairings.map(pair=><div className="record" key={pair.id}><strong>{pair.kind==='remote'?'Remote pairing':'Lockdown'}</strong><p>{new Date(pair.created).toLocaleString()}<br/>{pair.source==='imported'&&!pair.bindingVerified?'Imported · device validation needed':pair.lastValidated?'Validated '+new Date(pair.lastValidated).toLocaleDateString():'Created on its device'}</p><div className="row-actions"><button className="text-button" onClick={async()=>{const destination=await window.waypoint?.saveFile(pair.kind==='remote'?'pairingFile.plist':'pairing.mobiledevicepairing');if(destination)perform('exportPairing',async()=>{await call('pairing.export',{pairingId:pair.id,destination});setNotice('Pairing record exported.');});}}>Export</button><button className="text-button" disabled={!device||blocked||!!busy} onClick={()=>device&&perform('validatePairing',async()=>{const verified=await call<Pairing>('pairing.validate',{pairingId:pair.id,deviceId:device.id});setPairings(items=>items.map(p=>p.id===verified.id?verified:p));setNotice('The selected device accepted this pairing record.');})}>{busy==='validatePairing'?'Validating…':'Validate'}</button><button className="text-button" disabled={!device||blocked||!!busy||(pair.source==='imported'&&!pair.bindingVerified)} onClick={()=>showPairingDestinations(pair)}>Send to app</button></div></div>):<p className="muted-text">No records saved.</p>}
        </aside></div>}
        {page==='accounts'&&<div className="split-layout"><section className="content-column"><h2>Apple account</h2><p className="section-description">{status?.account?hidden?'An Apple account is connected.':status.account.email:'Sign in when you’re ready to sign an application.'}</p><div className="row-actions"><Button kind="primary" disabled={!status?.nativeReady} onClick={()=>setLogin(true)}>{status?.account?'Sign in with another account':'Sign in to Apple'}</Button>{status?.account&&<Button onClick={()=>perform('logout',async()=>{await call('account.logout');await refresh();})}>Sign out</Button>}</div>
          <div className="section-rule"><h2>Developer account</h2><div className="preference"><div><strong>Development certificates</strong><p>Read the certificates registered on your team.</p></div><Button disabled={!status?.account||!!busy} onClick={()=>perform('certificates',async()=>setAccountData(await call('account.certificates')))}>View certificates</Button></div><div className="preference"><div><strong>App identifiers</strong><p>Read registered App IDs and account limits.</p></div><Button disabled={!status?.account||!!busy} onClick={()=>perform('appIds',async()=>setAccountData(await call('account.appIds')))}>View App IDs</Button></div></div>
        </section><aside className="detail-column"><h2>Certificate signing</h2><p className="muted-text">Use an exported .p12 certificate and its provisioning profile instead of Apple account sign-in.</p><div className="form-stack"><Button onClick={async()=>setCertificate(await window.waypoint?.chooseFile('certificate')||'')}>Import .p12 certificate</Button><Button onClick={importProfile}>Import provisioning profile</Button></div><p className="fine-print">The certificate password is discarded after import. Signing material stays on this computer.</p></aside></div>}
        {page==='activity'&&<section>{jobs.length?<div className="table-scroll"><table><thead><tr><th>Operation</th><th>Status</th><th>Progress</th><th>Started</th><th/></tr></thead><tbody>{jobs.map(job=><tr key={job.id}><td><strong>{job.name}</strong><small>{job.stage}</small></td><td><span className={'job-state '+job.status}>{stateName(job.status)}</span></td><td>{job.progress===null?'—':Math.round(job.progress)+'%'}</td><td>{new Date(job.started).toLocaleString()}</td><td><div className="row-actions"><button className="text-button" onClick={()=>setDetails(job)}>Details</button>{['queued','running'].includes(job.status)&&<button className="text-button" onClick={()=>perform('cancel',()=>call('jobs.cancel',{jobId:job.id}))}>Cancel</button>}</div></td></tr>)}</tbody></table></div>:<Empty title="No activity yet">Your installation progress and logs will appear here.</Empty>}</section>}
        {page==='settings'&&<div className="settings-layout"><section><h2>Appearance</h2><div className="preference"><div><strong>Theme</strong><p>Choose an appearance for the desktop app.</p></div><div className="segmented compact">{(['light','dark'] as const).map(theme=><button key={theme} className={status?.settings.theme===theme?'selected':''} onClick={()=>perform('theme',()=>saveSettings({theme}))}>{theme==='light'?'Light':'Dark'}</button>)}</div></div><Toggle title="Hide identifiers" description="Hide account emails and device identifiers." value={hidden} onChange={()=>perform('privacy',()=>saveSettings({hideSensitive:!hidden}))}/>
          <div className="section-rule"><h2>Apple verification</h2><label>Anisette v3 service<input type="url" key={status?.settings.anisetteUrl} defaultValue={status?.settings.anisetteUrl} onBlur={e=>perform('settings',()=>saveSettings({anisetteUrl:e.target.value}))}/></label><p className="fine-print">Windows uses this service for verification data. Your password is sent to Apple through the local signing engine. macOS and Linux can use their bundled local provider.</p></div>
          <div className="section-rule"><h2>Background tasks</h2><Toggle title="Automatic app refresh" description="Not active in this development build." value={false} disabled onChange={()=>{}}/><Toggle title="Start at login" description="Available when the refresh service is integrated." value={false} disabled onChange={()=>{}}/></div>
        </section><aside className="detail-column"><h2>About</h2><dl className="facts"><div><dt>Version</dt><dd>{status?.version||'0.1.0'}</dd></div><div><dt>Platform</dt><dd>{status?.platform==='win32'?'Windows':status?.platform==='darwin'?'macOS':status?.platform||'—'}</dd></div><div><dt>Device service</dt><dd>{status?'Available':'Disconnected'}</dd></div><div><dt>Signing engine</dt><dd>{status?.nativeReady?'Available':'Not built'}</dd></div></dl>{status&&<button className="text-button" onClick={()=>window.waypoint?.reveal(status.dataDirectory)}>Open local workspace folder</button>}<p className="fine-print">Full Sideloadly and idevice_pair feature parity is still in development.</p></aside></div>}
      </main>
      <footer className="statusbar"><span>{status?'Device service online':'Connecting to device service…'}</span><span>{blocked?'Device changes blocked':device?deviceName(device)+' · '+device.transport:'No device connected'}</span></footer>
    </div>
    {notice&&<div className="toast" role="status">{notice}</div>}
    {login&&<Dialog title="Sign in to Apple" description="Sign applications with a free or paid developer account." onClose={()=>{setLogin(false);setPassword('');}}><form className="form-stack" onSubmit={signIn}><label>Apple account<input type="email" autoComplete="username" required value={email} onChange={e=>setEmail(e.target.value)}/></label><label>Password<input type="password" autoComplete="current-password" required value={password} onChange={e=>setPassword(e.target.value)}/></label><p className="fine-print">The password is passed to the local signing engine and is not saved by this build.</p>{status?.platform==='win32'&&<p className="fine-print">Verification service: {status.settings.anisetteUrl||'Not configured'}</p>}<div className="dialog-actions"><Button type="button" onClick={()=>{setLogin(false);setPage('settings');}}>Signing settings</Button><Button kind="primary" type="submit" disabled={!!busy||(status?.platform==='win32'&&!status.settings.anisetteUrl)}>{busy==='login'?'Signing in…':'Sign in'}</Button></div></form></Dialog>}
    {prompt&&<Dialog title="Verify your Apple account" description="Enter the code shown on your trusted device." onClose={()=>{call('prompt.reply',{promptId:prompt.promptId,answer:{action:'abort'}});setPrompt(null);}}><form className="form-stack" onSubmit={e=>{e.preventDefault();call('prompt.reply',{promptId:prompt.promptId,answer:{action:'submit',code}});setPrompt(null);setCode('');}}><label>Verification code<input className="verification-code" inputMode="numeric" autoComplete="one-time-code" autoFocus maxLength={6} value={code} onChange={e=>setCode(e.target.value.replace(/\D/g,''))}/></label>{prompt.detail?.lastError&&<p className="error-text">{prompt.detail.lastError}</p>}<div className="dialog-actions"><Button type="button" onClick={()=>{call('prompt.reply',{promptId:prompt.promptId,answer:{action:'resend'}});setPrompt(null);}}>Send another code</Button><Button kind="primary" disabled={code.length!==6} type="submit">Verify</Button></div></form></Dialog>}
    {!!certificate&&<Dialog title="Import certificate" description="Unlock the .p12 certificate and its private key." onClose={()=>{setCertificate('');setCertificatePassword('');}}><form className="form-stack" onSubmit={importIdentity}><label>Certificate password<input type="password" autoFocus value={certificatePassword} onChange={e=>setCertificatePassword(e.target.value)}/></label><p className="fine-print">Leave blank if the certificate has no password.</p><div className="dialog-actions"><Button kind="primary" type="submit" disabled={!!busy}>{busy?'Importing…':'Import certificate'}</Button></div></form></Dialog>}
    {deleteApp&&<Dialog title={'Uninstall '+deleteApp.name+'?'} description="This removes the application and its local data from the phone." onClose={()=>setDeleteApp(null)}><p className="muted-text">Install updates over an existing app when you need to keep its data.</p><div className="dialog-actions"><Button onClick={()=>setDeleteApp(null)}>Keep application</Button><Button kind="destructive" disabled={blocked||!!busy} onClick={()=>perform('uninstall',async()=>{await call('app.uninstall',{deviceId:deleteApp.deviceId,bundleId:deleteApp.bundleId,confirmation:deleteApp.bundleId});setApps(items=>items.filter(a=>a.bundleId!==deleteApp.bundleId));setDeleteApp(null);setNotice('Application uninstalled.');})}>Uninstall</Button></div></Dialog>}
    {pairTarget&&<Dialog title="Send pairing to an app" description="Transfers the record into the selected app’s Documents folder." onClose={()=>setPairTarget(null)}><div className="form-stack"><label>Application<select value={targetBundle} onChange={e=>{const bundle=e.target.value;setTargetBundle(bundle);setTargetFilename(pairDestinations.find(a=>a.bundleId===bundle)?.recommendedPath||'pairingFile.plist');}}><option value="">Select an application</option>{pairDestinations.map(a=><option key={a.bundleId} value={a.bundleId}>{a.name}</option>)}</select></label><label>Filename<select value={targetFilename} onChange={e=>setTargetFilename(e.target.value)}>{['pairingFile.plist','waypoint-setup-pairing.plist','ALTPairingFile.mobiledevicepairing','rpPairingFile.plist','SideStore/Documents/ALTPairingFile.mobiledevicepairing'].map(name=><option key={name}>{name}</option>)}</select></label><p className="fine-print">Replaces a file with the same name. A Waypoint setup file never replaces an existing saved pairing automatically.</p><div className="dialog-actions"><Button kind="primary" disabled={!targetBundle||blocked||!!busy} onClick={()=>perform('transfer',async()=>{await call('pairing.install',{deviceId:device?.id,bundleId:targetBundle,pairingId:pairTarget.id,filename:targetFilename});setPairTarget(null);setNotice('Pairing record transferred.');})}>Send pairing</Button></div></div></Dialog>}
    {accountData&&<Dialog title="Developer account information" description="Current response from Apple." onClose={()=>setAccountData(null)} wide>{hidden?<><p className="muted-text">Identifiers are hidden. Show them to view the full account response.</p><div className="dialog-actions"><Button onClick={()=>perform('privacy',()=>saveSettings({hideSensitive:false}))}>Show identifiers</Button></div></>:<pre className="code-block">{JSON.stringify(accountData,null,2)}</pre>}</Dialog>}
    {details&&<Dialog title={details.name} description={stateName((jobs.find(j=>j.id===details.id)||details).status)} onClose={()=>setDetails(null)} wide><div className="log-lines">{(jobs.find(j=>j.id===details.id)||details).logs.map((line,index)=><div key={index}><time>{new Date(line.time).toLocaleTimeString()}</time><p>{line.message}</p></div>)}</div></Dialog>}
  </div>;
}
