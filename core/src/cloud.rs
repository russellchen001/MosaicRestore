use crate::provider::{
    ProgressUpdate, RestorationProvider, RestoreControl, RestoreError, RestoreErrorKind,
    RestoreResult,
};
use crate::{ComputeBackend, RestoreRequest, TaskState};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};

const DETECTOR: &str = "lada-yolo-v4";
const RESTORER: &str = "basicvsrpp";
const BACKEND: &str = "cuda";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudConfig {
    pub adapter: PathBuf,
    pub profile: String,
    pub status_retries: u32,
    pub poll_millis: u64,
}

impl CloudConfig {
    pub fn from_file(path: impl AsRef<Path>) -> Result<Self, RestoreError> {
        let path = path.as_ref();
        let contents = fs::read_to_string(path).map_err(|error| {
            RestoreError::new(
                RestoreErrorKind::InvalidRequest,
                format!("failed to read cloud config {}: {error}", path.display()),
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
                    format!("invalid cloud config line {}", index + 1),
                ));
            };
            values.insert(key.trim().to_string(), value.trim().to_string());
        }
        if values.get("version").map(String::as_str) != Some("1") {
            return Err(RestoreError::new(
                RestoreErrorKind::InvalidRequest,
                "cloud config requires version=1",
            ));
        }
        let adapter = values
            .remove("adapter")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .ok_or_else(|| {
                RestoreError::new(
                    RestoreErrorKind::InvalidRequest,
                    "cloud config requires adapter",
                )
            })?;
        let profile = values
            .remove("profile")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                RestoreError::new(
                    RestoreErrorKind::InvalidRequest,
                    "cloud config requires profile",
                )
            })?;
        let status_retries = parse_optional(&values, "status_retries", 3)?;
        let poll_millis = parse_optional(&values, "poll_millis", 1000)?;
        if !adapter.is_file() {
            return Err(RestoreError::new(
                RestoreErrorKind::ProviderUnavailable,
                format!("cloud adapter not found: {}", adapter.display()),
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
                format!("cloud config {key} is invalid"),
            )
        })
    })
}

pub struct CloudNvidiaProvider {
    config: CloudConfig,
}

impl CloudNvidiaProvider {
    pub fn from_config(path: impl AsRef<Path>) -> Result<Self, RestoreError> {
        Ok(Self {
            config: CloudConfig::from_file(path)?,
        })
    }

