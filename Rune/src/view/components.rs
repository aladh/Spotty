use crate::State;
use rune::tok::TextStyle;
use rune::{Color, Cursor, El, Key, KeyEvent, Shape, SurfaceFit, Tx, canvas, el, row, text};
use rune_kit::glyphs;

pub fn mark(name: &str, size: f32, ink: &str) -> El {
    let ink = color(ink);
    if name == "search" {
        return rune::icon(&glyphs::SEARCH, size).color(ink).a11y_hidden();
    }
    let strokes: &[&[[f32; 2]]] = match name {
        "home" => &[&[
            [2., 9.],
            [9., 3.],
            [16., 9.],
            [16., 16.],
            [11., 16.],
            [11., 11.],
            [7., 11.],
            [7., 16.],
            [2., 16.],
            [2., 9.],
        ]],
        "library" => &[
            &[[3., 4.], [3., 15.]],
            &[[7., 4.], [7., 15.]],
            &[[11., 4.], [15., 15.]],
        ],
        "heart" => &[&[
            [9., 16.],
            [3., 10.],
            [2., 7.],
            [4., 4.],
            [7., 4.],
            [9., 6.],
            [11., 4.],
            [14., 4.],
            [16., 7.],
            [15., 10.],
            [9., 16.],
        ]],
        "pulse" => &[&[
            [1., 10.],
            [4., 10.],
            [6., 4.],
            [9., 15.],
            [12., 6.],
            [14., 10.],
            [17., 10.],
        ]],
        "back" => &[&[[11., 4.], [6., 9.], [11., 14.]]],
        "forward" => &[&[[7., 4.], [12., 9.], [7., 14.]]],
        "close" => &[&[[5., 5.], [13., 13.]], &[[13., 5.], [5., 13.]]],
        "queue" => &[
            &[[2., 5.], [16., 5.]],
            &[[2., 9.], [16., 9.]],
            &[[2., 13.], [11., 13.]],
        ],
        "device" => &[
            &[[2., 3.], [16., 3.], [16., 13.], [2., 13.], [2., 3.]],
            &[[6., 16.], [12., 16.]],
        ],
        "prev" => &[
            &[[3., 4.], [3., 14.]],
            &[[14., 4.], [6., 9.], [14., 14.], [14., 4.]],
        ],
        "next" => &[
            &[[15., 4.], [15., 14.]],
            &[[4., 4.], [12., 9.], [4., 14.], [4., 4.]],
        ],
        "shuffle" => &[
            &[[2., 5.], [5., 5.], [12., 13.], [16., 13.]],
            &[[13., 10.], [16., 13.], [13., 16.]],
            &[[2., 13.], [5., 13.], [12., 5.], [16., 5.]],
            &[[13., 2.], [16., 5.], [13., 8.]],
        ],
        "repeat" => &[
            &[[3., 9.], [3., 5.], [15., 5.]],
            &[[12., 2.], [15., 5.], [12., 8.]],
            &[[15., 9.], [15., 13.], [3., 13.]],
            &[[6., 10.], [3., 13.], [6., 16.]],
        ],
        "dots" => &[
            &[[3., 9.], [4., 9.]],
            &[[8.5, 9.], [9.5, 9.]],
            &[[14., 9.], [15., 9.]],
        ],
        "clock" => &[
            &[
                [9., 2.],
                [14., 4.],
                [16., 9.],
                [14., 14.],
                [9., 16.],
                [4., 14.],
                [2., 9.],
                [4., 4.],
                [9., 2.],
            ],
            &[[9., 5.], [9., 9.], [12., 9.]],
        ],
        "folder" => &[&[
            [2., 14.],
            [2., 5.],
            [7., 5.],
            [9., 7.],
            [16., 7.],
            [16., 14.],
            [2., 14.],
        ]],
        "down" => &[&[[4., 7.], [9., 12.], [14., 7.]]],
        "speaker" => &[
            &[
                [2., 7.],
                [5., 7.],
                [8., 4.],
                [8., 14.],
                [5., 11.],
                [2., 11.],
                [2., 7.],
            ],
            &[[11., 6.], [13., 9.], [11., 12.]],
            &[[14., 4.], [16., 9.], [14., 14.]],
        ],
        "note" => &[
            &[[8., 13.], [8., 4.], [15., 3.], [15., 11.]],
            &[[8., 13.], [5., 15.], [3., 14.], [4., 12.], [8., 12.]],
            &[[15., 11.], [12., 13.], [10., 12.], [11., 10.], [15., 10.]],
        ],
        _ => &[],
    };
    let mut shape = Shape::new().view_box(18.0, 18.0);
    for stroke in strokes {
        shape = shape.stroke(stroke.to_vec(), 1.35, ink);
    }
    match name {
        "play" => shape = shape.fill(vec![[6., 3.], [15., 9.], [6., 15.]], ink),
        "pause" => {
            shape = shape
                .fill(vec![[5., 3.], [8., 3.], [8., 15.], [5., 15.]], ink)
                .fill(vec![[11., 3.], [14., 3.], [14., 15.], [11., 15.]], ink);
        }
        _ => {}
    }
    canvas(shape).size(size, size).a11y_hidden()
}

