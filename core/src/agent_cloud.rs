use crate::provider::{
    ProgressUpdate, RestorationProvider, RestoreControl, RestoreError, RestoreErrorKind,
    RestoreResult,
};
use crate::{ComputeBackend, RestoreRequest, TaskState};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};

const CONTRACT_VERSION: &str = "1";
const TRANSPORT: &str = "agent-gui";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentCloudConfig {
    pub adapter: PathBuf,
    pub profile: String,
    pub status_retries: u32,
    pub poll_millis: u64,
}

impl AgentCloudConfig {
    pub fn from_file(path: impl AsRef<Path>) -> Result<Self, RestoreError> {
        let path = path.as_ref();
        let contents = fs::read_to_string(path).map_err(|error| {
            RestoreError::new(
                RestoreErrorKind::InvalidRequest,
                format!(
                    "failed to read agent cloud config {}: {error}",
                    path.display()
                ),
            )
        })?;
        let mut values = HashMap::new();
        for (index, raw_line) in contents.lines().enumerate() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                return Err(RestoreError::new(
                    RestoreErrorKind::InvalidRequest,
                    format!("invalid agent cloud config line {}", index + 1),
                ));
            };
            values.insert(key.trim().to_string(), value.trim().to_string());
        }
        if values.get("version").map(String::as_str) != Some(CONTRACT_VERSION) {
            return Err(RestoreError::new(
                RestoreErrorKind::InvalidRequest,
                "agent cloud config requires version=1",
            ));
        }
        let adapter = values
            .remove("adapter")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .ok_or_else(|| {
                RestoreError::new(
                    RestoreErrorKind::InvalidRequest,
                    "agent cloud config requires adapter",
                )
            })?;
        let profile = values
            .remove("profile")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                RestoreError::new(
                    RestoreErrorKind::InvalidRequest,
                    "agent cloud config requires profile",
                )
            })?;
        let status_retries = parse_optional(&values, "status_retries", 3)?;
        let poll_millis = parse_optional(&values, "poll_millis", 1000)?;
        if !adapter.is_file() {
            return Err(RestoreError::new(
                RestoreErrorKind::ProviderUnavailable,
                format!("agent cloud adapter not found: {}", adapter.display()),
            ));
        }
        Ok(Self {
            adapter: adapter.canonicalize().unwrap_or(adapter),
            profile,
            status_retries,
            poll_millis,
        })
    }
}

fn parse_optional<T>(
    values: &HashMap<String, String>,
    key: &str,
    default: T,
) -> Result<T, RestoreError>
where
    T: std::str::FromStr,
{
    values.get(key).map_or(Ok(default), |value| {
        value.parse().map_err(|_| {
            RestoreError::new(
                RestoreErrorKind::InvalidRequest,
                format!("agent cloud config {key} is invalid"),
            )
        })
    })
}

pub struct AgentCloudComputerProvider {
    config: AgentCloudConfig,
}

impl AgentCloudComputerProvider {
    pub fn from_config(path: impl AsRef<Path>) -> Result<Self, RestoreError> {
        Ok(Self {
            config: AgentCloudConfig::from_file(path)?,
        })
    }

    fn invoke(&self, action: &str, args: &[(&str, &OsStr)]) -> Result<Output, RestoreError> {
        let mut command = Command::new(&self.config.adapter);
        command
            .arg(action)
            .arg("--profile")
            .arg(&self.config.profile);
        for (name, value) in args {
            command.arg(name).arg(value);
        }
        command.output().map_err(|error| {
            RestoreError::new(
                RestoreErrorKind::ProviderUnavailable,
                format!("agent cloud adapter {action} failed to start: {error}"),
            )
        })
    }

