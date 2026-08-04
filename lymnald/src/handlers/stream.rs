//! The change stream endpoint `GET /v1/events` (§04).
//!
//! Emits `change` and `usage` events off the trove watcher's bus, each with a
//! monotonic id so a client can resume with Last-Event-ID, plus a `ping` every
//! 20 s to hold the line.

use std::convert::Infallible;
use std::time::Duration;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::IntoResponse;
use futures::stream::{self, Stream, StreamExt};
use tokio_stream::wrappers::{BroadcastStream, IntervalStream};

use crate::error::ApiError;
use crate::state::Shared;

use super::require_auth;

pub(super) async fn events(
    State(s): State<Shared>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    require_auth(&s, &headers)?;

    // Live events from the bus.
    let live = BroadcastStream::new(s.events.subscribe()).filter_map(|res| async move {
        let ev = res.ok()?;
        let data = serde_json::to_string(&ev.data).ok()?;
        Some(Ok::<Event, Infallible>(
            Event::default()
                .id(ev.id.to_string())
                .event(ev.event)
                .data(data),
        ))
    });

    // A ping every 20 s, independent of traffic.
    let mut interval = tokio::time::interval(Duration::from_secs(20));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let pings = IntervalStream::new(interval)
        .map(|_| Ok::<Event, Infallible>(Event::default().event("ping").data("")));

    let merged = stream::select(live, pings);
    Ok(Sse::new(merged).keep_alive(KeepAlive::new().interval(Duration::from_secs(20))))
}

/// (Kept for the type signature — the merged stream is `impl Stream`.)
#[allow(dead_code)]
fn _assert_stream<S: Stream>(_: &S) {}
