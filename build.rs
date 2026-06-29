use std::path::PathBuf;
use std::process::Command;

fn compile_swift(src: &str, out_dir: &PathBuf, target: &str) -> PathBuf {
    let stem = std::path::Path::new(src)
        .file_stem()
        .unwrap()
        .to_str()
        .unwrap();
    let obj_path = out_dir.join(format!("{stem}.o"));

    let status = Command::new("swiftc")
        .args([
            src,
            "-emit-object",
            "-parse-as-library",
            "-module-name",
            "Bridge",
            "-target",
            target,
            "-o",
            obj_path.to_str().unwrap(),
        ])
        .status()
        .expect("swiftc not found — install Xcode command line tools");

    assert!(status.success(), "swiftc failed for {src}");
    obj_path
}

fn main() {
    napi_build::setup();

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());

    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    let target = if arch == "aarch64" {
        "arm64-apple-macos15.0"
    } else {
        "x86_64-apple-macos15.0"
    };

    let translate_obj = compile_swift("src/translate_bridge.swift", &out_dir, target);
    let speech_obj = compile_swift("src/speech_bridge.swift", &out_dir, target);

    println!("cargo:rustc-link-arg={}", translate_obj.display());
    println!("cargo:rustc-link-arg={}", speech_obj.display());
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Translation");
    println!("cargo:rustc-link-lib=framework=Speech");
    println!("cargo:rustc-link-search=/usr/lib/swift");
    println!("cargo:rustc-link-lib=swiftFoundation");
    println!("cargo:rustc-link-lib=swiftCore");

    // libswift_Concurrency.dylib is in the DYLD shared cache at /usr/lib/swift on macOS 12+.
    println!("cargo:rustc-link-arg=-rpath");
    println!("cargo:rustc-link-arg=/usr/lib/swift");

    println!("cargo:rerun-if-changed=src/translate_bridge.swift");
    println!("cargo:rerun-if-changed=src/speech_bridge.swift");
    println!("cargo:rerun-if-changed=build.rs");
}