    fn checked(&self, action: &str, args: &[(&str, &OsStr)]) -> Result<String, RestoreError> {
        let output = self.invoke(action, args)?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let values = parse_values(&stderr);
            let kind = match values.get("error_kind").map(String::as_str) {
                Some("invalid-request") => RestoreErrorKind::InvalidRequest,
                Some("provider-unavailable") => RestoreErrorKind::ProviderUnavailable,
                Some("cancelled") => RestoreErrorKind::Cancelled,
                Some("output-missing") => RestoreErrorKind::OutputMissing,
                Some("output-invalid") => RestoreErrorKind::OutputInvalid,
                _ => RestoreErrorKind::ExecutionFailed,
            };
            let message = values
                .get("message")
                .cloned()
                .unwrap_or_else(|| stderr.trim().to_string());
            return Err(RestoreError::new(
                kind,
                format!("agent cloud adapter {action} failed: {message}"),
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }

    fn values(
        &self,
        action: &str,
        args: &[(&str, &OsStr)],
    ) -> Result<HashMap<String, String>, RestoreError> {
        Ok(parse_values(&self.checked(action, args)?))
    }

    fn report(control: &RestoreControl<'_>, percent: u8, stage: &'static str) {
        control.progress.report(ProgressUpdate {
            percent,
            state: TaskState::Running,
            stage,
        });
    }

    fn require<'a>(
        values: &'a HashMap<String, String>,
        key: &str,
        expected: &str,
        context: &str,
    ) -> Result<&'a str, RestoreError> {
        let actual = values.get(key).map(String::as_str).unwrap_or("missing");
        if actual != expected {
            return Err(RestoreError::new(
                RestoreErrorKind::ProviderUnavailable,
                format!("agent cloud {context} requires {key}={expected}, got {actual}"),
            ));
        }
        Ok(actual)
    }