    fn invoke(&self, action: &str, args: &[(&str, &Path)]) -> Result<Output, RestoreError> {
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
                format!("cloud adapter {action} failed to start: {error}"),
            )
        })
    }

    fn checked(&self, action: &str, args: &[(&str, &Path)]) -> Result<String, RestoreError> {
        let output = self.invoke(action, args)?;
        if !output.status.success() {
            return Err(RestoreError::new(
                RestoreErrorKind::ExecutionFailed,
                format!(
                    "cloud adapter {action} failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }

    fn report(control: &RestoreControl<'_>, percent: u8, stage: &'static str) {
        control.progress.report(ProgressUpdate {
            percent,
            state: TaskState::Running,
            stage,
        });
    }
}

impl RestorationProvider for CloudNvidiaProvider {
    fn name(&self) -> &'static str {
        "cloud-nvidia"
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
        let job = Path::new(&job_id);

        Self::report(control, 5, "validating-cloud-config");
        self.checked("validate", &[])?;

        Self::report(control, 10, "uploading");
        self.checked("upload", &[("--job", job), ("--input", &request.input)])?;

        Self::report(control, 15, "gpu-runtime-readiness");
        let readiness = parse_values(&self.checked("readiness", &[("--job", job)])?);
        for key in ["gpu", "driver", "cuda", "runtime", "detector"] {
            if readiness.get(key).map(String::as_str) != Some("ready") {
                return Err(RestoreError::new(
                    RestoreErrorKind::ProviderUnavailable,
                    format!("cloud readiness failed: {key} is not ready"),
                ));
            }
        }
        Self::report(
            control,
            18,
            if readiness.get("cache_hit").map(String::as_str) == Some("true") {
                "runtime-cache-hit"
            } else {
                "runtime-cache-miss"
            },
        );

        let estimate = parse_values(&self.checked("estimate", &[("--job", job)])?);
        let seconds = estimate
            .get("estimated_seconds")
            .map(String::as_str)
            .unwrap_or("unknown");
        let cost = estimate
            .get("estimated_cost_usd")
            .map(String::as_str)
            .unwrap_or("unknown");
        println!("CLOUD estimated_seconds={seconds} estimated_cost_usd={cost}");

        let detector = Path::new(DETECTOR);
        let restorer = Path::new(RESTORER);
        let backend = Path::new(BACKEND);
        let start_args = [
            ("--job", job),
            ("--detector", detector),
            ("--restorer", restorer),
            ("--backend", backend),
        ];
        if self.checked("start", &start_args).is_err() {
            Self::report(control, 20, "recovering-connection");
            let status = self.checked("status", &[("--job", job)])?;
            let state = parse_values(&status);
            if !matches!(
                state.get("state").map(String::as_str),
                Some("running" | "succeeded")
            ) {
                return Err(RestoreError::new(
                    RestoreErrorKind::ExecutionFailed,
                    "cloud runner did not start and no resumable job was found",
                ));
            }
        }
        Self::report(control, 25, "remote-runner-started");

        let mut connection_failures = 0;
        loop {
            if control.cancellation.is_cancelled() {
                let _ = self.checked("cancel", &[("--job", job)]);
                return Err(RestoreError::new(
                    RestoreErrorKind::Cancelled,
                    "cloud restore cancelled",
                ));
            }
            match self.checked("status", &[("--job", job)]) {
                Ok(text) => {
                    connection_failures = 0;
                    let values = parse_values(&text);
                    match values.get("state").map(String::as_str) {
                        Some("succeeded") => break,
                        Some("failed") => {
                            return Err(RestoreError::new(
                                RestoreErrorKind::ExecutionFailed,
                                values
                                    .get("message")
                                    .cloned()
                                    .unwrap_or_else(|| "remote runner failed".to_string()),
                            ));
                        }
                        Some("cancelled") => {
                            return Err(RestoreError::new(
                                RestoreErrorKind::Cancelled,
                                "remote runner was cancelled",
                            ));
                        }
                        Some("running" | "pending") => {
                            let remote = values
                                .get("progress")
                                .and_then(|value| value.parse::<u8>().ok())
                                .unwrap_or(0)
                                .min(100);
                            Self::report(
                                control,
                                25 + remote.saturating_mul(60) / 100,
                                "remote-progress",
                            );
                        }
                        _ => {
                            return Err(RestoreError::new(
                                RestoreErrorKind::ExecutionFailed,
                                "cloud adapter returned an invalid job state",
                            ));
                        }
                    }
                }
                Err(error) => {
                    connection_failures += 1;
                    if connection_failures > self.config.status_retries {
                        return Err(error);
                    }
                    Self::report(control, 25, "recovering-connection");
                }
            }
            thread::sleep(Duration::from_millis(self.config.poll_millis));
        }

        Self::report(control, 90, "downloading");
        self.checked("download", &[("--job", job), ("--output", &request.output)])?;
        let valid = request
            .output
            .metadata()
            .map(|metadata| metadata.is_file() && metadata.len() > 0)
            .unwrap_or(false);
        if !valid {
            return Err(RestoreError::new(
                RestoreErrorKind::OutputMissing,
                "cloud adapter completed without a non-empty output",
            ));
        }
        Self::report(control, 95, "output-validated");
        Ok(RestoreResult {
            output: request.output.clone(),
        })
    }
}

fn stable_job_id(request: &RestoreRequest) -> Result<String, RestoreError> {
    let metadata = request.input.metadata().map_err(|error| {
        RestoreError::new(
            RestoreErrorKind::InvalidRequest,
            format!("failed to inspect cloud input: {error}"),
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
    Ok(format!("mosaic-{hash:016x}"))
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
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::SystemTime;

    static FIXTURE_ID: AtomicU64 = AtomicU64::new(0);

    fn fixture(script: &str) -> (PathBuf, PathBuf, PathBuf, PathBuf) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let id = FIXTURE_ID.fetch_add(1, Ordering::SeqCst);
        let root =
            std::env::temp_dir().join(format!("mosaic-cloud-{}-{nonce}-{id}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let adapter = root.join("adapter");
        fs::write(&adapter, script).unwrap();
        let mut permissions = fs::metadata(&adapter).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&adapter, permissions).unwrap();
        let config = root.join("cloud.conf");
        fs::write(
            &config,
            format!(
                "version=1\nadapter={}\nprofile=test\npoll_millis=10\n",
                adapter.display()
            ),
        )
        .unwrap();
        let input = root.join("input.mp4");
        let output = root.join("output.mp4");
        fs::write(&input, b"cloud-video").unwrap();
        (root, config, input, output)
    }

    const SUCCESS_ADAPTER: &str = r#"#!/bin/sh
action="$1"; shift
job=""
input=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --job) job="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) shift 2 ;;
  esac
done
root="$(dirname "$0")"
case "$action" in
  validate) exit 0 ;;
  upload) cp "$input" "$root/uploaded" ;;
  readiness) printf 'gpu=ready\ndriver=ready\ncuda=ready\nruntime=ready\ndetector=ready\ncache_hit=true\n' ;;
  estimate) printf 'estimated_seconds=12\nestimated_cost_usd=0.25\n' ;;
  start) printf running > "$root/state" ;;
  status) printf 'state=succeeded\nprogress=100\n' ;;
  cancel) printf cancelled > "$root/state" ;;
  download) cp "$root/uploaded" "$output" ;;
  *) exit 9 ;;
