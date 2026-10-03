use crate::provider::{
    ProgressReporter, ProgressUpdate, RestorationProvider, RestoreControl, RestoreError,
    RestoreErrorKind, RestoreResult,
};
use crate::runner::run_restore;
use crate::{RestoreRequest, TaskState};
use std::collections::BTreeSet;
use std::collections::hash_map::DefaultHasher;
use std::fs::{self, File};
use std::hash::{Hash, Hasher};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::UNIX_EPOCH;

#[derive(Debug, Clone)]
pub struct ProductionOptions {
    pub chunk_seconds: f64,
    pub max_retries: u32,
    pub work_root: Option<PathBuf>,
    pub minimum_free_bytes: u64,
}

impl Default for ProductionOptions {
    fn default() -> Self {
        Self {
            chunk_seconds: 300.0,
            max_retries: 1,
            work_root: None,
            minimum_free_bytes: 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChunkPlan {
    pub index: usize,
    pub start_seconds: f64,
    pub duration_seconds: f64,
}

#[derive(Debug, Clone)]
struct Checkpoint {
    fingerprint: u64,
    duration_millis: u64,
    chunk_count: usize,
    completed: BTreeSet<usize>,
}

pub fn plan_chunks(
    duration_seconds: f64,
    chunk_seconds: f64,
) -> Result<Vec<ChunkPlan>, RestoreError> {
    if !duration_seconds.is_finite() || duration_seconds <= 0.0 {
        return Err(RestoreError::new(
            RestoreErrorKind::OutputInvalid,
            "input duration is invalid",
        ));
    }
    if !chunk_seconds.is_finite() || chunk_seconds <= 0.0 {
        return Err(RestoreError::new(
            RestoreErrorKind::InvalidRequest,
            "chunk duration must be positive",
        ));
    }
    let count = (duration_seconds / chunk_seconds).ceil() as usize;
    Ok((0..count)
        .map(|index| {
            let start = index as f64 * chunk_seconds;
            ChunkPlan {
                index,
                start_seconds: start,
                duration_seconds: (duration_seconds - start).min(chunk_seconds),
            }
        })
        .collect())
}

pub fn run_production_batch(
    provider: &dyn RestorationProvider,
    requests: &[RestoreRequest],
    options: &ProductionOptions,
    control: &RestoreControl<'_>,
) -> Result<Vec<RestoreResult>, RestoreError> {
    if requests.is_empty() {
        return Err(RestoreError::new(
            RestoreErrorKind::InvalidRequest,
            "batch is empty",
        ));
    }
    let mut results = Vec::with_capacity(requests.len());
    for (job_index, request) in requests.iter().enumerate() {
        if control.cancellation.is_cancelled() {
            return Err(RestoreError::new(
                RestoreErrorKind::Cancelled,
                "batch cancelled",
            ));
        }
        println!(
            "QUEUE {}/{} Running {}",
            job_index + 1,
            requests.len(),
            request.input.display()
        );
        let batch_reporter = BatchProgress {
            inner: control.progress,
            job_index,
            job_count: requests.len(),
        };
        let batch_control = RestoreControl {
            cancellation: control.cancellation,
            progress: &batch_reporter,
        };
        match run_production(provider, request, options, &batch_control) {
            Ok(result) => {
                println!(
                    "QUEUE {}/{} Succeeded {}",
                    job_index + 1,
                    requests.len(),
                    result.output.display()
                );
                results.push(result);
            }
            Err(error) => {
                let status = if error.kind == RestoreErrorKind::Cancelled {
                    "Cancelled"
                } else {
                    "Failed"
                };
                println!(
                    "QUEUE {}/{} {} {}",
                    job_index + 1,
                    requests.len(),
                    status,
                    error
                );
                return Err(error);
            }
        }
    }
    Ok(results)
}

pub fn run_production(
    provider: &dyn RestorationProvider,
    request: &RestoreRequest,
    options: &ProductionOptions,
    control: &RestoreControl<'_>,
) -> Result<RestoreResult, RestoreError> {
    request
        .validate()
        .map_err(|message| RestoreError::new(RestoreErrorKind::InvalidRequest, message))?;
    let duration = probe_duration(&request.input)?;
    let chunks = plan_chunks(duration, options.chunk_seconds)?;
    preflight_disk(request, chunks.len(), options.minimum_free_bytes)?;

    let fingerprint = fingerprint(request)?;
    let work_root = options.work_root.clone().unwrap_or_else(|| {
        request
            .output
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join(".mosaic-restore")
    });
    let task_root = work_root.join(format!("{fingerprint:016x}"));
    let source_root = task_root.join("source");
    let restored_root = task_root.join("restored");
    fs::create_dir_all(&source_root).map_err(io_error("create source workspace"))?;
    fs::create_dir_all(&restored_root).map_err(io_error("create restored workspace"))?;
    let checkpoint_path = task_root.join("checkpoint.txt");
    let mut checkpoint = load_checkpoint(&checkpoint_path).unwrap_or(Checkpoint {
        fingerprint,
        duration_millis: (duration * 1000.0).round() as u64,
        chunk_count: chunks.len(),
        completed: BTreeSet::new(),
    });
    if checkpoint.fingerprint != fingerprint || checkpoint.chunk_count != chunks.len() {
        return Err(RestoreError::new(
            RestoreErrorKind::InvalidRequest,
            "checkpoint does not match the current input",
        ));
    }
    checkpoint
        .completed
        .retain(|index| restored_root.join(chunk_name(*index)).is_file());
    save_checkpoint(&checkpoint_path, &checkpoint)?;

    for chunk in &chunks {
        if control.cancellation.is_cancelled() {
            return Err(RestoreError::new(
                RestoreErrorKind::Cancelled,
                "restore cancelled; checkpoint preserved",
            ));
        }
        if checkpoint.completed.contains(&chunk.index) {
            report_chunk_progress(
                control.progress,
                chunk.index + 1,
                chunks.len(),
                "checkpoint-resumed",
            );
            continue;
        }
        let source = source_root.join(chunk_name(chunk.index));
        let restored = restored_root.join(chunk_name(chunk.index));
        if !source.is_file() {
            split_chunk(&request.input, &source, chunk)?;
        }
        let chunk_request = RestoreRequest {
            input: source,
            output: restored.clone(),
            backend: request.backend,
        };
        // A crash may leave an uncheckpointed partial provider output. Never trust or reuse it.
        let _ = fs::remove_file(&restored);
        let chunk_reporter = ChunkProgress {
            inner: control.progress,
            completed: chunk.index,
            total: chunks.len(),
        };
        let chunk_control = RestoreControl {
            cancellation: control.cancellation,
            progress: &chunk_reporter,
        };
        let mut last_error = None;
        for attempt in 0..=options.max_retries {
            match run_restore(provider, &chunk_request, &chunk_control) {
                Ok(_) => {
                    last_error = None;
                    break;
                }
                Err(error)
                    if error.kind != RestoreErrorKind::Cancelled
                        && attempt < options.max_retries =>
                {
                    let _ = fs::remove_file(&restored);
                    println!("RETRY chunk={} attempt={}", chunk.index + 1, attempt + 2);
                    last_error = Some(error);
                }
                Err(error) => return Err(error),
            }
        }
        if let Some(error) = last_error {
            return Err(error);
        }
        checkpoint.completed.insert(chunk.index);
        save_checkpoint(&checkpoint_path, &checkpoint)?;
        report_chunk_progress(
            control.progress,
            chunk.index + 1,
            chunks.len(),
            "chunk-completed",
        );
    }

    let output_name = request
        .output
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("output.mp4");
    let staging = request
        .output
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(format!(".{output_name}.mosaic-finalizing.mp4"));
    let _ = fs::remove_file(&staging);
    concatenate_chunks(&restored_root, chunks.len(), &staging)?;
    validate_output(&staging, duration)?;
    fs::rename(&staging, &request.output).map_err(io_error("move validated output into place"))?;
    fs::remove_dir_all(&task_root).map_err(io_error("clean completed task workspace"))?;
    if work_root
        .read_dir()
        .map(|mut entries| entries.next().is_none())
        .unwrap_or(false)
    {
        let _ = fs::remove_dir(&work_root);
    }
    control.progress.report(ProgressUpdate {
        percent: 100,
        state: TaskState::Succeeded,
        stage: "completed",
    });
    Ok(RestoreResult {
        output: request.output.clone(),
    })
}

struct ChunkProgress<'a> {
    inner: &'a dyn ProgressReporter,
    completed: usize,
    total: usize,
}
impl ProgressReporter for ChunkProgress<'_> {
    fn report(&self, update: ProgressUpdate) {
        let within = update.percent as f64 / 100.0;
        let aggregate = ((self.completed as f64 + within) / self.total as f64 * 94.0).round() as u8;
        let state = match update.state {
            TaskState::Pending | TaskState::Succeeded => TaskState::Running,
            state => state,
        };
        let stage = if update.stage == "completed" {
            "chunk-completed"
        } else {
            update.stage
        };
        self.inner.report(ProgressUpdate {
            percent: aggregate.min(94),
            state,
            stage,
        });
    }
}

struct BatchProgress<'a> {
    inner: &'a dyn ProgressReporter,
    job_index: usize,
    job_count: usize,
}
impl ProgressReporter for BatchProgress<'_> {
    fn report(&self, update: ProgressUpdate) {
        let aggregate = ((self.job_index as f64 + update.percent as f64 / 100.0)
            / self.job_count as f64
            * 100.0)
            .round() as u8;
        self.inner.report(ProgressUpdate {
            percent: aggregate,
            state: update.state,
            stage: update.stage,
        });
    }
}