    fn restore_session(
        &self,
        request: &RestoreRequest,
        control: &RestoreControl<'_>,
        job_id: &str,
        session_id: &str,
    ) -> Result<RestoreResult, RestoreError> {
        let job = OsStr::new(job_id);
        let session = OsStr::new(session_id);

        Self::report(control, 10, "agent-desktop-readiness");
        let readiness = self.values("readiness", &[("--session", session), ("--job", job)])?;
        for key in ["agent", "desktop", "gpu", "application"] {
            Self::require(&readiness, key, "ready", "readiness")?;
        }
        Self::require(&readiness, "transport", TRANSPORT, "readiness")?;

        Self::report(control, 18, "agent-uploading");
        self.checked(
            "upload",
            &[
                ("--session", session),
                ("--job", job),
                ("--input", request.input.as_os_str()),
            ],
        )?;

        let estimate = self.values("estimate", &[("--session", session), ("--job", job)])?;
        let seconds = estimate
            .get("estimated_seconds")
            .map(String::as_str)
            .unwrap_or("unknown");
        let cost = estimate
            .get("estimated_cost_usd")
            .map(String::as_str)
            .unwrap_or("unknown");
        println!(
            "AGENT_CLOUD session_id={session_id} estimated_seconds={seconds} estimated_cost_usd={cost}"
        );

        Self::report(control, 25, "agent-gui-launching");
        let started = self.values(
            "start",
            &[
                ("--session", session),
                ("--job", job),
                ("--task", OsStr::new("restore-video")),
            ],
        )?;
        Self::require(&started, "transport", TRANSPORT, "start receipt")?;
        if started.get("action_receipt").is_none_or(String::is_empty) {
            return Err(RestoreError::new(
                RestoreErrorKind::ExecutionFailed,
                "agent cloud start did not return GUI action evidence",
            ));
        }
        Self::report(control, 30, "agent-gui-started");

        let mut connection_failures = 0;
        loop {
            if control.cancellation.is_cancelled() {
                self.checked("cancel", &[("--session", session), ("--job", job)])?;
                return Err(RestoreError::new(
                    RestoreErrorKind::Cancelled,
                    "agent cloud restore cancelled",
                ));
            }

            let status = match self.values("status", &[("--session", session), ("--job", job)]) {
                Ok(status) => {
                    connection_failures = 0;
                    status
                }
                Err(error) => {
                    connection_failures += 1;
                    if connection_failures > self.config.status_retries {
                        return Err(error);
                    }
                    Self::report(control, 30, "agent-session-reconnecting");
                    let reconnected =
                        self.values("reconnect", &[("--session", session), ("--job", job)])?;
                    Self::require(&reconnected, "session_id", session_id, "reconnect")?;
                    Self::require(&reconnected, "agent", "ready", "reconnect")?;
                    thread::sleep(Duration::from_millis(self.config.poll_millis));
                    continue;
                }
            };

            Self::require(&status, "session_id", session_id, "status")?;
            Self::require(&status, "transport", TRANSPORT, "status")?;
            match status.get("state").map(String::as_str) {
                Some("succeeded") => {
                    let actions = status
                        .get("gui_actions")
                        .and_then(|value| value.parse::<u64>().ok())
                        .unwrap_or(0);
                    if actions == 0
                        || status.get("result_ready").map(String::as_str) != Some("true")
                    {
                        return Err(RestoreError::new(
                            RestoreErrorKind::ExecutionFailed,
                            "agent cloud completed without GUI action evidence or a ready result",
                        ));
                    }
                    break;
                }
                Some("failed") => {
                    return Err(RestoreError::new(
                        RestoreErrorKind::ExecutionFailed,
                        status
                            .get("message")
                            .cloned()
                            .unwrap_or_else(|| "remote agent failed".to_string()),
                    ));
                }
                Some("cancelled") => {
                    return Err(RestoreError::new(
                        RestoreErrorKind::Cancelled,
                        "remote agent was cancelled",
                    ));
                }
                Some("running" | "pending") => {
                    let remote = status
                        .get("progress")
                        .and_then(|value| value.parse::<u8>().ok())
                        .unwrap_or(0)
                        .min(100);
                    Self::report(
                        control,
                        30 + remote.saturating_mul(55) / 100,
                        "agent-gui-progress",
                    );
                }
                _ => {
                    return Err(RestoreError::new(
                        RestoreErrorKind::ExecutionFailed,
                        "agent cloud adapter returned an invalid task state",
                    ));
                }
            }
            thread::sleep(Duration::from_millis(self.config.poll_millis));
        }

        Self::report(control, 90, "agent-downloading");
        self.checked(
            "download",
            &[
                ("--session", session),
                ("--job", job),
                ("--output", request.output.as_os_str()),
            ],
        )?;
        let valid = request
            .output
            .metadata()
            .map(|metadata| metadata.is_file() && metadata.len() > 0)
            .unwrap_or(false);
        if !valid {
            return Err(RestoreError::new(
                RestoreErrorKind::OutputMissing,
                "agent cloud completed without a non-empty output",
            ));
        }

        let metadata = self.values("metadata", &[("--session", session), ("--job", job)])?;
        println!(
            "AGENT_CLOUD runtime={} session_id={} elapsed_seconds={} billed_cost_usd={}",
            metadata
                .get("runtime")
                .map(String::as_str)
                .unwrap_or("unknown"),
            session_id,
            metadata
                .get("elapsed_seconds")
                .map(String::as_str)
                .unwrap_or("unknown"),
            metadata
                .get("billed_cost_usd")
                .map(String::as_str)
                .unwrap_or("unknown")
        );
        Self::report(control, 95, "agent-output-validated");
        Ok(RestoreResult {
            output: request.output.clone(),
        })
    }
}

impl RestorationProvider for AgentCloudComputerProvider {
    fn name(&self) -> &'static str {
        "agent-cloud-computer"
    }

    fn supports(&self, backend: ComputeBackend) -> bool {
        backend == ComputeBackend::NvidiaCuda
    }

    fn restore(
        &self,
        request: &RestoreRequest,
        control: &RestoreControl<'_>,
    ) -> Result<RestoreResult, RestoreError> {
        let job_id = stable_job_id(request)?;
        let job = OsStr::new(&job_id);

        Self::report(control, 5, "validating-agent-cloud-config");
        let contract = self.values("validate", &[])?;
        Self::require(
            &contract,
            "contract_version",
            CONTRACT_VERSION,
            "adapter contract",
        )?;
        Self::require(&contract, "transport", TRANSPORT, "adapter contract")?;

        Self::report(control, 7, "agent-session-opening");
        let opened = self.values("open-session", &[("--job", job)])?;
        Self::require(&opened, "transport", TRANSPORT, "session")?;
        let session_id = opened
            .get("session_id")
            .filter(|value| !value.is_empty())
            .cloned()
            .ok_or_else(|| {
                RestoreError::new(
                    RestoreErrorKind::ProviderUnavailable,
                    "agent cloud did not return a session id",
                )
            })?;
        let session = OsStr::new(&session_id);

        let result = self.restore_session(request, control, &job_id, &session_id);
        let cleanup = self.checked("cleanup", &[("--session", session), ("--job", job)]);
        match (result, cleanup) {
            (Ok(result), Ok(_)) => Ok(result),
            (Ok(_), Err(error)) => Err(error),
            (Err(error), _) => Err(error),
        }
    }
}