esac
"#;

    #[test]
    fn cloud_contract_uploads_checks_cache_runs_and_downloads() {
        let (root, config, input, output) = fixture(SUCCESS_ADAPTER);
        let provider = CloudNvidiaProvider::from_config(config).unwrap();
        let request = RestoreRequest {
            input,
            output: output.clone(),
            backend: ComputeBackend::NvidiaCuda,
        };
        let cancellation = CancellationToken::new();
        let updates = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&updates);
        let reporter = move |update| captured.lock().unwrap().push(update);
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        run_restore(&provider, &request, &control).unwrap();
        assert_eq!(fs::read(output).unwrap(), b"cloud-video");
        let stages = updates.lock().unwrap();
        assert!(
            stages
                .iter()
                .any(|update| update.stage == "runtime-cache-hit")
        );
        assert!(
            stages
                .iter()
                .any(|update| update.stage == "remote-runner-started")
        );
        assert!(stages.iter().any(|update| update.stage == "downloading"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejects_incomplete_readiness() {
        let script = SUCCESS_ADAPTER.replace("cuda=ready", "cuda=missing");
        let (root, config, input, output) = fixture(&script);
        let provider = CloudNvidiaProvider::from_config(config).unwrap();
        let request = RestoreRequest {
            input,
            output,
            backend: ComputeBackend::NvidiaCuda,
        };
        let cancellation = CancellationToken::new();
        let reporter = |_| {};
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        assert_eq!(
            run_restore(&provider, &request, &control).unwrap_err().kind,
            RestoreErrorKind::ProviderUnavailable
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancellation_reaches_remote_adapter() {
        let script = SUCCESS_ADAPTER.replace(
            "status) printf 'state=succeeded\\nprogress=100\\n' ;;",
            "status) printf 'state=running\\nprogress=30\\n' ;;",
        );
        let (root, config, input, output) = fixture(&script);
        let provider = CloudNvidiaProvider::from_config(config).unwrap();
        let request = RestoreRequest {
            input,
            output,
            backend: ComputeBackend::NvidiaCuda,
        };
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
        let error = run_restore(&provider, &request, &control).unwrap_err();
        thread.join().unwrap();
        assert_eq!(error.kind, RestoreErrorKind::Cancelled);
        assert_eq!(fs::read_to_string(root.join("state")).unwrap(), "cancelled");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn transient_status_failure_is_recovered() {
        let script = SUCCESS_ADAPTER.replace(
            "status) printf 'state=succeeded\\nprogress=100\\n' ;;",
            "status) if [ ! -f \"$root/retry\" ]; then touch \"$root/retry\"; exit 8; fi; printf 'state=succeeded\\nprogress=100\\n' ;;",
        );
        let (root, config, input, output) = fixture(&script);
        let provider = CloudNvidiaProvider::from_config(config).unwrap();
        let request = RestoreRequest {
            input,
            output,
            backend: ComputeBackend::NvidiaCuda,
        };
        let cancellation = CancellationToken::new();
        let updates = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&updates);
        let reporter = move |update| captured.lock().unwrap().push(update);
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        run_restore(&provider, &request, &control).unwrap();
        assert!(
            updates
                .lock()
                .unwrap()
                .iter()
                .any(|update| update.stage == "recovering-connection")
        );
        fs::remove_dir_all(root).unwrap();
    }
}
