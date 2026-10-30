//! `tt-demo setup`: put the "look" defaults in place on this machine.
//!
//! What it does itself: installs the JetBrainsMono Nerd Font into the user's font
//! directory (no root). What it only reports: system packages (alacritty,
//! ncurses-term), because installing those needs sudo and a surprise `apt install`
//! from a demo tool is not welcome. For each missing package it prints the exact
//! command for the detected package manager.
use crate::look;
use crate::record::home;
use anyhow::{bail, Context};
use std::path::{Path, PathBuf};
use std::process::Command;
use which::which;

/// Nerd Fonts release the font comes from. Pinned, along with its checksum below, so
/// setup installs exactly the bytes that were reviewed rather than whatever a moving
/// "latest" link serves. The font is OFL licensed.
const FONT_URL: &str =
    "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.tar.xz";
/// SHA-256 of `JetBrainsMono.tar.xz` at v3.4.0, from the release's SHA-256.txt.
const FONT_SHA256: &str = "ef552a3e638f25125c6ad4c51176a6adcdce295ab1d2ffacf0db060caf8c1582";
/// Only the monospaced variants are extracted. The archive also holds proportional
/// and "Propo" families that renderers must not pick for a terminal grid.
const FONT_GLOB: &str = "JetBrainsMonoNerdFontMono-*.ttf";

/// `$XDG_DATA_HOME/fonts/tt-demo`, defaulting to `~/.local/share/fonts/tt-demo`.
fn font_dir() -> anyhow::Result<PathBuf> {
    let base = match std::env::var_os("XDG_DATA_HOME").filter(|s| !s.is_empty()) {
        Some(d) => PathBuf::from(d),
        None => PathBuf::from(std::env::var_os("HOME").context("HOME is not set")?).join(".local/share"),
    };
    Ok(base.join("fonts/tt-demo"))
}

/// The install command for `pkg` using whichever package manager is present.
fn install_hint(pkg_by_manager: &[(&str, &str)]) -> Option<String> {
    pkg_by_manager.iter().find(|(m, _)| which(m).is_ok()).map(|(m, pkg)| match *m {
        "apt-get" => format!("sudo apt-get install -y {pkg}"),
        "dnf" => format!("sudo dnf install -y {pkg}"),
        "pacman" => format!("sudo pacman -S --needed {pkg}"),
        "brew" => format!("brew install {pkg}"),
        other => format!("{other} install {pkg}"),
    })
}

fn sha256_of(path: &Path) -> anyhow::Result<String> {
    let out = Command::new("sha256sum").arg(path).output().context("running sha256sum")?;
    if !out.status.success() {
        bail!("sha256sum failed on {}", path.display());
    }
    Ok(String::from_utf8_lossy(&out.stdout).split_whitespace().next().unwrap_or("").to_string())
}

/// Download the pinned archive, verify it, and unpack the mono TTFs into `dir`.
fn install_font(dir: &Path) -> anyhow::Result<()> {
    for tool in ["tar", "xz", "sha256sum"] {
        if which(tool).is_err() {
            bail!("`{tool}` is needed to unpack the font; install it and re-run");
        }
    }
    let tmp = std::env::temp_dir().join(format!("tt-demo-font-{}.tar.xz", std::process::id()));
    println!("  downloading {FONT_URL}");
    let resp = ureq::get(FONT_URL).call().context("downloading the font")?;
    let mut file = std::fs::File::create(&tmp)?;
    std::io::copy(&mut resp.into_reader(), &mut file)?;
    drop(file);

    let got = sha256_of(&tmp)?;
    if got != FONT_SHA256 {
        std::fs::remove_file(&tmp).ok();
        bail!("checksum mismatch for the font archive\n  expected {FONT_SHA256}\n  got      {got}\nnothing was installed");
    }

    std::fs::create_dir_all(dir)?;
    let status = Command::new("tar")
        .arg("-xJf").arg(&tmp)
        .arg("-C").arg(dir)
        .arg("--wildcards").arg(FONT_GLOB)
        .status()
        .context("running tar")?;
    std::fs::remove_file(&tmp).ok();
    if !status.success() {
        bail!("tar could not unpack the font archive");
    }
    // Refresh fontconfig's cache for just this directory so agg, VHS and alacritty see it now.
    if which("fc-cache").is_ok() {
        Command::new("fc-cache").arg("-f").arg(dir).status().ok();
    }
    println!("  installed into {}", dir.display());
    Ok(())
}

