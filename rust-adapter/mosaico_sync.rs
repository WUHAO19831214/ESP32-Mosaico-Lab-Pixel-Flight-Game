//! Authoritative telemetry synchronization adapter for ESP-Mosaico -> mirui Pixel Flight.
//!
//! Allows the native Rust `mirui-pixel-flight` desktop app (SDL/WGPU) to lock onto the
//! authoritative flight state streamed by ESP-Mosaico without introducing extra crate dependencies.

use crate::flight::wrap_angle;
use crate::gameplay::FlightModelHandle;
use crate::presentation::palette::Daylight;
use mirui::types::Fixed;

/// Authoritative flight state parsed from ESP-Mosaico NDJSON v2 (`sync` payload).
#[derive(Clone, Copy, Debug)]
pub struct MosaicoSyncFrame {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub vx: f32,
    pub vy: f32,
    pub fyaw: f32,
    pub froll: f32,
    pub fpitch: f32,
    pub yaw_rate: f32,
    pub boost: f32,
    pub stunt: f32,
    pub stunt_dir: i8,
    pub view: u8,
    pub day: u8,
    pub wingmen: u8,
}

#[inline]
fn to_fixed(v: f32) -> Fixed {
    Fixed::from_ratio((v * 256.0) as i32, 256)
}

/// Apply an ESP-Mosaico authoritative snapshot onto a running `FlightModelHandle`
/// with short-horizon dead-reckoning interpolation.
pub fn apply_to_model(model: &FlightModelHandle, frame: &MosaicoSyncFrame, age_sec: f32) {
    let dt = age_sec.clamp(0.0, 0.2);
    model.update(|m| {
        let view = match frame.view % 3 {
            0 => crate::flight::View::Overhead,
            1 => crate::flight::View::Chase,
            _ => crate::flight::View::Cockpit,
        };
        m.flight.view = view;
        m.day = match frame.day % 3 {
            0 => Daylight::Day,
            1 => Daylight::Sunset,
            _ => Daylight::Night,
        };
        let want_wingmen = usize::from(frame.wingmen.min(2));
        if m.flight.count != 1 + want_wingmen {
            m.flight.set_wingmen(want_wingmen);
        }

        let tx = to_fixed(frame.x + frame.vx * dt);
        let ty = to_fixed(frame.y + frame.vy * dt);
        let tz = to_fixed(frame.z);
        let tyaw = to_fixed(frame.fyaw + frame.yaw_rate * dt);

        let j = &mut m.flight.jets[0];
        j.position = [tx, ty, tz];
        j.velocity = [to_fixed(frame.vx), to_fixed(frame.vy)];
        j.yaw = wrap_angle(tyaw);
        j.yaw_rate = to_fixed(frame.yaw_rate);
        j.roll = to_fixed(frame.froll);
        j.pitch = to_fixed(frame.fpitch);
        m.flight.boost = to_fixed(frame.boost.clamp(0.0, 1.0));
        if frame.stunt >= 0.0 {
            j.stunt = to_fixed(frame.stunt.clamp(0.0, 0.999));
            j.stunt_direction = if frame.stunt_dir >= 0 {
                Fixed::ONE
            } else {
                -Fixed::ONE
            };
        } else {
            j.stunt = -Fixed::ONE;
        }
        m.revision = m.revision.wrapping_add(1);
    });
}