fn report_chunk_progress(
    reporter: &dyn ProgressReporter,
    completed: usize,
    total: usize,
    stage: &'static str,
) {
    reporter.report(ProgressUpdate {
        percent: ((completed as f64 / total as f64) * 94.0).round() as u8,
        state: TaskState::Running,
        stage,
    });
}

fn split_chunk(input: &Path, output: &Path, chunk: &ChunkPlan) -> Result<(), RestoreError> {
    let status = Command::new("ffmpeg")
        .args(["-v", "error", "-y", "-ss"])
        .arg(format!("{:.3}", chunk.start_seconds))
        .arg("-i")
        .arg(input)
        .arg("-t")
        .arg(format!("{:.3}", chunk.duration_seconds))
        .args([
            "-map",
            "0:v:0",
            "-map",
            "0:a?",
            "-c:v",
            "libx264",
            "-preset",
            "faster",
            "-crf",
            "15",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-movflags",
            "+faststart",
        ])
        .arg(output)
        .status()
        .map_err(|error| {
            RestoreError::new(
                RestoreErrorKind::ExecutionFailed,
                format!("failed to start ffmpeg splitter: {error}"),
            )
        })?;
    if !status.success() || !output.is_file() {
        return Err(RestoreError::new(
            RestoreErrorKind::ExecutionFailed,
            "ffmpeg failed to create a source chunk",
        ));
    }
    Ok(())
}

