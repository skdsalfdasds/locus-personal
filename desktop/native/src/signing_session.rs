//! A resumable developer session over the same pinned isideload implementation.
//! Passwords are used only for login. Exported tokens are private backend IPC;
//! the Python service places them in the OS credential store, never the UI.
//!
//! Login/signing flow adapted from Apparition core (MIT):
//! Copyright (c) 2026 Illixion. Full permission notice in THIRD-PARTY-NOTICES.md.

use std::{collections::HashMap, fs, io::Write, path::{Path, PathBuf}, sync::Mutex};
use apparition_core::{api, claimed_platform::{self, ClaimedPlatform, Served}};
use base64::{Engine, prelude::BASE64_STANDARD};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, AppToken, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{app_ids::AppIdsApi, certificates::CertificatesApi, developer_session::DeveloperSession,
          device_type::DeveloperDeviceType, devices::DevicesApi, teams::{DeveloperTeam, TeamsApi}},
    sideload::{application::Application, builder::MaxCertsBehavior, sideloader::Sideloader, SideloaderBuilder, TeamSelection},
    util::{callbacks::MaxCertsCallbackBox, storage::SideloadingStorage},
};
use rootcause::prelude::*;
use rsa::{RsaPrivateKey, pkcs1::EncodeRsaPublicKey, pkcs8::DecodePrivateKey};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use x509_cert::der::Decode;

// Retain the existing machine label so an existing matching certificate/key is
// reused. MaxCertsBehavior::Error below never revokes someone else's certificate.
const MACHINE_NAME: &str = "Apparition";
static STORAGE_LOCK: Mutex<()> = Mutex::new(());

struct JsonStorage { path: PathBuf }
impl JsonStorage {
    fn open(path: PathBuf) -> Self { Self { path } }
    fn read(&self) -> Result<HashMap<String,String>,Report> {
        match fs::metadata(&self.path) {
            Ok(info) if info.len() <= 16*1024*1024 => {
                let bytes=fs::read(&self.path).context("Cannot read local signing state")?;
                serde_json::from_slice(&bytes).map_err(|_|report!("Local signing state is damaged"))
            },
            Ok(_) => Err(report!("Local signing state exceeds its size limit")),
            Err(error) if error.kind()==std::io::ErrorKind::NotFound => Ok(HashMap::new()),
            Err(_) => Err(report!("Cannot read local signing state")),
        }
    }
}
impl SideloadingStorage for JsonStorage {
    fn store(&self,key:&str,value:&str)->Result<(),Report> {
        let _guard=STORAGE_LOCK.lock().map_err(|_|report!("Local signing state is busy"))?;
        let mut values=self.read()?;
        if value.is_empty(){values.remove(key);}else{values.insert(key.into(),value.into());}
        let parent=self.path.parent().ok_or_else(||report!("Invalid signing state path"))?;
        fs::create_dir_all(parent)?;
        let mut temporary=tempfile::NamedTempFile::new_in(parent)?;
        temporary.write_all(&serde_json::to_vec(&values)?)?;
        temporary.as_file().sync_all()?;
        temporary.persist(&self.path).map_err(|_|report!("Cannot save local signing state"))?;
        Ok(())
    }
    fn retrieve(&self,key:&str)->Result<Option<String>,Report> {
        let _guard=STORAGE_LOCK.lock().map_err(|_|report!("Local signing state is busy"))?;
        Ok(self.read()?.get(key).cloned())
    }
}

// Deliberately no Debug implementation: a formatting error must not print tokens.
#[derive(Clone,Serialize,Deserialize)]
#[serde(rename_all="camelCase",deny_unknown_fields)]
pub struct StoredSession {
    version:u32, email:String, token:String, adsid:String,
    duration:u64, expiry:u64, endpoint:String, team_id:String,
}
impl StoredSession {
    fn validate(&self)->Result<(),Report> {
        if self.version!=1 || self.email.is_empty() || self.email.len()>320 ||
           self.token.is_empty() || self.token.len()>16384 || self.adsid.is_empty() ||
           self.adsid.len()>64 || !self.adsid.bytes().all(|b|b.is_ascii_digit()) ||
           self.team_id.is_empty() || self.team_id.len()>128 ||
           !self.team_id.bytes().all(|b|b.is_ascii_alphanumeric()) ||
           self.endpoint.is_empty() || self.endpoint.len()>2048 ||
           self.endpoint.contains(['\r','\n']) {
            bail!("Saved signing session is invalid");
        }
        Ok(())
    }
}