fn stable_job_id(request: &RestoreRequest) -> Result<String, RestoreError> {
    let metadata = request.input.metadata().map_err(|error| {
        RestoreError::new(
            RestoreErrorKind::InvalidRequest,
            format!("failed to inspect agent cloud input: {error}"),
        )
    })?;
    let modified = metadata
        .modified()
        .unwrap_or(UNIX_EPOCH)
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut hash = 0xcbf29ce484222325u64;
    for byte in request.input.to_string_lossy().bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash ^= metadata.len();
    hash ^= modified as u64;
    Ok(format!("mosaic-agent-{hash:016x}"))
}

fn parse_values(text: &str) -> HashMap<String, String> {
    text.lines()
        .filter_map(|line| line.trim().split_once('='))
        .map(|(key, value)| (key.trim().to_string(), value.trim().to_string()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{CancellationToken, RestoreControl};
    use crate::runner::run_restore;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Arc, Mutex};
    use std::time::SystemTime;

    const SUCCESS_ADAPTER: &str = r#"#!/bin/sh
action="$1"; shift
session=""; input=""; output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) session="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) shift 2 ;;
  esac
done
root="$(dirname "$0")"
printf '%s\n' "$action" >> "$root/events"
case "$action" in
  validate) printf 'contract_version=1\ntransport=agent-gui\nruntime=ufo2\n' ;;
  open-session) printf 'session_id=session-1\ntransport=agent-gui\n' ;;
  readiness) printf 'session_id=%s\ntransport=agent-gui\nagent=ready\ndesktop=ready\ngpu=ready\napplication=ready\n' "$session" ;;
  upload) cp "$input" "$root/uploaded.mp4" ;;
  estimate) printf 'estimated_seconds=12\nestimated_cost_usd=0.25\n' ;;
  start) printf 'state=running\ntransport=agent-gui\naction_receipt=screenshot-1\n' ;;
  status)
    if [ -f "$root/hold" ]; then
      printf 'session_id=%s\ntransport=agent-gui\nstate=running\nprogress=35\ngui_actions=3\n' "$session"
    else
      printf 'session_id=%s\ntransport=agent-gui\nstate=succeeded\nprogress=100\ngui_actions=7\nresult_ready=true\n' "$session"
    fi
    ;;
  reconnect) printf 'session_id=%s\nagent=ready\n' "$session" ;;
  cancel) printf cancelled > "$root/cancelled" ;;
  download) cp "$root/uploaded.mp4" "$output" ;;
  metadata) printf 'runtime=ufo2\nelapsed_seconds=11\nbilled_cost_usd=0.22\n' ;;
  cleanup) touch "$root/cleaned" ;;
  *) exit 9 ;;
