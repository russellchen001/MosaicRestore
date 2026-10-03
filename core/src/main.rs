use mosaic_core::adapters::{LocalLadaProvider, NvidiaJasnaProvider};
use mosaic_core::cloud::CloudNvidiaProvider;
use mosaic_core::provider::{CancellationToken, RestorationProvider, RestoreControl};
use mosaic_core::runner::run_restore;
use mosaic_core::workflow::{ProductionOptions, run_production_batch};
use mosaic_core::{ComputeBackend, RestoreRequest};
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

struct Options {
    provider: String,
    inputs: Vec<PathBuf>,
    outputs: Vec<PathBuf>,
    provider_root: Option<PathBuf>,
    runner: Option<PathBuf>,
    cloud_config: Option<PathBuf>,
    cancel_file: Option<PathBuf>,
    production: bool,
    chunk_seconds: f64,
    max_retries: u32,
    work_root: Option<PathBuf>,
    minimum_free_bytes: u64,
}

fn main() {
    let options = match parse_options() {
        Ok(options) => options,
        Err(message) => {
            eprintln!("FAIL restore — {message}");
            print_usage();
            std::process::exit(2);
        }
    };

    let cancellation = CancellationToken::new();
    if let Some(cancel_file) = options.cancel_file.clone() {
        let watcher = cancellation.clone();
        thread::spawn(move || {
            loop {
                if cancel_file.exists() {
                    watcher.cancel();
                    break;
                }
                thread::sleep(Duration::from_millis(100));
            }
        });
    }

    let (provider, backend): (Box<dyn RestorationProvider>, ComputeBackend) = match options
        .provider
        .as_str()
    {
        "local-lada" => {
            let root = options.provider_root.unwrap_or_else(default_lada_root);
            (
                Box::new(LocalLadaProvider::from_root(root)),
                ComputeBackend::AppleMps,
            )
        }
        "nvidia-jasna" => {
            let runner = options
                .runner
                .or_else(|| std::env::var_os("MOSAIC_JASNA_RUNNER").map(PathBuf::from));
            let Some(runner) = runner else {
                eprintln!("FAIL restore — nvidia-jasna requires --runner or MOSAIC_JASNA_RUNNER");
                std::process::exit(2);
            };
            (
                Box::new(NvidiaJasnaProvider::new(runner)),
                ComputeBackend::NvidiaCuda,
            )
        }
        "cloud-nvidia" => {
            let config = options
                .cloud_config
                .or_else(|| std::env::var_os("MOSAIC_CLOUD_CONFIG").map(PathBuf::from));
            let Some(config) = config else {
                eprintln!(
                    "FAIL restore — cloud-nvidia requires --cloud-config or MOSAIC_CLOUD_CONFIG"
                );
                std::process::exit(2);
            };
            let provider = match CloudNvidiaProvider::from_config(config) {
                Ok(provider) => provider,
                Err(error) => {
                    eprintln!("FAIL restore — {:?}: {}", error.kind, error);
                    std::process::exit(2);
                }
            };
            (Box::new(provider), ComputeBackend::NvidiaCuda)
        }
        value => {
            eprintln!("FAIL restore — unknown provider: {value}");
            std::process::exit(2);
        }
    };

    let requests = options
        .inputs
        .into_iter()
        .zip(options.outputs)
        .map(|(input, output)| RestoreRequest {
            input,
            output,
            backend,
        })
        .collect::<Vec<_>>();
    let reporter = |update: mosaic_core::provider::ProgressUpdate| {
        println!("{}% {:?} {}", update.percent, update.state, update.stage);
    };
    let control = RestoreControl {
        cancellation: &cancellation,
        progress: &reporter,
    };

    let result = if options.production || requests.len() > 1 {
        run_production_batch(
            provider.as_ref(),
            &requests,
            &ProductionOptions {
                chunk_seconds: options.chunk_seconds,
                max_retries: options.max_retries,
                work_root: options.work_root,
                minimum_free_bytes: options.minimum_free_bytes,
            },
            &control,
        )
        .map(|results| results.last().cloned().expect("non-empty batch"))
    } else {
        run_restore(provider.as_ref(), &requests[0], &control)
    };

    match result {
        Ok(result) => println!("PASS restore — {}", result.output.display()),
        Err(error) => {
            eprintln!("FAIL restore — {:?}: {}", error.kind, error);
            std::process::exit(1);
        }
    }
}

fn parse_options() -> Result<Options, String> {
    let mut provider = None;
    let mut inputs = Vec::new();
    let mut outputs = Vec::new();
    let mut provider_root = None;
    let mut runner = None;
    let mut cloud_config = None;
    let mut cancel_file = None;
    let mut production = false;
    let mut chunk_seconds = 300.0;
    let mut max_retries = 1;
    let mut work_root = None;
    let mut minimum_free_bytes = 0;
    let mut arguments = std::env::args().skip(1);

    while let Some(argument) = arguments.next() {
        if argument == "--production" {
            production = true;
            continue;
        }
        if argument == "--help" || argument == "-h" {
            print_usage();
            std::process::exit(0);
        }
        let value = arguments
            .next()
            .ok_or_else(|| format!("missing value for {argument}"))?;
        match argument.as_str() {
            "--provider" => provider = Some(value),
            "--input" => inputs.push(PathBuf::from(value)),
            "--output" => outputs.push(PathBuf::from(value)),
            "--provider-root" => provider_root = Some(PathBuf::from(value)),
            "--runner" => runner = Some(PathBuf::from(value)),
            "--cloud-config" => cloud_config = Some(PathBuf::from(value)),
            "--cancel-file" => cancel_file = Some(PathBuf::from(value)),
            "--chunk-seconds" => {
                chunk_seconds = value
                    .parse()
                    .map_err(|_| "--chunk-seconds must be a number".to_string())?
            }
            "--max-retries" => {
                max_retries = value
                    .parse()
                    .map_err(|_| "--max-retries must be an integer".to_string())?
            }
            "--work-root" => work_root = Some(PathBuf::from(value)),
            "--minimum-free-bytes" => {
                minimum_free_bytes = value
                    .parse()
                    .map_err(|_| "--minimum-free-bytes must be an integer".to_string())?
            }
            _ => return Err(format!("unknown argument: {argument}")),
        }
    }
    if inputs.is_empty() {
        return Err("--input is required".to_string());
    }
    if inputs.len() != outputs.len() {
        return Err("each --input requires one --output".to_string());
    }
    Ok(Options {
        provider: provider.ok_or_else(|| "--provider is required".to_string())?,
        inputs,
        outputs,
        provider_root,
        runner,
        cloud_config,
        cancel_file,
        production,
        chunk_seconds,
        max_retries,
        work_root,
        minimum_free_bytes,
    })
}

fn default_lada_root() -> PathBuf {
    if let Some(root) = std::env::var_os("MOSAIC_LADA_ROOT") {
        return PathBuf::from(root);
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("MosaicRestore/benchmark/lada-upstream")
}

fn print_usage() {
    eprintln!(
        "Usage: mosaic-core --provider local-lada|nvidia-jasna|cloud-nvidia --input VIDEO --output VIDEO [--input VIDEO --output VIDEO ...] [--production] [--chunk-seconds N] [--max-retries N] [--work-root DIR] [--minimum-free-bytes N] [--provider-root DIR] [--runner PATH] [--cloud-config PATH] [--cancel-file PATH]"
    );
}
