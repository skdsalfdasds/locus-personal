use std::{fs, io::Read, path::Path};
use apple_codesign::{CodeSignatureFlags, MachFile, SettingsScope, SigningSettings, UnifiedSigner, VerificationProblemType, verify_macho_data};
use serde_json::{Value, json};

fn verify_adhoc(bytes: &[u8]) -> Result<(),String> {
    let binary=MachFile::parse(bytes).map_err(|e|e.to_string())?;
    for slice in binary.iter_macho() {
        let signature=slice.code_signature().map_err(|e|e.to_string())?
            .ok_or("The executable has no code signature")?;
        let directory=signature.code_directory().map_err(|e|e.to_string())?
            .ok_or("The executable has no code directory")?;
        if !directory.flags.contains(CodeSignatureFlags::ADHOC) {
            return Err("The signing engine did not create an ad-hoc signature".into());
        }
        // This signer emits an empty CMS slot for ad-hoc signatures. The generic
        // verifier attempts to decode it as CMS and reports a parse error. Only
        // accept that error after proving this slice is ADHOC and the slot empty.
        if signature.signature_data().map_err(|e|e.to_string())?.is_some_and(|cms|!cms.is_empty()) {
            return Err("An ad-hoc signature unexpectedly contains CMS data".into());
        }
        let problems=verify_macho_data(slice.data);
        let failures:Vec<_>=problems.iter().filter(|p|!matches!(p.problem,
            VerificationProblemType::NoCryptographicSignature|VerificationProblemType::CmsError(_))).collect();
        if !failures.is_empty() {
            return Err(format!("Ad-hoc code-directory verification failed: {failures:?}"));
        }
    }
    Ok(())
}

pub fn export(source: &Path, data: &Path, entitlements: Option<&str>) -> Result<Value,String> {
    let parent=data.join("exports");
    fs::create_dir_all(&parent).map_err(|e|e.to_string())?;
    let workspace=tempfile::Builder::new().prefix("adhoc-").tempdir_in(&parent).map_err(|e|e.to_string())?;
    let file=fs::File::open(source).map_err(|e|e.to_string())?;
    let mut archive=zip::ZipArchive::new(file).map_err(|e|e.to_string())?;
    archive.extract(workspace.path()).map_err(|e|e.to_string())?;
    let payload=workspace.path().join("Payload");
    let apps:Vec<_>=fs::read_dir(&payload).map_err(|_|"The IPA has no Payload directory".to_string())?
        .filter_map(Result::ok).map(|entry|entry.path())
        .filter(|p|p.is_dir()&&p.extension().is_some_and(|e|e=="app")).collect();
    if apps.len()!=1 {return Err("Choose an IPA with exactly one application".into());}
    let app=&apps[0];
    // The workspace is owned by this operation; no profile outside it is touched.
    for entry in walkdir::WalkDir::new(app).follow_links(false) {
        let entry=entry.map_err(|e|e.to_string())?;
        if entry.file_type().is_file()&&entry.file_name()=="embedded.mobileprovision" {
            fs::remove_file(entry.path()).map_err(|e|e.to_string())?;
        }
    }
    let mut settings=SigningSettings::default();
    if let Some(xml)=entitlements {
        settings.set_entitlements_xml(SettingsScope::Main,xml).map_err(|e|e.to_string())?;
    }
    UnifiedSigner::new(settings).sign_path_in_place(app).map_err(|e|e.to_string())?;
    let mut verified=0;
    for entry in walkdir::WalkDir::new(app).follow_links(false) {
        let entry=entry.map_err(|e|e.to_string())?;
        if !entry.file_type().is_file(){continue;}
        let mut file=fs::File::open(entry.path()).map_err(|e|e.to_string())?;
        let mut magic=[0u8;4];
        if file.read_exact(&mut magic).is_err(){continue;}
        if !matches!(magic,[0xcf,0xfa,0xed,0xfe]|[0xce,0xfa,0xed,0xfe]|[0xfe,0xed,0xfa,0xcf]|[0xfe,0xed,0xfa,0xce]|[0xca,0xfe,0xba,0xbe]|[0xbe,0xba,0xfe,0xca]|[0xca,0xfe,0xba,0xbf]|[0xbf,0xba,0xfe,0xca]){continue;}
        let bytes=fs::read(entry.path()).map_err(|e|e.to_string())?;
        verify_adhoc(&bytes)?;
        verified+=1;
    }
    if verified==0{return Err("No signed Mach-O executable was found".into());}
    let app_path=app.to_path_buf();
    let kept=workspace.keep();
    Ok(json!({"signedPath":app_path,"workspace":kept,"mode":"adhoc","verifiedBinaries":verified,"appleProvisioned":false}))
}