esac
"#;

    fn fixture(script: &str) -> (PathBuf, PathBuf, PathBuf, PathBuf) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("mosaic-agent-cloud-{}-{nonce}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let adapter = root.join("adapter");
        fs::write(&adapter, script).unwrap();
        let mut permissions = fs::metadata(&adapter).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&adapter, permissions).unwrap();
        let config = root.join("agent-cloud.conf");
        fs::write(
            &config,
            format!(
                "version=1\nadapter={}\nprofile=test\npoll_millis=10\nstatus_retries=2\n",
                adapter.display()
            ),
        )
        .unwrap();
        let input = root.join("input.mp4");
        let output = root.join("output.mp4");
        fs::write(&input, b"agent-gui-video").unwrap();
        (root, config, input, output)
    }

    fn request(input: PathBuf, output: PathBuf) -> RestoreRequest {
        RestoreRequest {
            input,
            output,
            backend: ComputeBackend::NvidiaCuda,
        }
    }

    #[test]
    fn agent_cloud_runs_complete_gui_lifecycle_and_cleanup() {
        let (root, config, input, output) = fixture(SUCCESS_ADAPTER);
        let provider = AgentCloudComputerProvider::from_config(config).unwrap();
        let cancellation = CancellationToken::new();
        let updates = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&updates);
        let reporter = move |update| captured.lock().unwrap().push(update);
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        run_restore(&provider, &request(input, output.clone()), &control).unwrap();
        assert_eq!(fs::read(output).unwrap(), b"agent-gui-video");
        assert!(root.join("cleaned").is_file());
        let events = fs::read_to_string(root.join("events")).unwrap();
        for action in [
            "validate",
            "open-session",
            "readiness",
            "upload",
            "start",
            "status",
            "download",
            "metadata",
            "cleanup",
        ] {
            assert!(events.lines().any(|event| event == action));
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejects_ssh_bypass_transport() {
        let script = SUCCESS_ADAPTER.replacen("transport=agent-gui", "transport=ssh", 1);
        let (root, config, input, output) = fixture(&script);
        let provider = AgentCloudComputerProvider::from_config(config).unwrap();
        let cancellation = CancellationToken::new();
        let reporter = |_| {};
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        assert_eq!(
            run_restore(&provider, &request(input, output), &control)
                .unwrap_err()
                .kind,
            RestoreErrorKind::ProviderUnavailable
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn reconnects_the_same_agent_session_after_status_failure() {
        let script = SUCCESS_ADAPTER.replace(
            "status)\n    if [ -f \"$root/hold\" ]; then",
            "status)\n    if [ ! -f \"$root/retried\" ]; then touch \"$root/retried\"; exit 8; fi\n    if [ -f \"$root/hold\" ]; then",
        );
        let (root, config, input, output) = fixture(&script);
        let provider = AgentCloudComputerProvider::from_config(config).unwrap();
        let cancellation = CancellationToken::new();
        let updates = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&updates);
        let reporter = move |update| captured.lock().unwrap().push(update);
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        run_restore(&provider, &request(input, output), &control).unwrap();
        assert!(
            updates
                .lock()
                .unwrap()
                .iter()
                .any(|update| update.stage == "agent-session-reconnecting")
        );
        assert!(
            fs::read_to_string(root.join("events"))
                .unwrap()
                .lines()
                .any(|event| event == "reconnect")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancellation_reaches_agent_before_cleanup() {
        let (root, config, input, output) = fixture(SUCCESS_ADAPTER);
        fs::write(root.join("hold"), b"").unwrap();
        let provider = AgentCloudComputerProvider::from_config(config).unwrap();
        let cancellation = CancellationToken::new();
        let trigger = cancellation.clone();
        let reporter = |_| {};
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        let thread = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            trigger.cancel();
        });
        let error = run_restore(&provider, &request(input, output), &control).unwrap_err();
        thread.join().unwrap();
        assert_eq!(error.kind, RestoreErrorKind::Cancelled);
        assert!(root.join("cancelled").is_file());
        assert!(root.join("cleaned").is_file());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn maps_structured_adapter_errors() {
        let script = SUCCESS_ADAPTER.replace(
            "validate) printf 'contract_version=1\\ntransport=agent-gui\\nruntime=ufo2\\n' ;;",
            "validate) printf 'error_kind=provider-unavailable\\nmessage=relay-offline\\n' >&2; exit 7 ;;",
        );
        let (root, config, input, output) = fixture(&script);
        let provider = AgentCloudComputerProvider::from_config(config).unwrap();
        let cancellation = CancellationToken::new();
        let reporter = |_| {};
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        let error = run_restore(&provider, &request(input, output), &control).unwrap_err();
        assert_eq!(error.kind, RestoreErrorKind::ProviderUnavailable);
        assert!(error.message.contains("relay-offline"));
        fs::remove_dir_all(root).unwrap();
    }
}
