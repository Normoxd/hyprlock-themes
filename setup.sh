#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/Normoxd/hyprlock-themes"
HYPR_DIR="$HOME/.config/hypr"
THEMES_DIR="$HYPR_DIR/hyprlock-themes"
FONT_DIR="$HOME/.local/share/fonts"

install_gum_binary() {
    command -v curl >/dev/null && command -v tar >/dev/null || { echo "curl and tar are needed to download gum"; return 1; }

    local arch tag url tmp bin
    case "$(uname -m)" in
        x86_64)          arch="x86_64" ;;
        aarch64|arm64)   arch="arm64" ;;
        armv7l)          arch="armv7" ;;
        armv6l)          arch="armv6" ;;
        i386|i686)       arch="i386" ;;
        *) echo "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac

    tag=$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest \
        | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/') || return 1
    [ -n "$tag" ] || return 1

    url="https://github.com/charmbracelet/gum/releases/download/v${tag}/gum_${tag}_Linux_${arch}.tar.gz"
    tmp=$(mktemp -d)
    curl -fsSL "$url" | tar -xz -C "$tmp" || return 1
    bin=$(find "$tmp" -type f -name gum | head -n1)
    [ -n "$bin" ] || return 1

    install -Dm755 "$bin" "$HOME/.local/bin/gum"
    rm -rf "$tmp"
    export PATH="$HOME/.local/bin:$PATH"
    echo "Installed gum to ~/.local/bin (make sure it is in your PATH)"
}

ensure_gum() {
    command -v gum >/dev/null && return 0

    echo "gum is required but not installed."
    read -rp "Install it now? [Y/n] " answer
    [[ "${answer:-y}" =~ ^[Yy]$ ]] || exit 1

    local SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"

    if   command -v pacman       >/dev/null; then $SUDO pacman -S --needed --noconfirm gum || true
    elif command -v apk          >/dev/null; then $SUDO apk add gum || true
    elif command -v xbps-install >/dev/null; then $SUDO xbps-install -Sy gum || true
    elif command -v brew         >/dev/null; then brew install gum || true
    elif command -v nix-env      >/dev/null; then nix-env -iA nixpkgs.gum || true
    fi

    # apt/dnf/zypper/anything else (or a failed install above): grab the release binary
    command -v gum >/dev/null || install_gum_binary || true

    command -v gum >/dev/null || { echo "Could not install gum. See https://github.com/charmbracelet/gum#installation"; exit 1; }
}

ensure_gum
command -v git >/dev/null || { echo "git is not installed"; exit 1; }

ok()   { gum style --foreground 2 "$*"; }
warn() { gum style --foreground 3 "$*"; }
err()  { gum style --foreground 1 "$*"; }

install_fonts() {
    local src
    src=$(find "$THEMES_DIR" -maxdepth 2 -type d -name fonts | head -n1)
    if [ -n "$src" ]; then
        mkdir -p "$FONT_DIR"
        cp -r "$src"/. "$FONT_DIR"/
        fc-cache -f >/dev/null 2>&1 || true
        ok "Fonts installed"
    else
        warn "No fonts folder found, skipping fonts"
    fi
}

do_install() {
    mkdir -p "$HYPR_DIR"

    if [ -d "$THEMES_DIR/.git" ]; then
        warn "Already installed, use Update instead"
        return
    elif [ -d "$THEMES_DIR" ]; then
        warn "Themes folder exists without git, using it as is"
    else
        gum spin --title "Cloning themes..." -- git clone "$REPO" "$THEMES_DIR"
    fi

    install_fonts

    # Back up the current config once, never overwrite an existing backup
    if [ -f "$HYPR_DIR/hyprlock.conf" ] && [ ! -f "$HYPR_DIR/hyprlock.conf.backup" ]; then
        mv "$HYPR_DIR/hyprlock.conf" "$HYPR_DIR/hyprlock.conf.backup"
        ok "Backed up hyprlock.conf"
    fi

    ok "Install done"
    if gum confirm "Set your profile picture now?"; then
        do_avatar
    fi
    if gum confirm "Set your background now?"; then
        do_background
    fi
    if gum confirm "Pick a theme now?"; then
        do_pick
    fi
}