pub struct SigningSession {
    secret:StoredSession, team:DeveloperTeam, teams:Vec<DeveloperTeam>,
    sideloader:Sideloader<MaxCertsCallbackBox>, data_dir:PathBuf,
}

fn team_info(team:&DeveloperTeam)->Value {
    json!({"id":team.team_id,"name":team.name,"kind":team.r#type})
}
impl SigningSession {
    pub fn info(&self)->Value {
        json!({"email":self.secret.email,"team":team_info(&self.team),
               "teams":self.teams.iter().map(team_info).collect::<Vec<_>>()})
    }
    pub fn export(&self)->Result<Value,Report> {
        self.secret.validate()?;
        Ok(serde_json::to_value(&self.secret)?)
    }
    pub fn select_team(&mut self,id:&str)->Result<Value,Report> {
        let team=self.teams.iter().find(|team|team.team_id==id)
            .ok_or_else(||report!("This team is not available to the signed-in account"))?;
        self.team=team.clone();self.secret.team_id=id.into();
        Ok(self.info())
    }
}

async fn anisette_address(requested:&str,data:&Path)->Result<String,Report> {
    if requested!=api::BUILTIN_ANISETTE{return Ok(requested.into());}
    #[cfg(any(target_os="macos",target_os="linux"))]
    {
        static SERVER:tokio::sync::OnceCell<apparition_core::anisette::Server>=tokio::sync::OnceCell::const_new();
        let server=SERVER.get_or_try_init(||async {
            apparition_core::anisette::start(&data.parent().unwrap_or(data).join("anisette"),
                std::net::SocketAddr::from(([127,0,0,1],0))).await
        }).await?;
        Ok(server.url())
    }
    #[cfg(not(any(target_os="macos",target_os="linux")))]
    { let _=data;bail!("Configure an anisette v3 server on this platform"); }
}

async fn account_for(email:&str,endpoint:&str,data:&Path)->Result<(AppleAccount,Served),Report> {
    fs::create_dir_all(data)?;
    let address=anisette_address(endpoint,data).await?;
    let served=claimed_platform::served_by(&address).await;
    let provider=ClaimedPlatform::new(RemoteV3AnisetteProvider::new(&address,
        Box::new(JsonStorage::open(data.join("storage.json"))),"0".into())?,served);
    Ok((AppleAccount::builder(email).anisette_provider(provider).build().await?,served))
}

async fn finish(mut dev:DeveloperSession,mut secret:StoredSession,data:&Path)->Result<SigningSession,Report> {
    // A portal read validates a restored token. No device registration or
    // certificate creation/revocation takes place during restoration.
    let teams=dev.list_teams().await.context("Cannot open the developer session")?;
    let team=if secret.team_id.is_empty(){teams.first()}else{teams.iter().find(|team|team.team_id==secret.team_id)}
        .ok_or_else(||report!("The selected developer team is unavailable"))?.clone();
    secret.team_id=team.team_id.clone();secret.validate()?;
    let sideloader=SideloaderBuilder::new(dev,secret.email.clone())
        .team_selection(TeamSelection::First).max_certs_behavior(MaxCertsBehavior::Error)
        .storage(Box::new(JsonStorage::open(data.join("storage.json"))))
        .machine_name(MACHINE_NAME.into()).delete_app_after_install(false).build();
    Ok(SigningSession {secret,team,teams,sideloader,data_dir:data.into()})
}

pub async fn login(email:&str,password:String,endpoint:&str,data:&Path,team_id:Option<&str>,
    callback:impl Fn(&TwoFactorCallbackParams)->TwoFactorCallbackResponse+Send+Sync)->Result<SigningSession,Report> {
    let (mut account,served)=account_for(email,endpoint,data).await?;
    let answer=|params:TwoFactorCallbackParams| {
        let response=callback(&params);async move {Ok(response)}
    };
    account.login(&password,answer).await.context("Apple sign-in failed")?;
    let token=match account.get_app_token("xcode.auth").await {
        Ok(token)=>token,
        Err(error) if served==Served::Android&&format!("{error:?}").contains("-22411")=>{
            account.code_after_login=true;
            account.login(&password,answer).await.context("Apple verification failed")?;
            account.get_app_token("xcode.auth").await.context("Cannot open the developer session")?
        },
        Err(error)=>return Err(error.context("Cannot open the developer session").into_dynamic()),
    };
    drop(password);
    let adsid=account.spd.as_ref().and_then(|spd|spd.get("adsid")).and_then(plist::Value::as_string)
        .ok_or_else(||report!("Apple did not return the developer identity"))?.to_string();
    let secret=StoredSession {version:1,email:email.into(),token:token.token.clone(),adsid:adsid.clone(),
        duration:token.duration,expiry:token.expiry,endpoint:endpoint.into(),team_id:team_id.unwrap_or("").into()};
    let dev=DeveloperSession::new(token,adsid,account.grandslam_client.clone(),account.anisette_generator.clone());
    finish(dev,secret,data).await
}

pub async fn restore(value:Value,data:&Path)->Result<SigningSession,Report> {
    let secret:StoredSession=serde_json::from_value(value).map_err(|_|report!("Saved signing session is invalid"))?;
    secret.validate()?;
    let (account,_)=account_for(&secret.email,&secret.endpoint,data).await?;
    let dev=DeveloperSession::new(AppToken {token:secret.token.clone(),duration:secret.duration,expiry:secret.expiry},
        secret.adsid.clone(),account.grandslam_client,account.anisette_generator);
    finish(dev,secret,data).await
}

fn entitlements(app:&Path)->Option<plist::Dictionary> {
    let info:plist::Dictionary=plist::from_file(app.join("Info.plist")).ok()?;
    let executable=info.get("CFBundleExecutable")?.as_string()?;
    if Path::new(executable).components().count()!=1{return None;}
    let bytes=fs::read(app.join(executable)).ok()?;
    let macho=apple_codesign::MachFile::parse(&bytes).ok()?;
    for slice in macho.iter_macho() {
        if let Some(blob)=slice.code_signature().ok()??.entitlements().ok()? {
            return plist::from_bytes(blob.as_str().as_bytes()).ok();
        }
    }
    None
}

pub async fn sign(session:&mut SigningSession,path:PathBuf,device_id:&str,device_name:&str,strip:bool)->Result<Value,Report> {
    let app=Application::new(path.clone())?.bundle.bundle_dir;
    let mut stripped=Vec::new();
    if strip {
        let base=app.canonicalize()?;
        if !path.is_file() || !base.starts_with(std::env::temp_dir().canonicalize()?) {
            bail!("Remove extensions from an IPA input, not an existing application directory");
        }
        for name in ["PlugIns","Extensions"] {
            let directory=app.join(name);
            if !directory.exists(){continue;}
            let resolved=directory.canonicalize()?;
            if !resolved.starts_with(&base)||fs::symlink_metadata(&directory)?.file_type().is_symlink(){
                bail!("An extension directory points outside its signing workspace");
            }
            for entry in fs::read_dir(&directory)?{stripped.push(entry?.file_name().to_string_lossy().to_string());}
            fs::remove_dir_all(resolved)?;
        }
    }
    let asked=entitlements(&app).unwrap_or_default();
    let mapping=[("com.apple.developer.kernel.increased-memory-limit","INCREASED_MEMORY_LIMIT"),
                 ("com.apple.developer.kernel.extended-virtual-addressing","EXTENDED_VIRTUAL_ADDRESSING")];
    let capabilities:Vec<String>=mapping.iter().filter(|(key,_)|asked.get(*key).and_then(plist::Value::as_boolean)==Some(true))
        .map(|(_,capability)|capability.to_string()).collect();
    let team=session.team.clone();
    let dev=session.sideloader.get_dev_session();
    dev.ensure_device_registered(&team,device_name,device_id,None).await.context("Device registration failed")?;
    let devices=dev.list_devices(&team,None).await?;
    let (signed,_)=session.sideloader.sign_app(app,Some(team),&capabilities,
        None::<fn(f32)->std::future::Ready<()>>,None,Some(device_id)).await.context("Signing failed")?;
    let mut result=json!({"signedPath":signed,"strippedExtensions":stripped,
        "devices":devices.iter().map(|d|json!({"name":d.name,"udid":d.device_number,"status":d.status})).collect::<Vec<_>>()});
    if !capabilities.is_empty() {
        let actual=entitlements(&signed).unwrap_or_default();
        result["capabilities"]=json!({"requested":capabilities,"signed":mapping.iter()
            .filter(|(key,_)|actual.contains_key(*key)).map(|(key,_)|key).collect::<Vec<_>>()});
    }
    Ok(result)
}

fn stored_public_key(session:&SigningSession)->Option<Vec<u8>> {
    let key=format!("{:x}/key",Sha256::digest(session.secret.email.as_bytes()));
    let encoded=JsonStorage::open(session.data_dir.join("storage.json")).retrieve(&key).ok()??;
    let key=RsaPrivateKey::from_pkcs8_der(&BASE64_STANDARD.decode(encoded).ok()?).ok()?;
    Some(key.to_public_key().to_pkcs1_der().ok()?.as_bytes().to_vec())
}
pub async fn certificates(session:&mut SigningSession)->Result<Value,Report> {
    let ours=stored_public_key(session);
    let dev=session.sideloader.get_dev_session();let team=&session.team;
    let mut certificates=dev.list_all_development_certs(team,DeveloperDeviceType::Ios).await?;
    if let Ok(more)=dev.list_all_development_certs(team,DeveloperDeviceType::Any).await {
        for item in more {
            if item.serial_number.is_none()||!certificates.iter().any(|known|known.serial_number==item.serial_number){certificates.push(item);}
        }
    }
    let entries:Vec<_>=certificates.iter().map(|cert|{
        let key=cert.cert_content.as_ref().and_then(|data|x509_cert::Certificate::from_der(data.as_ref()).ok())
            .and_then(|cert|cert.tbs_certificate.subject_public_key_info.subject_public_key.as_bytes().map(<[u8]>::to_vec));
        json!({"name":cert.name,"serialNumber":cert.serial_number,"machineName":cert.machine_name,
            "status":cert.status,"expires":cert.expiration_date.map(|date|date.to_xml_format()),
            "platform":cert.certificate_platform.clone().or_else(||cert.certificate_type.as_ref().and_then(|kind|kind.platform.clone())),
            "typeName":cert.certificate_type.as_ref().and_then(|kind|kind.name.clone()),
            "madeByApparition":cert.machine_name.as_deref()==Some(MACHINE_NAME),"inUseHere":ours.is_some()&&key==ours})
    }).collect();
    Ok(json!({"certificates":entries}))
}
pub async fn app_ids(session:&mut SigningSession)->Result<Value,Report> {
    let response=session.sideloader.get_dev_session().list_app_ids(&session.team,None).await?;
    Ok(json!({"appIds":response.app_ids.iter().map(|app|json!({"appIdId":app.app_id_id,"identifier":app.identifier,
        "name":app.name,"expires":app.expiration_date.map(|date|date.to_xml_format())})).collect::<Vec<_>>(),
        "maxQuantity":response.max_quantity,"availableQuantity":response.available_quantity}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn storage_merges_instances_and_refuses_to_overwrite_damage() {
        let dir=tempfile::tempdir().unwrap();let path=dir.path().join("storage.json");
        let first=JsonStorage::open(path.clone());let second=JsonStorage::open(path.clone());
        first.store("first","synthetic-one").unwrap();second.store("second","synthetic-two").unwrap();
        assert_eq!(first.retrieve("second").unwrap().as_deref(),Some("synthetic-two"));
        second.delete("first").unwrap();assert_eq!(first.retrieve("first").unwrap(),None);
        fs::write(&path,b"damaged").unwrap();assert!(first.store("third","synthetic").is_err());
        assert_eq!(fs::read(&path).unwrap(),b"damaged");
    }
    #[test]
    fn secret_schema_rejects_passwords_and_invalid_identity_without_printing_tokens() {
        let valid=json!({"version":1,"email":"synthetic@example.invalid","token":"synthetic-token",
            "adsid":"123456","duration":3600,"expiry":1,"endpoint":"https://example.invalid","teamId":"TEAM123"});
        assert!(serde_json::from_value::<StoredSession>(valid.clone()).unwrap().validate().is_ok());
        let mut with_password=valid.clone();with_password["password"]=json!("synthetic-password");
        assert!(serde_json::from_value::<StoredSession>(with_password).is_err());
        let mut invalid=valid;invalid["adsid"]=json!("not-numeric");
        let error=serde_json::from_value::<StoredSession>(invalid).unwrap().validate().unwrap_err();
        assert!(!format!("{error}").contains("synthetic-token"));
    }
}
