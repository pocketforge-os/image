use pocketforge_recovery_surface::{
    offscreen, Capability, RecoveryAction, RecoveryRequired, RecoverySurface,
    FEL_FLOOR_COPY, REQUIRED_COPY,
};
use serde_json::json;
use std::{env, fs, io, path::Path};

const DEFAULT_CONDITION: &str = "/var/lib/pocketforge/recovery/required.json";
const DEFAULT_FRAME: &str = "/run/pocketforge/recovery/frame.rgba";
const DEFAULT_FB: &str = "/dev/fb0";
const DEFAULT_EVIDENCE: &str = "/var/lib/pocketforge/recovery/presentation-failure.json";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let condition_path = env::var("PF_RECOVERY_CONDITION").unwrap_or_else(|_| DEFAULT_CONDITION.into());
    let frame_path = env::var("PF_RECOVERY_FRAME").unwrap_or_else(|_| DEFAULT_FRAME.into());
    let fb_path = env::var("PF_RECOVERY_FB").unwrap_or_else(|_| DEFAULT_FB.into());
    let evidence_path = env::var("PF_RECOVERY_EVIDENCE").unwrap_or_else(|_| DEFAULT_EVIDENCE.into());

    let condition: RecoveryRequired = serde_json::from_slice(&fs::read(&condition_path)?)?;
    let surface = RecoverySurface {
        condition,
        capabilities: vec![
            Capability::Unavailable {
                action: RecoveryAction::OtaUpdate,
                reason: "Recovery entry started offline; network availability is not assumed".into(),
            },
            Capability::Available {
                action: RecoveryAction::FelRecovery,
                label: FEL_FLOOR_COPY.into(),
            },
        ],
        last_result: None,
    };
    let frame = offscreen::render(&surface);
    write_file(&frame_path, &frame.rgba)?;

    if let Err(error) = fs::write(&fb_path, &frame.rgba) {
        let evidence = json!({
            "condition": REQUIRED_COPY,
            "presentation": "panel_unavailable",
            "fallback": FEL_FLOOR_COPY,
            "frame": frame_path,
            "error": error.to_string()
        });
        write_file(&evidence_path, serde_json::to_string_pretty(&evidence)?.as_bytes())?;
        eprintln!("recovery panel unavailable; FEL/out-of-band evidence: {evidence_path}");
    }
    Ok(())
}

fn write_file(path: &str, bytes: &[u8]) -> io::Result<()> {
    if let Some(parent) = Path::new(path).parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, bytes)
}
