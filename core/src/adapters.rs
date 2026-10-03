use crate::provider::{
    ProgressUpdate, RestorationProvider, RestoreControl, RestoreError, RestoreErrorKind,
    RestoreResult,
};
use crate::{ComputeBackend, RestoreRequest, TaskState};
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

pub struct LocalLadaProvider {
    executable: PathBuf,
    working_directory: PathBuf,
}

impl LocalLadaProvider {
    pub fn from_root(root: impl Into<PathBuf>) -> Self {
        let requested_root = root.into();
        let root = requested_root.canonicalize().unwrap_or(requested_root);
        Self {
            executable: root.join(".venv/bin/lada-cli"),
            working_directory: root,
        }
    }
}

impl RestorationProvider for LocalLadaProvider {
    fn name(&self) -> &'static str {
        "local-lada-mps"
    }

    fn supports(&self, backend: ComputeBackend) -> bool {
        backend == ComputeBackend::AppleMps
    }

    fn restore(
        &self,
        request: &RestoreRequest,
        control: &RestoreControl<'_>,
    ) -> Result<RestoreResult, RestoreError> {
        run_external(
            &self.executable,
            &self.working_directory,
            &[
                "--device".into(),
                "mps".into(),
                "--mosaic-detection-model".into(),
                "v4-fast".into(),
                "--mosaic-restoration-model".into(),
                "basicvsrpp-v1.2".into(),
                "--encoding-preset".into(),
                "h264-cpu-fast".into(),
            ],
            request,
            control,
        )
    }
}

pub struct NvidiaJasnaProvider {
    runner: PathBuf,
}

impl NvidiaJasnaProvider {
    pub fn new(runner: impl Into<PathBuf>) -> Self {
        let requested_runner = runner.into();
        let runner = requested_runner.canonicalize().unwrap_or(requested_runner);
        Self { runner }
    }
}

impl RestorationProvider for NvidiaJasnaProvider {
    fn name(&self) -> &'static str {
        "nvidia-jasna"
    }

    fn supports(&self, backend: ComputeBackend) -> bool {
        backend == ComputeBackend::NvidiaCuda
    }

    fn restore(
        &self,
        request: &RestoreRequest,
        control: &RestoreControl<'_>,
    ) -> Result<RestoreResult, RestoreError> {
        let working_directory = self.runner.parent().unwrap_or_else(|| Path::new("."));
        run_external(
            &self.runner,
            working_directory,
            &[
                "--detector".into(),
                "lada-yolo-v4".into(),
                "--restorer".into(),
                "basicvsrpp".into(),
                "--backend".into(),
                "tensorrt".into(),
            ],
            request,
            control,
        )
    }
}

fn run_external(
    executable: &Path,
    working_directory: &Path,
    fixed_args: &[OsString],
    request: &RestoreRequest,
    control: &RestoreControl<'_>,
) -> Result<RestoreResult, RestoreError> {
    if !executable.is_file() {
        return Err(RestoreError::new(
            RestoreErrorKind::ProviderUnavailable,
            format!("provider executable not found: {}", executable.display()),
        ));
    }
    let input = request.input.canonicalize().map_err(|error| {
        RestoreError::new(
            RestoreErrorKind::InvalidRequest,
            format!("failed to resolve input path: {error}"),
        )
    })?;
    let output = if request.output.is_absolute() {
        request.output.clone()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(&request.output)
    };

    control.progress.report(ProgressUpdate {
        percent: 10,
        state: TaskState::Running,
        stage: "starting-provider",
    });

    let mut child = Command::new(executable)
        .current_dir(working_directory)
        .args(fixed_args)
        .arg("--input")
        .arg(input)
        .arg("--output")
        .arg(output)
        .spawn()
        .map_err(|error| {
            RestoreError::new(
                RestoreErrorKind::ProviderUnavailable,
                format!("failed to start provider: {error}"),
            )
        })?;

    control.progress.report(ProgressUpdate {
        percent: 15,
        state: TaskState::Running,
        stage: "restoring",
    });

    loop {
        if control.cancellation.is_cancelled() {
            let _ = child.kill();
            let _ = child.wait();
            let _ = fs::remove_file(&request.output);
            return Err(RestoreError::new(
                RestoreErrorKind::Cancelled,
                "restore cancelled",
            ));
        }

        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(status)) => {
                let _ = fs::remove_file(&request.output);
                return Err(RestoreError::new(
                    RestoreErrorKind::ExecutionFailed,
                    format!("provider exited with status {status}"),
                ));
            }
            Ok(None) => thread::sleep(Duration::from_millis(50)),
            Err(error) => {
                return Err(RestoreError::new(
                    RestoreErrorKind::ExecutionFailed,
                    format!("failed while waiting for provider: {error}"),
                ));
            }
        }
    }

    let output_is_valid = request
        .output
        .metadata()
        .map(|metadata| metadata.is_file() && metadata.len() > 0)
        .unwrap_or(false);
    if !output_is_valid {
        return Err(RestoreError::new(
            RestoreErrorKind::OutputMissing,
            "provider completed without a non-empty output file",
        ));
    }

    control.progress.report(ProgressUpdate {
        percent: 95,
        state: TaskState::Running,
        stage: "output-validated",
    });
    Ok(RestoreResult {
        output: request.output.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{CancellationToken, ProgressUpdate, RestoreControl};
    use crate::runner::run_restore;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Arc, Mutex};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture(name: &str, script: &str) -> (PathBuf, PathBuf, PathBuf) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("mosaic-{name}-{}-{nonce}", std::process::id()));
        fs::create_dir_all(root.join(".venv/bin")).unwrap();
        let executable = root.join(".venv/bin/lada-cli");
        fs::write(&executable, script).unwrap();
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&executable, permissions).unwrap();
        let input = root.join("input.mp4");
        let output = root.join("output.mp4");
        fs::write(&input, b"video").unwrap();
        (root, input, output)
    }

    const ADAPTER_SCRIPT: &str = r#"#!/bin/sh
