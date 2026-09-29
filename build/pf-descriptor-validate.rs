//! Image-build-only check of the staged platform device descriptor (bd: tsp-f3fm.202.1 B4).
//!
//! Copied into runtime's `pf-input-broker/examples/` and built for the build host, exactly
//! like `pf-app-validate`; it is never installed. It parses the descriptor with the loaders
//! its two real consumers use:
//! - the app facade: `pocketforge::Descriptor::load` (`PF_DESCRIPTOR`), and
//! - `pf-input-broker --descriptor`: `Remap::from_descriptor` plus `ExpectedIdentity`.
//! It also requires the guide control (`BTN_MODE`) that the SafeReturn intake keys on.

use pf_input_broker::broker::ExpectedIdentity;
use pf_input_broker::Remap;
use pocketforge::Descriptor;

const BTN_MODE: u16 = 0x13c;

fn main() {
    let mut arguments = std::env::args_os().skip(1);
    let (Some(path), Some(expected_id), None) =
        (arguments.next(), arguments.next(), arguments.next())
    else {
        eprintln!("usage: pf-descriptor-validate <capabilities.toml> <device-id>");
        std::process::exit(2);
    };
    let expected_id = expected_id.to_string_lossy().into_owned();
    let descriptor = Descriptor::load(&path).unwrap_or_else(|error| {
        fail(&format!("Descriptor::load {}: {error}", path.to_string_lossy()))
    });
    if descriptor.identity.id != expected_id {
        fail(&format!(
            "identity.id {:?} != expected {:?}",
            descriptor.identity.id, expected_id
        ));
    }
    let remap = Remap::from_descriptor(&descriptor)
        .unwrap_or_else(|error| fail(&format!("broker remap rejected the descriptor: {error:?}")));
    if let Err(error) = ExpectedIdentity::from_descriptor(&descriptor) {
        fail(&format!("broker source identity rejected the descriptor: {error}"));
    }
    if !remap.spec().keys.contains(&BTN_MODE) {
        fail("descriptor has no guide/BTN_MODE control for the SafeReturn intake");
    }
    println!(
        "validated device descriptor {} inputs={} re-emit={:?} guide=BTN_MODE",
        descriptor.identity.id,
        descriptor.inputs.len(),
        remap.spec().name
    );
}

fn fail(message: &str) -> ! {
    eprintln!("FATAL: device descriptor validation failed: {message}");
    std::process::exit(1);
}