pub const INK: &str = "#ffffff";
pub const MUTED: &str = "#b3b3b3";
pub const DATA: &str = "#a4a4a4";
pub const SOFT: &str = "#818181";
pub const BG: &str = "#121212";
pub const BLACK: &str = "#000000";
pub const TILE: &str = "#1f1f1f";
pub const LINE: &str = "#2b2b2b";
pub const ACCENT: &str = "#1ed760";

pub fn color(value: &str) -> Color {
    rune::color::hex(value).expect("palette color")
}

pub fn label(value: impl Into<String>, size: f32, weight: f32, ink: &str) -> El {
    text(value)
        .font(TextStyle::new(size, weight))
        .color(color(ink))
}

pub fn line() -> El {
    el().h(1.0).w_full().fill(color(LINE))
}

pub fn control(
    key: impl Into<String>,
    title: impl Into<String>,
    face: El,
    enabled: bool,
    action: impl Fn(&mut State, &mut Tx) + 'static,
) -> El {
    let button = face
        .key(key)
        .role("button")
        .label(title)
        .disabled(!enabled)
        .focusable(enabled)
        .focus_ring(2.0, 2.0, color(INK));
    if enabled {
        button
            .cursor(Cursor::Pointer)
            .hover(color("#ffffff").alpha(0.10))
            .on_press_tx(action)
    } else {
        button
    }
}

/// A selected row can hand focus to its adjacent action and receive it back.
pub fn focus_row_action(event: &KeyEvent, tx: &mut Tx, row: &str, action: &str) -> bool {
    if event.key != Key::Tab
        || event.mods.cmd
        || event.mods.ctrl
        || event.mods.alt
        || event.mods.logo
    {
        return false;
    }
    if !event.mods.shift && tx.focused() == Some(row) {
        tx.focus(action, true);
    } else if event.mods.shift && tx.focused() == Some(action) {
        tx.focus(row, true);
    } else {
        return false;
    }
    true
}

pub fn button(label_text: &str, primary: bool) -> El {
    row()
        .h(36.0)
        .px(15.0)
        .center()
        .gap(8.0)
        .radius(18.0)
        .fill(color(if primary { INK } else { TILE }))
        .child(label(
            label_text,
            13.0,
            650.0,
            if primary { BLACK } else { INK },
        ))
}

pub fn icon_button(name: &str, size: f32, symbol: f32, fill: &str, ink: &str) -> El {
    el().size(size, size)
        .center()
        .radius(size * 0.5)
        .fill(color(fill))
        .child(mark(name, symbol, ink))
}

pub fn picture(state: &State, artwork: Option<&str>, width: f32, height: f32, radius: f32) -> El {
    let base = el()
        .size(width, height)
        .center()
        .radius(radius)
        .clip_rounded(radius)
        .fill(color(TILE));
    picture_in(state, base, artwork, width.min(height))
}

pub fn picture_in(state: &State, base: El, artwork: Option<&str>, size: f32) -> El {
    if let Some(pixels) = artwork.and_then(|url| state.artwork.get(url)) {
        base.pixels_fit(pixels, SurfaceFit::Fill)
    } else {
        base.child(mark("note", size.min(54.0) * 0.60, SOFT))
    }
}

pub fn time(seconds: f64) -> String {
    let seconds = seconds.max(0.0) as u64;
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

pub fn duration(seconds: f64) -> String {
    let seconds = seconds.max(0.0) as u64;
    let (hours, minutes) = (seconds / 3600, seconds % 3600 / 60);
    if hours > 0 && minutes == 0 {
        format!("{hours} hr")
    } else if hours > 0 {
        format!("{hours} hr {minutes} min")
    } else if minutes > 0 {
        format!("{minutes} min {} sec", seconds % 60)
    } else {
        format!("{} sec", seconds % 60)
    }
}