device= detector= restorer= backend= input= output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --detector) detector="$2"; shift 2 ;;
    --restorer) restorer="$2"; shift 2 ;;
    --backend) backend="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) shift 2 ;;
  esac
done
if [ -n "$device" ]; then [ "$device" = mps ] || exit 21; fi
if [ -n "$backend" ]; then
  [ "$detector" = lada-yolo-v4 ] || exit 22
  [ "$restorer" = basicvsrpp ] || exit 23
  [ "$backend" = tensorrt ] || exit 24
fi
cp "$input" "$output"
"#;

    #[test]
    fn local_lada_executes_mps_contract_and_reports_progress() {
        let (root, input, output) = fixture("lada", ADAPTER_SCRIPT);
        let provider = LocalLadaProvider::from_root(&root);
        let request = RestoreRequest {
            input,
            output: output.clone(),
            backend: ComputeBackend::AppleMps,
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

        assert_eq!(fs::read(output).unwrap(), b"video");
        assert!(
            updates
                .lock()
                .unwrap()
                .iter()
                .any(|update| update.percent == 100)
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn jasna_executes_standard_nvidia_contract() {
        let (root, input, output) = fixture("jasna", ADAPTER_SCRIPT);
        let runner = root.join("jasna-runner");
        fs::rename(root.join(".venv/bin/lada-cli"), &runner).unwrap();
        let provider = NvidiaJasnaProvider::new(runner);
        let request = RestoreRequest {
            input,
            output: output.clone(),
            backend: ComputeBackend::NvidiaCuda,
        };
        let cancellation = CancellationToken::new();
        let reporter = |_: ProgressUpdate| {};
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };

        run_restore(&provider, &request, &control).unwrap();

        assert_eq!(fs::read(output).unwrap(), b"video");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancellation_stops_external_provider() {
        let script = "#!/bin/sh\nsleep 5\nexit 0\n";
        let (root, input, output) = fixture("cancel", script);
        let provider = LocalLadaProvider::from_root(&root);
        let request = RestoreRequest {
            input,
            output,
            backend: ComputeBackend::AppleMps,
        };
        let cancellation = CancellationToken::new();
        let trigger = cancellation.clone();
        let reporter = |_: ProgressUpdate| {};
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        let cancel_thread = thread::spawn(move || {
            thread::sleep(Duration::from_millis(100));
            trigger.cancel();
        });

        let error = run_restore(&provider, &request, &control).unwrap_err();

        cancel_thread.join().unwrap();
        assert_eq!(error.kind, RestoreErrorKind::Cancelled);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn nonzero_exit_is_mapped() {
        let (root, input, output) = fixture("failure", "#!/bin/sh\nexit 7\n");
        let provider = LocalLadaProvider::from_root(&root);
        let request = RestoreRequest {
            input,
            output,
            backend: ComputeBackend::AppleMps,
        };
        let cancellation = CancellationToken::new();
        let reporter = |_: ProgressUpdate| {};
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        let error = run_restore(&provider, &request, &control).unwrap_err();
        assert_eq!(error.kind, RestoreErrorKind::ExecutionFailed);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_output_is_mapped() {
        let (root, input, output) = fixture("missing", "#!/bin/sh\nexit 0\n");
        let provider = LocalLadaProvider::from_root(&root);
        let request = RestoreRequest {
            input,
            output,
            backend: ComputeBackend::AppleMps,
        };
        let cancellation = CancellationToken::new();
        let reporter = |_: ProgressUpdate| {};
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &reporter,
        };
        let error = run_restore(&provider, &request, &control).unwrap_err();
        assert_eq!(error.kind, RestoreErrorKind::OutputMissing);
        fs::remove_dir_all(root).unwrap();
    }
}