do_update() {
    if [ ! -d "$THEMES_DIR" ]; then
        err "Not installed yet, run Install first"
        return
    fi
    if [ ! -d "$THEMES_DIR/.git" ]; then
        warn "Themes folder has no .git, can't update. Remove it and run Install to re-clone."
        return
    fi
    gum spin --title "Updating themes..." -- git -C "$THEMES_DIR" pull --ff-only
    install_fonts
    ok "Updated (re-apply your theme to get changes)"
}

do_pick() {
    if [ ! -d "$THEMES_DIR" ]; then
        err "Not installed yet, run Install first"
        return
    fi

    local themes=() labels=() f n choice src img
    declare -A files

    local tdir="$THEMES_DIR/themes"
    [ -d "$tdir" ] || tdir="$THEMES_DIR"
    mapfile -t themes < <(find "$tdir" -maxdepth 1 -name '*.conf' 2>/dev/null | sort -V)
    if [ ${#themes[@]} -eq 0 ]; then
        err "No themes found"
        return
    fi

    for f in "${themes[@]}"; do
        n=$(basename "$f" .conf)
        n=${n#hyprlock-}
        files["$n"]=$f
        labels+=("$n")
    done
    [ -f "$HYPR_DIR/hyprlock.conf.backup" ] && labels+=("Restore backup")

    choice=$(gum choose --header "Pick a hyprlock theme" "${labels[@]}") || return 0

    if [ "$choice" = "Restore backup" ]; then
        src="$HYPR_DIR/hyprlock.conf.backup"
    else
        src=${files[$choice]}
        img=$(find "$THEMES_DIR" -maxdepth 2 -name "$choice.png" 2>/dev/null | head -n1)
        if command -v chafa >/dev/null && [ -n "$img" ]; then
            chafa -s 60x "$img"
        fi
    fi

    while true; do
        action=$(gum choose --header "$choice" "Preview" "Apply" "Back") || return 0
        case "$action" in
            "Preview")
                if ! command -v hyprlock >/dev/null; then
                    err "hyprlock is not installed"
                    continue
                fi
                warn "Locking the screen with this theme. Unlock with your password to come back."
                sleep 1
                # -c loads the theme directly, so your real config is never touched
                hyprlock -c "$src" || true
                ;;
            "Apply")
                cp "$src" "$HYPR_DIR/hyprlock.conf"
                ok "Applied: $choice"
                return 0
                ;;
            "Back")
                return 0
                ;;
        esac
    done
}

pick_image() {
    local target="$1" label="$2" start="$HOME/Pictures" img

    [ -d "$start" ] || start="$HOME"
    mkdir -p "$HYPR_DIR"

    if [ -f "$target" ]; then
        gum confirm "A $label already exists. Replace it?" || return 0
    fi

    gum style "Pick an image for your $label (arrows to move, enter to select)"
    img=$(gum file --height 15 "$start") || return 0
    [ -f "$img" ] || { err "Not a file"; return; }

    # hyprlock reads any image format as long as the file has the right name
    cp "$img" "$target"
    ok "$label set"
}

do_avatar()     { pick_image "$HYPR_DIR/user.png" "profile picture"; }
do_background() { pick_image "$HYPR_DIR/background.png" "background"; }

while true; do
    action=$(gum choose --header "hyprlock themes" "Install" "Update" "Select a theme" "Set profile picture" "Set background" "Quit") || exit 0
    case "$action" in
        "Install")         do_install ;;
        "Update")          do_update ;;
        "Select a theme")  do_pick ;;
        "Set profile picture") do_avatar ;;
        "Set background")  do_background ;;
        "Quit")            exit 0 ;;
    esac
    echo
done
