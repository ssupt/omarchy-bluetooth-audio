//! A single command owner for the Bluetooth panel. The shell keeps this
//! process alive independently of bar widgets on individual monitors.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{Mutex, mpsc};

const MAX_FRAME: usize = 65_536;
const MAX_OUTPUT: usize = 131_072;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    id: String,
    method: String,
    params: Value,
}

#[derive(Serialize)]
struct Failure {
    code: &'static str,
    message: String,
    outcome: &'static str,
}

impl Failure {
    fn rejected(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            outcome: "rejected",
        }
    }
    fn unknown(message: impl Into<String>) -> Self {
        Self {
            code: "unknown",
            message: message.into(),
            outcome: "unknown",
        }
    }
}

struct Service {
    scripts: PathBuf,
    mutation: Mutex<()>,
    active_action: Mutex<Option<(String, u32)>>,
}

fn string<'a>(value: &'a Value, key: &str) -> Result<&'a str, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::rejected("invalid_params", format!("Missing {key}")))
}

fn address(value: &str) -> bool {
    value.len() == 17
        && value.as_bytes().iter().enumerate().all(|(index, byte)| {
            if index % 3 == 2 {
                *byte == b':'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn identifier(value: &str) -> bool {
    !value.is_empty() && value.len() <= 160 && !value.chars().any(char::is_control)
}

async fn read_frame<R: AsyncBufRead + Unpin>(
    reader: &mut R,
    frame: &mut Vec<u8>,
) -> std::io::Result<bool> {
    frame.clear();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return Ok(false);
        }
        let count = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        let complete = available[count - 1] == b'\n';
        if frame.len() + count > MAX_FRAME {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Bluetooth request is too large",
            ));
        }
        frame.extend_from_slice(&available[..count]);
        reader.consume(count);
        if complete {
            return Ok(true);
        }
    }
}

