use std::collections::BTreeSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const SOURCES_MANIFEST: &str = "packaging/sources.txt";

fn collect(directory: &Path, files: &mut Vec<PathBuf>) -> std::io::Result<()> {
    println!("cargo:rerun-if-changed={}", directory.display());
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

fn top_level_sources(root: &Path) -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    // Watching the repository root directly would also watch backend/target and
    // break incremental builds. Instead, track top-level QML/JS membership in a
    // checked manifest and reject any unlisted or missing top-level files.
    let manifest_path = root.join(SOURCES_MANIFEST);
    println!("cargo:rerun-if-changed={}", manifest_path.display());
    let contents = fs::read_to_string(&manifest_path)?;
    let mut declared = Vec::new();
    for line in contents.lines() {
        if line.is_empty()
            || line != line.trim()
            || line.contains('/')
            || line.contains('\\')
            || !(line.ends_with(".qml") || line.ends_with(".js"))
        {
            return Err(format!("Invalid entry in {SOURCES_MANIFEST}: {line:?}").into());
        }
        declared.push(line.to_string());
    }
    if !declared.windows(2).all(|pair| pair[0] < pair[1]) {
        return Err(format!("{SOURCES_MANIFEST} must be sorted without duplicates").into());
    }

    let mut actual = Vec::new();
    for entry in fs::read_dir(root)? {
        let path = entry?.path();
        if path.is_file()
            && matches!(
                path.extension().and_then(|ext| ext.to_str()),
                Some("qml" | "js")
            )
        {
            let name = path
                .file_name()
                .and_then(|value| value.to_str())
                .ok_or("Non-UTF-8 top-level QML/JS filename")?;
            actual.push(name.to_string());
        }
    }
    actual.sort();
    if declared != actual {
        let declared_set: BTreeSet<&str> = declared.iter().map(String::as_str).collect();
        let actual_set: BTreeSet<&str> = actual.iter().map(String::as_str).collect();
        let missing: Vec<&str> = declared_set.difference(&actual_set).copied().collect();
        let unlisted: Vec<&str> = actual_set.difference(&declared_set).copied().collect();
        return Err(format!(
            "Top-level QML/JS files do not match {SOURCES_MANIFEST} (missing={missing:?}, unlisted={unlisted:?})"
        )
        .into());
    }
    Ok(declared.into_iter().map(PathBuf::from).collect())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut files = vec![
        PathBuf::from("manifest.json"),
        PathBuf::from("backend/Cargo.toml"),
        PathBuf::from("backend/Cargo.lock"),
        PathBuf::from("backend/build.rs"),
        PathBuf::from("packaging/release.py"),
        PathBuf::from(SOURCES_MANIFEST),
    ];
    files.extend(top_level_sources(root)?);
    for directory in ["scripts", "backend/src"] {
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
