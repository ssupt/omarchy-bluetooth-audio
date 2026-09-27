//! A single command owner for the Bluetooth panel. The shell keeps this
//! process alive independently of bar widgets on individual monitors.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{Mutex, Semaphore, mpsc};

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
    active_action: Mutex<Option<(String, u32)>>,
    jobs: Mutex<HashMap<String, Job>>,
}

struct Job {
    address: Option<String>,
    admitted: Instant,
    deadline: Duration,
    running: bool,
    cancelled: bool,
}

fn mutation_deadline(method: &str) -> Option<Duration> {
    match method {
        "device.action" => Some(Duration::from_secs(50)),
        "device.property" | "policy.set" => Some(Duration::from_secs(8)),
        "profile.set" => Some(Duration::from_secs(40)),
        _ => None,
    }
}

fn reply(request: &Request, result: Result<Value, Failure>) -> Value {
    match result {
        Ok(result) => json!({"version":1,"id":request.id,"result":result}),
        Err(error) => json!({"version":1,"id":request.id,"error":error}),
    }
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
        action: Option<(&str, &str)>,
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
        if let Some((request_id, address)) = action {
            *self.active_action.lock().await = Some((address.to_owned(), pid));
            if self
                .jobs
                .lock()
                .await
                .get(request_id)
                .is_some_and(|job| job.cancelled)
            {
                unsafe {
                    libc::kill(pid as i32, libc::SIGTERM);
                }
            }
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

    async fn handle(
        &self,
        request: &Request,
        remaining: Option<Duration>,
    ) -> Result<Value, Failure> {
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
                self.script(
                    "bluetooth-device-action",
                    &[action, device],
                    remaining.unwrap_or(Duration::from_secs(50)),
                    Some((&request.id, device)),
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
                let requested_id = request.params.get("requestId").and_then(Value::as_str);
                if request.params.get("requestId").is_some()
                    && requested_id.is_none_or(|id| id.is_empty() || id.len() > 80)
                {
                    return Err(Failure::rejected(
                        "invalid_params",
                        "Invalid Bluetooth command ID",
                    ));
                }
                let mut jobs = self.jobs.lock().await;
                let target = jobs
                    .iter()
                    .filter(|(id, job)| {
                        requested_id.is_none_or(|wanted| *id == wanted)
                            && job
                                .address
                                .as_deref()
                                .is_some_and(|value| value.eq_ignore_ascii_case(device))
                    })
                    .min_by_key(|(_, job)| job.admitted)
                    .map(|(id, _)| id.clone());
                if let Some(target) = target {
                    let job = jobs.get_mut(&target).expect("selected job");
                    job.cancelled = true;
                    if job.running {
                        let active = self.active_action.lock().await;
                        if let Some((address, pid)) = active.as_ref() {
                            if address.eq_ignore_ascii_case(device) {
                                unsafe {
                                    libc::kill(*pid as i32, libc::SIGTERM);
                                }
                            }
                        }
                    }
                    return Ok(json!({"outcome":"cancel_requested"}));
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
                self.script(
                    "bluetooth-device-property",
                    &[property, path, value],
                    remaining.unwrap_or(Duration::from_secs(8)),
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
                self.script(
                    "bluetooth-audio-profile-set",
                    &[device, profile],
                    remaining.unwrap_or(Duration::from_secs(40)),
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
                self.script(
                    "audio-preferences",
                    &["set-policy", device, policy],
                    remaining.unwrap_or(Duration::from_secs(8)),
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
        active_action: Mutex::new(None),
        jobs: Mutex::new(HashMap::new()),
    });
    let (tx, mut rx) = mpsc::channel::<Value>(32);
    let (mutation_tx, mut mutation_rx) = mpsc::channel::<Request>(32);
    let worker_service = service.clone();
    let worker_replies = tx.clone();
    let worker = tokio::spawn(async move {
        while let Some(request) = mutation_rx.recv().await {
            let remaining = {
                let mut jobs = worker_service.jobs.lock().await;
                let job = jobs.get_mut(&request.id).expect("admitted mutation");
                if job.cancelled {
                    None
                } else {
                    let left = job.deadline.saturating_sub(job.admitted.elapsed());
                    if left.is_zero() {
                        None
                    } else {
                        job.running = true;
                        Some(left)
                    }
                }
            };
            let result = if let Some(remaining) = remaining {
                worker_service.handle(&request, Some(remaining)).await
            } else {
                let jobs = worker_service.jobs.lock().await;
                if jobs.get(&request.id).is_some_and(|job| job.cancelled) {
                    Err(Failure::rejected(
                        "cancelled",
                        "Queued Bluetooth command was cancelled",
                    ))
                } else {
                    Err(Failure::rejected(
                        "timeout",
                        "Bluetooth command expired while queued",
                    ))
                }
            };
            worker_service.jobs.lock().await.remove(&request.id);
            if worker_replies.send(reply(&request, result)).await.is_err() {
                break;
            }
        }
    });
    let other_permits = Arc::new(Semaphore::new(32));
    let cancel_permits = Arc::new(Semaphore::new(4));
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
        if let Some(deadline) = mutation_deadline(&request.method) {
            let mut jobs = service.jobs.lock().await;
            if jobs.contains_key(&request.id) {
                drop(jobs);
                let _ = tx
                    .send(reply(
                        &request,
                        Err(Failure::rejected(
                            "duplicate_id",
                            "Bluetooth command ID is already pending",
                        )),
                    ))
                    .await;
                continue;
            }
            jobs.insert(
                request.id.clone(),
                Job {
                    address: request
                        .params
                        .get("address")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    admitted: Instant::now(),
                    deadline,
                    running: false,
                    cancelled: false,
                },
            );
            drop(jobs);
            if let Err(error) = mutation_tx.try_send(request) {
                let request = error.into_inner();
                service.jobs.lock().await.remove(&request.id);
                let _ = tx
                    .send(reply(
                        &request,
                        Err(Failure::rejected(
                            "busy",
                            "Bluetooth mutation queue is full",
                        )),
                    ))
                    .await;
            }
        } else {
            let permits = if request.method == "device.cancel" {
                cancel_permits.clone()
            } else {
                other_permits.clone()
            };
            let Ok(permit) = permits.try_acquire_owned() else {
                let _ = tx
                    .send(reply(
                        &request,
                        Err(Failure::rejected(
                            "busy",
                            "Too many Bluetooth commands are pending",
                        )),
                    ))
                    .await;
                continue;
            };
            let service = service.clone();
            let tx = tx.clone();
            tokio::spawn(async move {
                let result = service.handle(&request, None).await;
                let _ = tx.send(reply(&request, result)).await;
                drop(permit);
            });
        }
    }
    drop(mutation_tx);
    worker.await?;
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
