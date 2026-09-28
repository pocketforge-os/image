//! Image-build-only wrapper around runtime's shared default-app resolver.

use pf_app_manifest::Resolver;
use std::path::PathBuf;

fn main() {
    let mut arguments = std::env::args_os();
    let _program = arguments.next();
    let Some(app_root) = arguments.next().map(PathBuf::from) else {
        usage();
    };
    let Some(platform_contract) = arguments.next().map(PathBuf::from) else {
        usage();
    };
    let Some(app_id) = arguments.next() else {
        usage();
    };
    if arguments.next().is_some() {
        usage();
    }
    let Some(app_id) = app_id.to_str() else {
        eprintln!("FATAL: default-app descriptor validation received a non-UTF-8 id");
        std::process::exit(1);
    };
    match Resolver::new(app_root, platform_contract).resolve(app_id) {
        Ok(resolved) => println!("validated default app {}", resolved.id),
        Err(error) => {
            eprintln!(
                "FATAL: default-app descriptor validation failed: reason={} detail={}",
                error.reason.as_str(),
                error.detail
            );
            std::process::exit(1);
        }
    }
}

fn usage() -> ! {
    eprintln!("usage: pf-app-validate <app-root> <platform-contract> <app-id>");
    std::process::exit(2);
}