fn concatenate_chunks(
    restored_root: &Path,
    count: usize,
    output: &Path,
) -> Result<(), RestoreError> {
    let list_path = output.with_extension("concat.txt");
    let mut list = File::create(&list_path).map_err(io_error("create concat list"))?;
    for index in 0..count {
        let escaped = restored_root
            .join(chunk_name(index))
            .to_string_lossy()
            .replace('\'', "'\\''");
        writeln!(list, "file '{escaped}'").map_err(io_error("write concat list"))?;
    }
    let status = Command::new("ffmpeg")
        .args(["-v", "error", "-y", "-f", "concat", "-safe", "0", "-i"])
        .arg(&list_path)
        .args(["-c", "copy"])
        .arg(output)
        .status()
        .map_err(|error| {
            RestoreError::new(
                RestoreErrorKind::ExecutionFailed,
                format!("failed to start ffmpeg concat: {error}"),
            )
        })?;
    let _ = fs::remove_file(list_path);
    if !status.success() || !output.is_file() {
        return Err(RestoreError::new(
            RestoreErrorKind::ExecutionFailed,
            "ffmpeg failed to assemble final output",
        ));
    }
    Ok(())
}

fn probe_duration(path: &Path) -> Result<f64, RestoreError> {
    let output = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(path)
        .output()
        .map_err(|error| {
            RestoreError::new(
                RestoreErrorKind::ExecutionFailed,
                format!("failed to start ffprobe: {error}"),
            )
        })?;
    if !output.status.success() {
        return Err(RestoreError::new(
            RestoreErrorKind::OutputInvalid,
            "ffprobe could not read video",
        ));
    }
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<f64>()
        .map_err(|_| {
            RestoreError::new(
                RestoreErrorKind::OutputInvalid,
                "ffprobe returned an invalid duration",
            )
        })
}

fn validate_output(output: &Path, expected_duration: f64) -> Result<(), RestoreError> {
    let actual = probe_duration(output)?;
    let tolerance = (expected_duration * 0.05).max(1.0);
    if (actual - expected_duration).abs() > tolerance {
        let _ = fs::remove_file(output);
        return Err(RestoreError::new(
            RestoreErrorKind::OutputInvalid,
            format!("output duration mismatch: expected {expected_duration:.3}s, got {actual:.3}s"),
        ));
    }
    Ok(())
}

fn preflight_disk(
    request: &RestoreRequest,
    chunk_count: usize,
    minimum_free_bytes: u64,
) -> Result<(), RestoreError> {
    let available = available_bytes(request.output.parent().unwrap_or_else(|| Path::new(".")))?;
    let input_size = request
        .input
        .metadata()
        .map_err(io_error("read input metadata"))?
        .len();
    let estimate = input_size
        .saturating_mul(4)
        .saturating_add(chunk_count as u64 * 1_048_576);
    let required = estimate.max(minimum_free_bytes);
    if available < required {
        return Err(RestoreError::new(
            RestoreErrorKind::InsufficientDiskSpace,
            format!("insufficient disk space: need {required} bytes, have {available} bytes"),
        ));
    }
    Ok(())
}

