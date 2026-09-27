use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn collect(directory: &Path, files: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        if path.is_dir() {
            collect(&path, files)?;
        } else if path.is_file() {
            files.push(path);
        }
    }
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut files = vec![
        PathBuf::from("manifest.json"),
        PathBuf::from("backend/Cargo.toml"),
        PathBuf::from("backend/Cargo.lock"),
        PathBuf::from("backend/build.rs"),
        PathBuf::from("packaging/release.py"),
    ];
    for entry in fs::read_dir(root)? {
        let path = entry?.path();
        if path.is_file()
            && matches!(
                path.extension().and_then(|ext| ext.to_str()),
                Some("qml" | "js")
            )
        {
            files.push(path.strip_prefix(root)?.to_path_buf());
        }
    }
    for directory in ["scripts", "backend/src"] {
        println!("cargo:rerun-if-changed={}", root.join(directory).display());
        let mut children = Vec::new();
        collect(&root.join(directory), &mut children)?;
        files.extend(
            children
                .into_iter()
                .map(|path| path.strip_prefix(root).unwrap().to_path_buf()),
        );
    }
    files.sort();
    let mut input = Vec::new();
    for relative in files {
        let path = root.join(&relative);
        println!("cargo:rerun-if-changed={}", path.display());
        let bytes = fs::read(path)?;
        input.extend_from_slice(
            relative
                .to_str()
                .ok_or("Non-UTF-8 source path")?
                .replace('\\', "/")
                .as_bytes(),
        );
        input.push(0);
        input.extend_from_slice(bytes.len().to_string().as_bytes());
        input.push(0);
        input.extend_from_slice(&bytes);
    }
    let mut child = Command::new("sha256sum")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    child.stdin.take().unwrap().write_all(&input)?;
    let result = child.wait_with_output()?;
    if !result.status.success() {
        return Err("sha256sum failed".into());
    }
    let digest = std::str::from_utf8(&result.stdout)?
        .split_whitespace()
        .next()
        .ok_or("Missing digest")?;
    println!("cargo:rustc-env=BLUETOOTH_BUILD_ID={digest}");
    println!(
        "cargo:rustc-env=BLUETOOTH_BUILD_TARGET={}",
        std::env::var("TARGET")?
    );
    Ok(())
}
