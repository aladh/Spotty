use crate::*;
use librespot_connect::{LoadContextOptions, Options};

/// A load must choose its ordering policy and capture modes before activation can publish
/// empty-player defaults. Both explicit selections and recovery use this same boundary.
pub(crate) struct SelectionLoadPolicy {
    modes: Options,
    order: SelectionOrder,
}

#[derive(Clone, Copy)]
pub(crate) enum SelectionOrder {
    Context,
    Supplied,
}

impl SelectionLoadPolicy {
    pub(crate) fn capture(order: SelectionOrder) -> Self {
        let (shuffle, repeat_track, repeat) = current_playback_options();
        Self {
            modes: Options {
                shuffle,
                repeat,
                repeat_track,
            },
            order,
        }
    }

    pub(crate) fn options(
        self,
        seek_to: u32,
        playing_track: Option<PlayingTrack>,
    ) -> LoadRequestOptions {
        LoadRequestOptions {
            start_playing: true,
            seek_to,
            playing_track,
            context_options: Some(LoadContextOptions::Options(self.modes)),
            preserve_track_order: matches!(self.order, SelectionOrder::Supplied),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_and_recovery_capture_modes_and_order_before_activation() {
        let _guard = lock_lifecycle_test_globals();
        let original = current_playback_options();
        for shuffle in [false, true] {
            for repeat_track in [false, true] {
                for repeat in [false, true] {
                    for order in [SelectionOrder::Context, SelectionOrder::Supplied] {
                        for position in [0, 152_000] {
                            update_playback_options(shuffle, repeat_track, repeat);
                            let policy = SelectionLoadPolicy::capture(order);
                            update_playback_options(false, false, false);
                            let selected = policy.options(position, None);
                            let Some(LoadContextOptions::Options(options)) =
                                selected.context_options
                            else {
                                panic!("every selection must specify retained modes");
                            };
                            assert_eq!(
                                (options.shuffle, options.repeat_track, options.repeat),
                                (shuffle, repeat_track, repeat)
                            );
                            assert!(selected.start_playing);
                            assert_eq!(selected.seek_to, position);
                            assert_eq!(
                                selected.preserve_track_order,
                                matches!(order, SelectionOrder::Supplied)
                            );
                        }
                    }
                }
            }
        }
        update_playback_options(original.0, original.1, original.2);
    }
}
