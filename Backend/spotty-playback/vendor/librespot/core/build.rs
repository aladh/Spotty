use rand::Rng;
use rand_distr::Alphanumeric;
use vergen_gitcl::{BuildBuilder, Emitter};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // This path dependency lives inside Spotty's checkout, not librespot's Git tree.
    let mut upstream = include_str!("../UPSTREAM").lines();
    let revision = upstream.next().expect("retained upstream revision");
    let date = upstream.next().expect("retained upstream commit date");
    assert!(revision.len() == 40 && revision.bytes().all(|byte| byte.is_ascii_hexdigit()));
    println!("cargo:rustc-env=VERGEN_GIT_SHA={}", &revision[..8]);
    println!("cargo:rustc-env=VERGEN_GIT_COMMIT_DATE={date}");
    println!("cargo:rerun-if-changed=../UPSTREAM");

    let build = BuildBuilder::default()
        .build_date(true) // outputs 'VERGEN_BUILD_DATE'
        .build()?;

    Emitter::default()
        .add_instructions(&build)?
        .emit()
        .expect("Unable to generate the cargo keys!");
    let build_id = match std::env::var("SOURCE_DATE_EPOCH") {
        Ok(val) => val,
        Err(_) => rand::rng()
            .sample_iter(Alphanumeric)
            .take(8)
            .map(char::from)
            .collect(),
    };

    println!("cargo:rustc-env=LIBRESPOT_BUILD_ID={build_id}");
    Ok(())
}