pub fn run(dry_run: bool, no_fonts: bool) -> anyhow::Result<()> {
    let home = home();
    println!("tt-demo setup — fonts, terminal, tmux truecolor{}", if dry_run { " (dry run)" } else { "" });

    // --- font ---------------------------------------------------------------
    println!("\nfont");
    if look::font_is_good(&home) {
        println!("  [ok ] {}", look::font(&home, None));
    } else if no_fonts {
        println!("  [-- ] only a stock font is installed; skipped (--no-fonts)");
    } else if dry_run {
        println!("  [-- ] would install JetBrainsMono Nerd Font into {}", font_dir()?.display());
    } else {
        println!("  [-- ] only a stock font is installed; installing JetBrainsMono Nerd Font");
        install_font(&font_dir()?)?;
        println!("  [{}] now using {}", if look::font_is_good(&home) { "ok " } else { "-- " }, look::font(&home, None));
    }

    // --- terminal -----------------------------------------------------------
    println!("\nMP4 terminal");
    let term = look::terminal(&home);
    if term == "alacritty" {
        println!("  [ok ] alacritty");
    } else {
        println!("  [-- ] alacritty not installed; MP4 renders fall back to xterm");
        match install_hint(&[("apt-get", "alacritty"), ("dnf", "alacritty"), ("pacman", "alacritty"), ("brew", "--cask alacritty")]) {
            Some(cmd) => println!("         install it with: {cmd}"),
            None => println!("         install alacritty with your package manager"),
        }
    }

    // --- tmux ---------------------------------------------------------------
    println!("\ntmux truecolor");
    println!("  [ok ] lib/tmux-record.conf turns RGB on for every recording (nothing to install)");
    if !look::has_tmux_terminfo() {
        println!("  [-- ] terminfo entry tmux-256color is missing");
        if let Some(cmd) = install_hint(&[("apt-get", "ncurses-term"), ("dnf", "ncurses-term"), ("pacman", "ncurses")]) {
            println!("         install it with: {cmd}");
        }
    }
    match look::tmux_version() {
        Some(v) if v >= (3, 2) => println!("  [ok ] tmux {}.{}", v.0, v.1),
        Some(v) => println!("  [-- ] tmux {}.{} is older than 3.2; upgrade for reliable truecolor", v.0, v.1),
        None => println!("  [-- ] tmux not found"),
    }

    println!("\nre-run `tt-demo doctor` to confirm; override the font any time with TT_DEMO_FONT or `defaults.render.font_family`.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn font_dir_honours_xdg_data_home() {
        // Env is process-wide, so set and restore around the assertion.
        let old = std::env::var_os("XDG_DATA_HOME");
        std::env::set_var("XDG_DATA_HOME", "/tmp/xdg-test");
        assert_eq!(font_dir().unwrap(), PathBuf::from("/tmp/xdg-test/fonts/tt-demo"));
        match old {
            Some(v) => std::env::set_var("XDG_DATA_HOME", v),
            None => std::env::remove_var("XDG_DATA_HOME"),
        }
    }

    #[test]
    fn pinned_checksum_is_a_sha256() {
        assert_eq!(FONT_SHA256.len(), 64);
        assert!(FONT_SHA256.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn install_hint_is_none_when_no_manager_matches() {
        assert_eq!(install_hint(&[("tt_demo_no_such_manager", "x")]), None);
    }
}