fn available_bytes(path: &Path) -> Result<u64, RestoreError> {
    let output = Command::new("df")
        .args(["-Pk"])
        .arg(path)
        .output()
        .map_err(|error| {
            RestoreError::new(
                RestoreErrorKind::ExecutionFailed,
                format!("failed to check disk space: {error}"),
            )
        })?;
    if !output.status.success() {
        return Err(RestoreError::new(
            RestoreErrorKind::ExecutionFailed,
            "disk space check failed",
        ));
    }
    let line = String::from_utf8_lossy(&output.stdout)
        .lines()
        .last()
        .unwrap_or("")
        .to_string();
    let blocks = line
        .split_whitespace()
        .nth(3)
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(|| {
            RestoreError::new(
                RestoreErrorKind::ExecutionFailed,
                "could not parse available disk space",
            )
        })?;
    Ok(blocks.saturating_mul(1024))
}

fn fingerprint(request: &RestoreRequest) -> Result<u64, RestoreError> {
    let metadata = request
        .input
        .metadata()
        .map_err(io_error("read input metadata"))?;
    let mut hasher = DefaultHasher::new();
    request
        .input
        .canonicalize()
        .unwrap_or_else(|_| request.input.clone())
        .hash(&mut hasher);
    request.output.hash(&mut hasher);
    metadata.len().hash(&mut hasher);
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_nanos())
        .hash(&mut hasher);
    Ok(hasher.finish())
}

fn chunk_name(index: usize) -> String {
    format!("chunk-{index:06}.mp4")
}

fn save_checkpoint(path: &Path, checkpoint: &Checkpoint) -> Result<(), RestoreError> {
    let temporary = path.with_extension("tmp");
    let completed = checkpoint
        .completed
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let contents = format!(
        "version=1\nfingerprint={}\nduration_millis={}\nchunk_count={}\ncompleted={}\n",
        checkpoint.fingerprint, checkpoint.duration_millis, checkpoint.chunk_count, completed
    );
    fs::write(&temporary, contents).map_err(io_error("write checkpoint"))?;
    fs::rename(temporary, path).map_err(io_error("commit checkpoint"))
}

fn load_checkpoint(path: &Path) -> Option<Checkpoint> {
    let contents = fs::read_to_string(path).ok()?;
    let value = |key: &str| {
        contents
            .lines()
            .find_map(|line| line.strip_prefix(&format!("{key}=")))
    };
    if value("version")? != "1" {
        return None;
    }
    Some(Checkpoint {
        fingerprint: value("fingerprint")?.parse().ok()?,
        duration_millis: value("duration_millis")?.parse().ok()?,
        chunk_count: value("chunk_count")?.parse().ok()?,
        completed: value("completed")
            .unwrap_or("")
            .split(',')
            .filter_map(|item| item.parse().ok())
            .collect(),
    })
}

fn io_error(context: &'static str) -> impl FnOnce(std::io::Error) -> RestoreError {
    move |error| {
        RestoreError::new(
            RestoreErrorKind::ExecutionFailed,
            format!("{context}: {error}"),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans_complete_non_overlapping_chunks() {
        let plan = plan_chunks(125.0, 60.0).unwrap();
        assert_eq!(plan.len(), 3);
        assert_eq!(
            plan[0],
            ChunkPlan {
                index: 0,
                start_seconds: 0.0,
                duration_seconds: 60.0
            }
        );
        assert_eq!(
            plan[2],
            ChunkPlan {
                index: 2,
                start_seconds: 120.0,
                duration_seconds: 5.0
            }
        );
    }

    #[test]
    fn checkpoint_round_trip_is_atomic_and_complete() {
        let root = std::env::temp_dir().join(format!("mosaic-checkpoint-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("checkpoint.txt");
        let checkpoint = Checkpoint {
            fingerprint: 7,
            duration_millis: 125_000,
            chunk_count: 3,
            completed: [0, 2].into(),
        };
        save_checkpoint(&path, &checkpoint).unwrap();
        let loaded = load_checkpoint(&path).unwrap();
        assert_eq!(loaded.fingerprint, 7);
        assert_eq!(loaded.completed, checkpoint.completed);
        assert!(!path.with_extension("tmp").exists());
        fs::remove_dir_all(root).unwrap();
    }
}
