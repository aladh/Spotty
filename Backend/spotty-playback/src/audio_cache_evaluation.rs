//! Disposable cache-layer experiments. No Session, credentials, audio decoder or network.
//! Counterexamples describe an enabled candidate; production audio caching stays disabled.
use crate::Cache;
use librespot_core::FileId;
use std::fs;
use std::io::{self, Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "spotty-audio-cache-{}-{nonce}-{sequence}",
            std::process::id()
        ));
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&path).unwrap();
        Self(path)
    }

    fn partition(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn candidate(path: &Path, limit: u64) -> Cache {
    Cache::new(None::<&Path>, None, Some(path), Some(limit)).unwrap()
}

fn file_id(value: u8) -> FileId {
    FileId::from_raw(&[value; 20])
}

fn retained_bytes(path: &Path) -> u64 {
    if !path.exists() {
        return 0;
    }
    fs::read_dir(path)
        .unwrap()
        .map(|entry| {
            let entry = entry.unwrap();
            let kind = entry.file_type().unwrap();
            // The receipt never traverses fixture symlinks; only Cache's own scan may do so.
            if kind.is_dir() {
                retained_bytes(&entry.path())
            } else if kind.is_file() {
                entry.metadata().unwrap().len()
            } else {
                0
            }
        })
        .sum()
}

fn read(cache: &Cache, id: FileId) -> Option<Vec<u8>> {
    let mut file = cache.file(id)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).unwrap();
    Some(bytes)
}

#[test]
fn disabled_audio_cache_retains_nothing_while_candidate_reuses_synthetic_bytes() {
    let fixture = Fixture::new();
    let disabled = Cache::new(None::<&Path>, None, None, None).unwrap();
    let id = file_id(1);
    let bytes = vec![7; 65_536];
    assert!(disabled.file_path(id).is_none());
    assert!(disabled.file(id).is_none());
    assert!(disabled.save_file(id, &mut Cursor::new(&bytes)).is_err());
    assert_eq!(retained_bytes(&fixture.0), 0);

    let partition = fixture.partition("synthetic-account-a");
    let enabled = candidate(&partition, 131_072);
    assert!(read(&enabled, id).is_none());
    enabled.save_file(id, &mut Cursor::new(&bytes)).unwrap();
    assert_eq!(read(&enabled, id), Some(bytes.clone()));
    assert_eq!(read(&enabled, id), Some(bytes));
    assert_eq!(retained_bytes(&partition), 65_536);
}

#[test]
fn completed_candidate_saves_and_restart_enforce_the_trial_quota() {
    let fixture = Fixture::new();
    let partition = fixture.partition("synthetic-account-a");
    let enabled = candidate(&partition, 24);
    for id in [file_id(1), file_id(2)] {
        enabled.save_file(id, &mut Cursor::new([1; 16])).unwrap();
        assert!(retained_bytes(&partition) <= 24);
    }
    assert_eq!(retained_bytes(&partition), 16);
    drop(enabled);
    let restarted = candidate(&partition, 8);
    assert_eq!(retained_bytes(&partition), 0);
    // An oversized completed save may succeed after evicting its own file.
    restarted
        .save_file(file_id(3), &mut Cursor::new([1; 16]))
        .unwrap();
    assert!(read(&restarted, file_id(3)).is_none());
    assert_eq!(retained_bytes(&partition), 0);
}

struct FailedCopy(Option<Vec<u8>>);

impl Read for FailedCopy {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if let Some(bytes) = self.0.take() {
            assert!(output.len() >= bytes.len());
            output[..bytes.len()].copy_from_slice(&bytes);
            Ok(bytes.len())
        } else {
            Err(io::Error::other("synthetic copy failure"))
        }
    }
}

#[test]
fn failed_candidate_copy_leaves_readable_unaccounted_bytes_until_restart() {
    let fixture = Fixture::new();
    let partition = fixture.partition("synthetic-account-a");
    let enabled = candidate(&partition, 8);
    let id = file_id(1);
    let prefix = vec![1; 16];
    assert!(enabled
        .save_file(id, &mut FailedCopy(Some(prefix.clone())))
        .is_err());
    assert_eq!(read(&enabled, id), Some(prefix));
    assert_eq!(
        retained_bytes(&partition),
        16,
        "failed copy exceeds the trial quota"
    );
    enabled.remove_file(id).unwrap();
    assert!(
        read(&enabled, id).is_none(),
        "cache removal primitive is available to the decoder"
    );
    assert!(enabled
        .save_file(id, &mut FailedCopy(Some(vec![2; 16])))
        .is_err());
    drop(enabled);
    let _restarted = candidate(&partition, 8);
    assert_eq!(retained_bytes(&partition), 0);
}

