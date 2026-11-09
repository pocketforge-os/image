//! Test-only compositor endpoint for tests/test-fake-gamescope-focus.sh (tsp-ca44436b9799851cd483).
//!
//! Copied into runtime's pf-input-broker/examples/ at the pinned runtime SHA and built from that
//! crate. It serves one compositor peer with the broker's real CompositorAuthority and
//! serve_compositor_peer, wired to the real RumbleControl, whose StderrLog writes the same
//! `rumble: ...` lines the daemon writes into the journal. Only the hardware is replaced: the
//! FfSink below accepts every effect without a motor, and there is no evdev grab or uinput.
//! The endpoint's uid/group/unit admission (authenticate_peer) is not exercised here; it needs
//! the production users and a systemd unit identity.

use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::sync::Arc;

use pf_input_broker::ff::{FfEffect, FfSink, RumbleControl};
use pf_input_broker::session_ipc::{serve_compositor_peer, CompositorAuthority};

struct NoMotor;

impl FfSink for NoMotor {
    fn upload(&mut self, vib: i16, _effect: &FfEffect) -> std::io::Result<i16> {
        Ok(if vib < 0 { 0 } else { vib })
    }
    fn play(&mut self, _vib: i16, _value: i32) -> std::io::Result<()> {
        Ok(())
    }
    fn erase(&mut self, _vib: i16) -> std::io::Result<()> {
        Ok(())
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args()
        .nth(1)
        .ok_or("usage: pf_compositor_focus_broker <compositor.sock>")?;
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o660))?;
    println!("compositor-sock={path}");
    let rumble = RumbleControl::new(Box::new(NoMotor));
    let authority = Arc::new(CompositorAuthority::default().with_rumble(rumble));
    let (stream, _) = listener.accept()?;
    let result = serve_compositor_peer(stream, &authority);
    let _ = std::fs::remove_file(&path);
    if let Err(error) = &result {
        eprintln!("pf_compositor_focus_broker: compositor peer refused: {error}");
    }
    Ok(result?)
}
