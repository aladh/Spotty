//! Runs blocking engine calls in submission order, outside either Tokio runtime.

use super::{Failure, Result};
use std::sync::mpsc;
use tokio::sync::oneshot;

type Job = Box<dyn FnOnce() + Send>;

#[derive(Clone)]
pub(super) struct PlaybackThread(mpsc::Sender<Job>);

impl PlaybackThread {
    pub(super) fn start() -> Result<Self> {
        let (send, receive) = mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name("Spotty playback commands".into())
            .spawn(move || {
                while let Ok(job) = receive.recv() {
                    job();
                }
            })
            .map_err(|_| Failure::Network)?;
        Ok(Self(send))
    }

    pub(super) async fn call<T, F>(&self, work: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce() -> T + Send + 'static,
    {
        self.submit(work)?.await.map_err(|_| Failure::Network)
    }

    pub(super) fn submit<T, F>(&self, work: F) -> Result<oneshot::Receiver<T>>
    where
        T: Send + 'static,
        F: FnOnce() -> T + Send + 'static,
    {
        let (reply, value) = oneshot::channel();
        self.0
            .send(Box::new(move || {
                let _ = reply.send(work());
            }))
            .map_err(|_| Failure::Network)?;
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_retirement_queued_behind_a_busy_engine_survives_a_dropped_reply() {
        let directory = tempfile::tempdir().unwrap();
        let grant = directory.path().join("session.json");
        std::fs::write(&grant, b"fixture").unwrap();

        let playback = PlaybackThread::start().unwrap();
        let (open, blocked) = mpsc::channel();
        let _occupied = playback.submit(move || blocked.recv().unwrap()).unwrap();
        let retired_grant = grant.clone();
        let retirement = playback
            .submit(move || std::fs::remove_file(retired_grant).unwrap())
            .unwrap();
        drop(retirement);
        let completed = playback.submit(move || !grant.exists()).unwrap();

        open.send(()).unwrap();
        assert!(completed.blocking_recv().unwrap());
    }
}