#[test]
fn delayed_candidate_clone_recreates_a_retired_partition_without_touching_replacement() {
    let fixture = Fixture::new();
    let first_path = fixture.partition("synthetic-account-a");
    let second_path = fixture.partition("synthetic-account-b");
    let first = candidate(&first_path, 128);
    let replacement = candidate(&second_path, 128);
    let id = file_id(1);
    replacement
        .save_file(id, &mut Cursor::new([2; 16]))
        .unwrap();
    let delayed = first.clone();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let writer = std::thread::spawn(move || {
        ready_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        delayed.save_file(id, &mut Cursor::new([1; 16])).unwrap()
    });
    ready_rx.recv().unwrap();
    fs::remove_dir_all(&first_path).unwrap();
    assert!(!first_path.exists());
    release_tx.send(()).unwrap();
    let recreated = writer.join().unwrap();
    assert!(recreated.starts_with(&first_path));
    assert_eq!(fs::read(recreated).unwrap(), vec![1; 16]);
    assert_eq!(read(&replacement, id), Some(vec![2; 16]));
    assert_eq!(
        retained_bytes(&first_path),
        16,
        "raw Cache has no retirement fence"
    );
}

#[test]
fn failed_candidate_eviction_can_lose_accounting_before_storage_is_removed() {
    let fixture = Fixture::new();
    let partition = fixture.partition("synthetic-account-a");
    let enabled = candidate(&partition, 8);
    let first = enabled
        .save_file(file_id(1), &mut Cursor::new([1; 8]))
        .unwrap();
    fs::remove_file(&first).unwrap();
    fs::create_dir(&first).unwrap();
    fs::write(first.join("synthetic-obstruction"), [1; 8]).unwrap();
    // remove_file refuses the replaced directory; the limiter has already popped its entry.
    assert!(enabled
        .save_file(file_id(2), &mut Cursor::new([2; 16]))
        .is_err());
    enabled
        .save_file(file_id(3), &mut Cursor::new([3; 8]))
        .unwrap();
    assert_eq!(
        retained_bytes(&partition),
        16,
        "later saves do not account for failed removal"
    );
}

#[cfg(unix)]
#[test]
fn candidate_restart_follows_a_directory_symlink_and_prunes_its_owned_fixture_target() {
    let fixture = Fixture::new();
    let partition = fixture.partition("synthetic-account-a");
    let outside = fixture.partition("owned-synthetic-target");
    fs::create_dir(&partition).unwrap();
    fs::create_dir(&outside).unwrap();
    let marker = outside.join("synthetic-bytes");
    fs::write(&marker, [1; 16]).unwrap();
    std::os::unix::fs::symlink(&outside, partition.join("synthetic-link")).unwrap();
    let _enabled = candidate(&partition, 0);
    assert!(
        !marker.exists(),
        "Cache startup scan follows a directory link outside its partition"
    );
}

#[test]
#[ignore = "descriptive filesystem timing; run explicitly in an isolated process"]
fn record_synthetic_cold_and_warm_cache_io() {
    let report = PathBuf::from(std::env::var("SPOTTY_AUDIO_CACHE_REPORT").unwrap());
    assert!(report.is_absolute() && !report.exists());
    let mut waves = Vec::new();
    for _ in 0..5 {
        let fixture = Fixture::new();
        let partition = fixture.partition("synthetic-account-a");
        let enabled = candidate(&partition, 131_072);
        let id = file_id(1);
        let bytes = vec![7; 65_536];
        let disabled = Cache::new(None::<&Path>, None, None, None).unwrap();
        let mut baseline_bytes = 0;
        let mut baseline_ms = Vec::new();
        for _ in 0..3 {
            assert!(read(&disabled, id).is_none());
            let started = Instant::now();
            let mut supplied = Vec::new();
            Cursor::new(&bytes).read_to_end(&mut supplied).unwrap();
            baseline_bytes += supplied.len();
            assert_eq!(supplied, bytes);
            baseline_ms.push(started.elapsed().as_secs_f64() * 1_000.0);
        }
        assert!(read(&enabled, id).is_none());
        let started = Instant::now();
        let mut source = Cursor::new(&bytes);
        enabled.save_file(id, &mut source).unwrap();
        let cold_ms = started.elapsed().as_secs_f64() * 1_000.0;
        let mut warm_ms = Vec::new();
        for _ in 0..2 {
            let started = Instant::now();
            assert_eq!(read(&enabled, id), Some(bytes.clone()));
            warm_ms.push(started.elapsed().as_secs_f64() * 1_000.0);
        }
        waves.push(serde_json::json!({
            "syntheticInputBytesWithoutRetention": baseline_bytes,
            "syntheticInputBytesWithRetention": source.position(),
            "baselineMemoryReadMilliseconds": baseline_ms,
            "cacheBytesWritten": 65_536,
            "cacheBytesReadWarm": 131_072,
            "retainedBytes": retained_bytes(&partition),
            "coldSaveMilliseconds": cold_ms,
            "warmReadMilliseconds": warm_ms,
        }));
    }
    let result = serde_json::json!({
        "sourceRevision": std::env::var("SPOTTY_AUDIO_CACHE_SOURCE_REVISION").unwrap(),
        "trialQuotaBytes": 131_072,
        "syntheticPayloadBytes": 65_536,
        "waves": waves,
        "limitations": "Synthetic memory-sourced bytes and filesystem operations only; OS page cache may be warm. No Session, encrypted Spotify payload, key request, network transfer, decoding, playback/startup latency or live benefit measurement. Disabled baseline byte count is three fixture reads, not observed network traffic.",
    });
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(report)
        .unwrap();
    use std::io::Write;
    serde_json::to_writer_pretty(&mut file, &result).unwrap();
    file.write_all(b"\n").unwrap();
}
