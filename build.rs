use std::path::PathBuf;
use std::process::Command;

fn main() {
    napi_build::setup();

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let obj_path = out_dir.join("translate_bridge.o");

    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    let target = if arch == "aarch64" {
        "arm64-apple-macos15.0"
    } else {
        "x86_64-apple-macos15.0"
    };

    let status = Command::new("swiftc")
        .args([
            "src/translate_bridge.swift",
            "-emit-object",
            "-module-name",
            "TranslateBridge",
            "-target",
            target,
            "-o",
            obj_path.to_str().unwrap(),
        ])
        .status()
        .expect("swiftc not found — install Xcode command line tools");

    assert!(status.success(), "swiftc failed");

    println!("cargo:rustc-link-arg={}", obj_path.display());
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Translation");
    println!("cargo:rustc-link-search=/usr/lib/swift");
    println!("cargo:rustc-link-lib=swiftFoundation");
    println!("cargo:rustc-link-lib=swiftCore");

    // libswift_Concurrency.dylib is in the DYLD shared cache at /usr/lib/swift on macOS 12+.
    // Adding just this rpath is sufficient; do NOT also add the Xcode toolchain path or the
    // dylib loads twice (duplicate class warning + crashes).
    println!("cargo:rustc-link-arg=-rpath");
    println!("cargo:rustc-link-arg=/usr/lib/swift");

    println!("cargo:rerun-if-changed=src/translate_bridge.swift");
    println!("cargo:rerun-if-changed=build.rs");
}
