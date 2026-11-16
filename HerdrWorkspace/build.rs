use std::{env, fs, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let output = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let root = manifest.join("web/vendor/pdfjs");
    println!("cargo:rerun-if-changed={}", root.display());
    let mut assets = Vec::new();
    for directory in ["", "cmaps", "standard_fonts", "iccs", "wasm"] {
        for entry in fs::read_dir(root.join(directory)).expect("PDF.js assets") {
            let path = entry.expect("PDF.js asset").path();
            let mime = match path.extension().and_then(|ext| ext.to_str()) {
                Some("mjs" | "js") => "text/javascript; charset=utf-8",
                Some("wasm") => "application/wasm",
                Some("ttf") => "font/ttf",
                Some("bcmap" | "icc" | "pfb") => "application/octet-stream",
                _ => continue,
            };
            assets.push((
                path.strip_prefix(&root)
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .replace(std::path::MAIN_SEPARATOR, "/"),
                mime,
                path,
            ));
        }
    }
    assets.sort_unstable();
    let mut table = String::from("&[\n");
    for (name, mime, path) in assets {
        use std::fmt::Write;
        writeln!(table, "({name:?}, {mime:?}, include_bytes!({path:?})),").unwrap();
    }
    table.push_str("]\n");
    fs::write(output.join("pdf-assets.rs"), table).expect("write PDF.js asset table");
    write_export_helper(
        &manifest.join("../scripts"),
        &output.join("swarmhub-grok-export.pyz"),
    );
}

// Python zipapps are ordinary ZIPs with a __main__.py. These fixed paths and
// uncompressed members keep the artifact deterministic and need no Python on the build host.
fn write_export_helper(scripts: &std::path::Path, output: &std::path::Path) {
    const FILES: [(&str, &str); 3] = [
        ("__main__.py", "export_grok_local.py"),
        ("export_grokbot.py", "export-grokbot.py"),
        ("grokbot_staged.py", "grokbot_staged.py"),
    ];
    fn u16le(out: &mut Vec<u8>, numbers: &[u16]) {
        for number in numbers {
            out.extend(number.to_le_bytes());
        }
    }
    fn u32le(out: &mut Vec<u8>, numbers: &[u32]) {
        for number in numbers {
            out.extend(number.to_le_bytes());
        }
    }
    let mut entries = Vec::new();
    let mut directory = Vec::new();
    for (name, source) in FILES {
        let path = scripts.join(source);
        println!("cargo:rerun-if-changed={}", path.display());
        let data = fs::read(path).expect("read Grok Bot export helper source");
        let len = u32::try_from(data.len()).expect("ZIP member size");
        let offset = u32::try_from(entries.len()).expect("ZIP member offset");
        let name_len = name.len() as u16;
        let crc = crc32fast::hash(&data);
        u32le(&mut entries, &[0x04034b50]);
        u16le(&mut entries, &[20, 0, 0, 0, 0x21]);
        u32le(&mut entries, &[crc, len, len]);
        u16le(&mut entries, &[name_len, 0]);
        entries.extend(name.as_bytes());
        entries.extend(&data);
        u32le(&mut directory, &[0x02014b50]);
        u16le(&mut directory, &[0x0314, 20, 0, 0, 0, 0x21]);
        u32le(&mut directory, &[crc, len, len]);
        u16le(&mut directory, &[name_len, 0, 0, 0, 0]);
        u32le(&mut directory, &[0o100644 << 16, offset]);
        directory.extend(name.as_bytes());
    }
    let directory_start = entries.len() as u32;
    entries.extend(&directory);
    u32le(&mut entries, &[0x06054b50]);
    u16le(
        &mut entries,
        &[0, 0, FILES.len() as u16, FILES.len() as u16],
    );
    u32le(&mut entries, &[directory.len() as u32, directory_start]);
    u16le(&mut entries, &[0]);
    fs::write(output, entries).expect("write Grok Bot export helper ZIP");
}
