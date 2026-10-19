use std::{collections::HashMap, io::{self, BufRead, Write}, path::{Path, PathBuf}, sync::{Arc, Mutex, atomic::{AtomicU64, Ordering}, mpsc}, time::Duration};
use apparition_core::api::{self, Session, TwoFactorCallbackResponse};
use idevice::{IdeviceService, provider::IdeviceProvider, lockdown::LockdownClient, remote_pairing::{RpPairingFile, RemotePairingLockdownService}, usbmuxd::{UsbmuxdAddr, UsbmuxdConnection, Connection}};
use serde_json::{Value, json};

type Replies = Arc<Mutex<HashMap<u64, mpsc::SyncSender<Value>>>>;
static NEXT_PROMPT: AtomicU64 = AtomicU64::new(1);
fn emit(value: Value) { let mut out = io::stdout().lock(); let _ = writeln!(out, "{value}"); let _ = out.flush(); }
fn text<'a>(p: &'a Value, key: &str) -> Result<&'a str, String> { p[key].as_str().filter(|s| !s.is_empty()).ok_or_else(|| format!("Missing {key}")) }
fn safe_id(id: &str) -> Result<(), String> { if id.len() > 128 || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') { Err("Invalid device identifier".into()) } else { Ok(()) } }
fn progress(id: &Value, message: &str) { emit(json!({"event":"progress", "requestId":id, "message":message})); }
fn ask(id: &Value, replies: &Replies, kind: &str, detail: Value) -> Value {
    let prompt = NEXT_PROMPT.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = mpsc::sync_channel(1);
    replies.lock().unwrap().insert(prompt, tx);
    emit(json!({"event":"prompt", "requestId":id, "promptId":prompt,"kind":kind,"detail":detail}));
    let result = rx.recv_timeout(Duration::from_secs(180)).unwrap_or(Value::Null);
    replies.lock().unwrap().remove(&prompt);
    result
}
async fn provider(udid: &str) -> Result<idevice::provider::UsbmuxdProvider, String> {
    let mut mux = UsbmuxdConnection::default().await.map_err(|e| e.to_string())?;
    let devices = mux.get_devices().await.map_err(|e| e.to_string())?;
    let device = devices.iter().filter(|d| d.udid == udid).min_by_key(|d| !matches!(d.connection_type, Connection::Usb)).ok_or("Device is disconnected")?;
    Ok(device.to_provider(UsbmuxdAddr::default(), "Waypoint Desktop"))
}
async fn devices() -> Result<Value, String> {
    let mut mux = UsbmuxdConnection::default().await.map_err(|e| format!("Cannot reach Apple device service: {e}"))?;
    let list = mux.get_devices().await.map_err(|e| e.to_string())?;
    let mut result: Vec<Value> = Vec::new();
    for d in list {
        if result.iter().any(|v| v["id"].as_str() == Some(&d.udid)) { continue }
        let p = d.to_provider(UsbmuxdAddr::default(), "Waypoint Desktop");
        let mut item = json!({"id":d.udid,"name":"Apple device","transport":if matches!(d.connection_type,Connection::Usb){"USB"}else{"Wi-Fi"},"trusted":false});
        if let Ok(mut client) = LockdownClient::connect(&p).await {
            for (key, field) in [("DeviceName","name"),("ProductType","model"),("ProductVersion","osVersion")] {
                if let Ok(v) = client.get_value(Some(key),None).await { if let Some(s)=v.as_string(){ item[field]=json!(s); } }
            }
            item["trusted"] = json!(p.get_pairing_file().await.is_ok());
            if let Ok(v)=client.get_value(Some("DeveloperModeStatus"),Some("com.apple.security.mac.amfi")).await { item["developerMode"]=json!(v.as_boolean()); }
        }
        result.push(item);
    }
    Ok(json!(result))
}
async fn dispatch(id: &Value, method: &str, p: &Value, data: &Path, session: &mut Option<Session>, replies: &Replies) -> Result<Value,String> {
    match method {
        "ping" => Ok(json!({"engine":"waypoint-native","version":env!("CARGO_PKG_VERSION"),"builtinAnisette":api::builtin_anisette_available()})),
        "devices.list" => devices().await,
        "pairing.validate" => {
            let udid=text(p,"deviceId")?; safe_id(udid)?;
            let provider=provider(udid).await?;
            let bytes=std::fs::read(text(p,"path")?).map_err(|_|"Cannot read the pairing record".to_string())?;
            match p["kind"].as_str() {
                Some("remote") => {
                    let mut record=RpPairingFile::from_bytes(&bytes).map_err(|_|"The remote pairing record is invalid".to_string())?;
                    let mut client=RemotePairingLockdownService::connect(&provider).await.map_err(|e|e.to_string())?
                        .into_client("Waypoint Desktop").map_err(|e|e.to_string())?;
                    client.attempt_pair_verify().await.map_err(|e|e.to_string())?;
                    client.validate_pairing(&mut record).await.map_err(|e|e.to_string())?;
                },
                Some("lockdown") => {
                    let record=idevice::pairing_file::PairingFile::from_bytes(&bytes).map_err(|_|"The Lockdown record is invalid".to_string())?;
                    if record.udid.as_deref().is_some_and(|record_id|!record_id.eq_ignore_ascii_case(udid)) {
                        return Err("This Lockdown record belongs to a different device".into());
                    }
                    let mut client=LockdownClient::connect(&provider).await.map_err(|e|e.to_string())?;
                    client.start_session(&record).await.map_err(|e|e.to_string())?;
                    client.stop_session().await.map_err(|e|e.to_string())?;
                },
                _ => return Err("Choose a supported pairing format".into())
            }
            Ok(json!({"valid":true}))
        },
        "pairing.createRemote" => {
            let udid=text(p,"deviceId")?; safe_id(udid)?;
            let mut record=RpPairingFile::generate("Waypoint Desktop");
            progress(id,"Creating a remote pairing record. Keep your device unlocked.");
            let provider=provider(udid).await?;
            for _ in 0..2 {
                RemotePairingLockdownService::connect(&provider).await.map_err(|e|e.to_string())?
                    .into_client("Waypoint Desktop").map_err(|e|e.to_string())?
                    .connect(&mut record, async || "000000".to_string()).await.map_err(|e|e.to_string())?;
            }
            let dir=data.join("pairings"); std::fs::create_dir_all(&dir).map_err(|e|e.to_string())?;
            let path=dir.join(format!("{udid}.remote.plist"));
            std::fs::write(&path,record.to_bytes()).map_err(|e|e.to_string())?;
            Ok(json!({"path":path,"kind":"remote","deviceId":udid}))
        },
        "account.login" => {
            let email=text(p,"email")?;
            let password=text(p,"password")?.to_owned();
            let anisette=p["anisetteUrl"].as_str().unwrap_or(api::BUILTIN_ANISETTE);
            progress(id,"Contacting Apple to sign in.");
            let (signed_in,info)=api::sign_in(email,password,anisette,&data.join("signing"),|params| {
                let answer=ask(id,replies,"twoFactor",json!({"lastError":params.last_error,"smsAvailable":params.sms,"numbers":params.numbers}));
                match answer["action"].as_str(){
                    Some("submit")=>TwoFactorCallbackResponse::SubmitCode(answer["code"].as_str().unwrap_or("").to_string()),
                    Some("sms")=>TwoFactorCallbackResponse::SendSms(answer["numberId"].as_u64().unwrap_or(0) as u32),
                    Some("resend")=>TwoFactorCallbackResponse::ResendCode,
                    Some("devices")=>TwoFactorCallbackResponse::SendToDevices,
                    _=>TwoFactorCallbackResponse::Abort
                }
            }).await.map_err(|e|format!("{e}"))?;
            *session=Some(signed_in); Ok(info)
        },
        "account.logout" => { *session=None; Ok(json!({"ok":true})) },
        "account.certificates" => api::list_certificates(session.as_mut().ok_or("Sign in first")?).await.map_err(|e|format!("{e}")),
        "account.appIds" => api::list_app_ids(session.as_mut().ok_or("Sign in first")?).await.map_err(|e|format!("{e}")),
        "identity.import" => api::import_identity(&data.join("signing"),&std::fs::read(text(p,"path")?).map_err(|e|e.to_string())?,p["password"].as_str().unwrap_or("").into()).map_err(|e|format!("{e}")),
        "profile.import" => api::import_profile(&data.join("signing"),std::fs::read(text(p,"path")?).map_err(|e|e.to_string())?,p["deviceId"].as_str()).map_err(|e|format!("{e}")),
        "ipa.sign" => {
            let path=PathBuf::from(text(p,"path")?); let udid=text(p,"deviceId")?;
            let strip=p["stripExtensions"].as_bool().unwrap_or(false);
            progress(id,"Signing app and its embedded bundles.");
            if p["mode"].as_str()==Some("certificate") {
                api::sign_offline(&data.join("signing"),path,text(p,"identityId")?,p["profileId"].as_str(),udid,strip,None,api::Platform::IOS).map_err(|e|format!("{e}"))
            } else {
                api::sign_with_apple_id(session.as_mut().ok_or("Sign in first")?,path,udid,p["deviceName"].as_str().unwrap_or("Apple device"),strip).await.map_err(|e|format!("{e}"))
            }
        },
        _ => Err(format!("Unknown native method: {method}"))
    }
}

#[tokio::main(flavor="multi_thread",worker_threads=4)]
async fn main() {
    api::init();
    let data=std::env::var_os("WAYPOINT_NATIVE_DATA").map(PathBuf::from).unwrap_or_else(||std::env::temp_dir().join("waypoint-native"));
    let replies:Replies=Arc::new(Mutex::new(HashMap::new()));
    let (tx,mut rx)=tokio::sync::mpsc::unbounded_channel::<Value>();
    let incoming=replies.clone();
    std::thread::spawn(move || {
        for line in io::stdin().lock().lines().map_while(Result::ok) {
            if let Ok(request)=serde_json::from_str::<Value>(&line) {
                if request["method"]=="prompt.reply" {
                    if let Some(pid)=request["params"]["promptId"].as_u64() {
                        if let Some(reply)=incoming.lock().unwrap().remove(&pid) { let _=reply.send(request["params"]["answer"].clone()); }
                    }
                } else if tx.send(request).is_err(){break}
            }
        }
    });
    let mut session=None;
    while let Some(request)=rx.recv().await {
        let id=request["id"].clone();
        let result=dispatch(&id,request["method"].as_str().unwrap_or(""),&request["params"],&data,&mut session,&replies).await;
        match result {
            Ok(value)=>emit(json!({"id":id,"result":value})),
            Err(message)=>emit(json!({"id":id,"error":{"code":"native_error","message":message}}))
        }
    }
}