impl Service {
    async fn script(
        &self,
        name: &str,
        args: &[&str],
        deadline: Duration,
        action: Option<&str>,
    ) -> Result<Value, Failure> {
        let path = self.scripts.join(name);
        let mut child = Command::new(&path)
            .args(args)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|error| {
                Failure::rejected("unavailable", format!("Could not run {name}: {error}"))
            })?;
        let pid = child
            .id()
            .ok_or_else(|| Failure::unknown("Bluetooth helper has no process ID"))?;
        if let Some(address) = action {
            *self.active_action.lock().await = Some((address.to_owned(), pid));
        }
        let stdout = child.stdout.take().expect("piped helper stdout");
        let stderr = child.stderr.take().expect("piped helper stderr");
        let mut output = Vec::new();
        let mut errors = Vec::new();
        let mut wait = Box::pin(async {
            let mut limited_stdout = stdout.take((MAX_OUTPUT + 1) as u64);
            let mut limited_stderr = stderr.take((MAX_FRAME + 1) as u64);
            let (out, err, status) = tokio::join!(
                limited_stdout.read_to_end(&mut output),
                limited_stderr.read_to_end(&mut errors),
                child.wait()
            );
            out?;
            err?;
            status
        });
        let result = match tokio::time::timeout(deadline, &mut wait).await {
            Ok(result) => result,
            Err(_) => {
                // Give the shell helper time to run its cleanup and profile
                // rollback traps. An abrupt kill can leave endpoints muted.
                unsafe {
                    libc::kill(pid as i32, libc::SIGTERM);
                }
                match tokio::time::timeout(Duration::from_secs(8), &mut wait).await {
                    Ok(result) => result,
                    Err(_) => {
                        unsafe {
                            libc::kill(pid as i32, libc::SIGKILL);
                        }
                        let _ = tokio::time::timeout(Duration::from_secs(2), &mut wait).await;
                        if action.is_some() {
                            *self.active_action.lock().await = None;
                        }
                        return Err(Failure::unknown(format!("{name} timed out")));
                    }
                }
            }
        };
        if action.is_some() {
            *self.active_action.lock().await = None;
        }
        drop(wait);
        let status = result
            .map_err(|error| Failure::unknown(format!("{name} outcome is unknown: {error}")))?;
        if output.len() > MAX_OUTPUT || errors.len() > MAX_FRAME {
            return Err(Failure::rejected(
                "too_large",
                "Bluetooth helper output is too large",
            ));
        }
        if !status.success() {
            let message = String::from_utf8_lossy(&errors).trim().to_owned();
            if status.code() == Some(2) && name == "bluetooth-audio-profile-set" {
                return Ok(json!({"outcome":"persistence_failed", "message":message}));
            }
            return Err(Failure::rejected(
                "failed",
                if message.is_empty() {
                    format!("{name} failed")
                } else {
                    message
                },
            ));
        }
        if name == "bluetooth-audio-profiles" {
            serde_json::from_slice(&output)
                .map_err(|_| Failure::rejected("invalid_state", "Invalid audio profile inventory"))
        } else {
            Ok(json!({"outcome":"applied"}))
        }
    }

    async fn handle(&self, request: &Request) -> Result<Value, Failure> {
        match request.method.as_str() {
            "hello" => Ok(
                json!({"name":"omarchy-bluetooth-service", "protocolVersion":1,
                "capabilities":["device.action","device.cancel","device.property","profile.list","profile.set","policy.set","health"]}),
            ),
            "health" => Ok(json!({"status":"ok", "pid":std::process::id()})),
            "profile.list" => {
                self.script(
                    "bluetooth-audio-profiles",
                    &[],
                    Duration::from_secs(5),
                    None,
                )
                .await
            }
            "device.action" => {
                let action = string(&request.params, "action")?;
                let device = string(&request.params, "address")?;
                if !["pair", "connect", "disconnect", "forget"].contains(&action)
                    || !address(device)
                {
                    return Err(Failure::rejected(
                        "invalid_params",
                        "Invalid Bluetooth action",
                    ));
                }
                let _guard = self.mutation.lock().await;
                self.script(
                    "bluetooth-device-action",
                    &[action, device],
                    Duration::from_secs(50),
                    Some(device),
                )
                .await
            }
            "device.cancel" => {
                let device = string(&request.params, "address")?;
                if !address(device) {
                    return Err(Failure::rejected(
                        "invalid_params",
                        "Invalid Bluetooth address",
                    ));
                }
                let active = self.active_action.lock().await;
                if let Some((address, pid)) = active.as_ref() {
                    if address.eq_ignore_ascii_case(device) {
                        unsafe {
                            libc::kill(*pid as i32, libc::SIGTERM);
                        }
                        return Ok(json!({"outcome":"cancel_requested"}));
                    }
                }
                Ok(json!({"outcome":"already_finished"}))
            }
            "device.property" => {
                let property = string(&request.params, "property")?;
                let path = string(&request.params, "path")?;
                let value = string(&request.params, "value")?;
                if !["name", "trusted", "blocked", "wakeAllowed"].contains(&property)
                    || !path.starts_with("/org/bluez/hci")
                    || path.len() > 100
                    || (property == "name" && value.len() > 160)
                    || (property != "name" && value != "true" && value != "false")
                    || value.chars().any(char::is_control)
                {
                    return Err(Failure::rejected(
                        "invalid_params",
                        "Invalid Bluetooth property",
                    ));
                }
                let _guard = self.mutation.lock().await;
                self.script(
                    "bluetooth-device-property",
                    &[property, path, value],
                    Duration::from_secs(8),
                    None,
                )
                .await
            }
            "profile.set" => {
                let device = string(&request.params, "address")?;
                let profile = string(&request.params, "profile")?;
                if !address(device) || !identifier(profile) {
                    return Err(Failure::rejected(
                        "invalid_params",
                        "Invalid Bluetooth audio mode",
                    ));
                }
                let _guard = self.mutation.lock().await;
                self.script(
                    "bluetooth-audio-profile-set",
                    &[device, profile],
                    Duration::from_secs(40),
                    None,
                )
                .await
            }
            "policy.set" => {
                let device = string(&request.params, "address")?;
                let policy = string(&request.params, "policy")?;
                if !address(device) || !["manual", "output", "output-mic"].contains(&policy) {
                    return Err(Failure::rejected(
                        "invalid_params",
                        "Invalid Bluetooth audio policy",
                    ));
                }
                let _guard = self.mutation.lock().await;
                self.script(
                    "audio-preferences",
                    &["set-policy", device, policy],
                    Duration::from_secs(8),
                    None,
                )
                .await
            }
            _ => Err(Failure::rejected(
                "method_not_found",
                "Unknown Bluetooth command",
            )),
        }
    }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args == ["--build-info"] {
        println!(
            "{}",
            json!({
                "sourceId": env!("BLUETOOTH_BUILD_ID"),
                "target": env!("BLUETOOTH_BUILD_TARGET"),
                "protocolVersion": 1
            })
        );
        return Ok(());
    }
    if args != ["--stdio"] {
        return Err("Usage: omarchy-bluetooth-service --stdio|--build-info".into());
    }
    let executable = std::env::current_exe()?;
    let scripts = executable
        .parent()
        .and_then(|path| path.parent())
        .ok_or("Backend has no plugin root")?
        .join("scripts");
    let service = Arc::new(Service {
        scripts,
        mutation: Mutex::new(()),
        active_action: Mutex::new(None),
    });
    let (tx, mut rx) = mpsc::channel::<Value>(32);
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(reply) = rx.recv().await {
            let mut bytes = serde_json::to_vec(&reply)?;
            bytes.push(b'\n');
            stdout.write_all(&bytes).await?;
            stdout.flush().await?;
        }
        Ok::<(), std::io::Error>(())
    });
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut line = Vec::new();
    loop {
        line.clear();
        if !read_frame(&mut stdin, &mut line).await? {
            break;
        }
        let Ok(request) = serde_json::from_slice::<Request>(&line) else {
            break;
        };
        if request.version != 1
            || request.id.is_empty()
            || request.id.len() > 80
            || !request.params.is_object()
        {
            break;
        }
        let service = service.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            let result = service.handle(&request).await;
            let reply = match result {
                Ok(result) => json!({"version":1,"id":request.id,"result":result}),
                Err(error) => json!({"version":1,"id":request.id,"error":error}),
            };
            let _ = tx.send(reply).await;
        });
    }
    drop(tx);
    writer.await??;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn address_checks_shape() {
        assert!(address("00:11:22:aa:BB:cc"));
        assert!(!address("00:11:22:aa:BB:c-"));
        assert!(!address("00-11-22-aa-BB-cc"));
    }
}
