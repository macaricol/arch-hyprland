#!/usr/bin/env bash
# Phase 3 — first login, as the new user. Drivers, desktop, apps, services.

SUDOERS_DROPIN=/etc/sudoers.d/99-arch-setup-temp

phase_post() {
  require_user
  require_network

  # One password prompt up front; a background loop then keeps the ticket
  # alive so no later step stalls on a second prompt under a spinner.
  info "Requesting sudo access..."
  sudo -v
  ( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 60; done ) &>/dev/null &
  local keepalive_pid=$!
  # -n in the trap: if the ticket is somehow gone, fail quietly rather than
  # hang on a password prompt nobody can answer.
  trap 'kill '"$keepalive_pid"' 2>/dev/null; sudo -n rm -f "$SUDOERS_DROPIN" 2>/dev/null' EXIT
  STEP_TOTAL=12

  clear
  step "Enabling multilib & updating the system"
  # Must precede the GPU step, which installs 32-bit drivers from multilib.
  sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
  run sudo pacman -Syu --noconfirm
  step_done

  step "Installing GPU drivers";           install_gpu_drivers;          step_done
  step "Installing desktop packages";      pkg_install "${DESKTOP_PACKAGES[@]}"; step_done
  step "Installing extra applications";    pkg_install "${EXTRA_PACKAGES[@]}";   step_done
  step "Setting mpv wheel controls";       configure_mpv;                step_done
  step "Configuring surround audio";       configure_audio;              step_done
  step "Setting up the login screen";      configure_login_screen;       step_done
  step "Setting up Samba file sharing";    configure_samba;              step_done
  step "Installing Steam & AUR packages";  install_gaming_and_aur;       step_done
  step "Installing Hyprland + Caelestia";  install_caelestia;            step_done
  step "Keyboard, apps & wallpaper";       configure_caelestia;          step_done

  step "Enabling services"
  enable_service --now bluetooth
  # No --now for SDDM: its unit conflicts with getty@tty1, so starting it here
  # would SIGHUP this very session before the prompt below. The reboot does it.
  enable_service sddm
  step_done

  remove_staged_installer
  box "DONE! Reboot to see your new setup"
  if confirm "Reboot now?"; then
    info "Rebooting..."
    sleep 2
    sudo reboot
  else
    info "Reboot manually when ready to apply everything."
  fi
}

# The staged ~/.arch-setup copy is only needed until this phase succeeds; on
# failure it stays, so `bash ~/.arch-setup/setup.sh post` can be re-run.
# A local checkout is never deleted.
remove_staged_installer() {
  [[ $SETUP_DIR == "$HOME/.arch-setup" ]] || return 0
  mv -f "$LOG_FILE" "$HOME/arch-setup.log" 2>/dev/null || true
  LOG_FILE=$HOME/arch-setup.log
  rm -rf "$SETUP_DIR"
}

# Sets GPU_SUPPORTED for the Steam decision later.
install_gpu_drivers() {
  local -a vendors
  mapfile -t vendors < <(gpu_vendors)
  if (( ${#vendors[@]} == 0 )); then
    warn "No Intel/AMD/NVIDIA GPU detected — installing generic mesa only"
    pkg_install "${GPU_PACKAGES_FALLBACK[@]}"
    GPU_SUPPORTED=0
    return
  fi
  GPU_SUPPORTED=1
  info "Detected GPU(s): ${vendors[*]}"
  local vendor list
  for vendor in "${vendors[@]}"; do
    list="GPU_PACKAGES_${vendor^^}[@]"
    pkg_install "${!list}"
  done
}

configure_mpv() {
  sudo mkdir -p /etc/mpv
  sudo tee /etc/mpv/input.conf > /dev/null <<'EOF'
WHEEL_UP      seek 10
WHEEL_DOWN    seek -10
WHEEL_LEFT    add volume -2
WHEEL_RIGHT   add volume 2
EOF
}

# PipeWire ships upmixing off: a stereo stream on a surround card feeds front
# L/R and leaves every other speaker silent. The same drop-in has to go in two
# places, because the channel mixing happens in whichever client library the
# app uses — client.conf.d covers native PipeWire apps (mpv, Firefox/Zen's
# native backend), pipewire-pulse.conf.d covers everything speaking PulseAudio.
# Miss either one and half your applications quietly stay stereo.
configure_audio() {
  if (( ! UPMIX_SURROUND )); then
    info "Surround upmixing disabled in config — leaving PipeWire defaults"
    return
  fi

  local dir
  for dir in client pipewire-pulse; do
    sudo mkdir -p "/etc/pipewire/$dir.conf.d"
    sudo tee "/etc/pipewire/$dir.conf.d/20-upmix.conf" > /dev/null <<EOF
# Managed by arch-setup. Upmix stereo onto all surround speakers.
stream.properties = {
    channelmix.upmix        = true
    channelmix.upmix-method = $UPMIX_METHOD
    channelmix.lfe-cutoff   = $UPMIX_LFE_CUTOFF
    channelmix.fc-cutoff    = $UPMIX_FC_CUTOFF
    channelmix.rear-delay   = $UPMIX_REAR_DELAY
}
EOF
  done

  # Deliberately nothing here for mpv: it already hands PipeWire a stereo
  # stream and lets the upmix do the work. Forcing audio-channels=7.1 would
  # make mpv pad the extra channels with silence itself, and PipeWire would
  # then see 8ch and skip upmixing entirely — front L/R only again.
}

configure_login_screen() {
  local theme_dir=/usr/share/sddm/themes/$SDDM_THEME
  sudo rm -rf "$theme_dir"
  run sudo git clone --depth 1 "$SDDM_THEME_REPO" "$theme_dir"
  sudo cp -r "$theme_dir"/Fonts/* /usr/share/fonts/
  run sudo fc-cache -f

  # Hyprland's package ships the wayland-sessions entry SDDM lists; nothing
  # else to register.
  sudo mkdir -p /etc/sddm.conf.d
  sudo tee /etc/sddm.conf.d/10-arch-setup.conf > /dev/null <<EOF
[Theme]
Current=$SDDM_THEME

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot

[Users]
MinimumUid=1000
MaximumUid=60513
EOF
}

configure_samba() {
  sudo mkdir -p /var/lib/samba/usershares
  sudo groupadd -r sambashare 2>/dev/null || true
  sudo chown root:sambashare /var/lib/samba/usershares
  sudo chmod 1770 /var/lib/samba/usershares
  sudo usermod -aG sambashare "$USER"

  sudo tee /etc/samba/smb.conf > /dev/null <<EOF
[global]
   workgroup = $SAMBA_WORKGROUP
   server string = Samba Server %v
   netbios name = %h
   security = user
   map to guest = Bad User
   dns proxy = no

   usershare path = /var/lib/samba/usershares
   usershare max shares = 100
   usershare allow guests = yes
   usershare owner only = yes
EOF
  enable_service --now smb nmb
}

install_gaming_and_aur() {
  info "Hang tight — this step compiles paru and builds the AUR packages."
  pkg_install base-devel
  if (( GPU_SUPPORTED )); then
    pkg_install "${GAMING_PACKAGES[@]}"
  else
    # Without a real GPU driver, steam's 32-bit Vulkan dependency can only be
    # met by software Vulkan (breaks the login screen's video) or by pacman
    # picking lib32-nvidia-utils. Neither is worth it on a VM.
    warn "No supported GPU — skipping Steam"
  fi

  # makepkg's internal `sudo pacman` calls don't pick up the cached ticket no
  # matter how it's shared. Rather than fight that: passwordless sudo for
  # pacman only, for the AUR steps only — created here, removed at the end
  # of install_caelestia.
  echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" | sudo tee "$SUDOERS_DROPIN" > /dev/null
  sudo chmod 440 "$SUDOERS_DROPIN"
  sudo visudo -c -f "$SUDOERS_DROPIN" > /dev/null || die "Generated sudoers drop-in is invalid"

  if command -v paru &>/dev/null; then
    info "paru already installed — skipping build"
  else
    # Built from source on purpose: paru-bin is compiled against a fixed
    # libalpm and breaks whenever pacman bumps its ABI (it has been flagged
    # out-of-date for months). -r removes the Rust toolchain again afterwards.
    local build; build=$(mktemp -d)
    git_clone https://aur.archlinux.org/paru.git "$build"
    (cd "$build" && run makepkg -sri --noconfirm)
    rm -rf "$build"
  fi
  aur_install "${AUR_PACKAGES[@]}"
  # The drop-in stays for install_caelestia, which builds AUR packages too;
  # it removes it.
}

# `caelestia install` pulls in Hyprland, Quickshell, the shell and the rest
# of the dots (packages via paru, configs into ~/.config). Its post-install
# hooks expect a running Hyprland and just warn from a tty; the session's own
# exec-once lines start the shell on first login anyway.
install_caelestia() {
  # Folder icon colours follow the scheme through `sudo -n papirus-folders`,
  # which silently does nothing unless it's allowed without a password.
  echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/papirus-folders" \
    | sudo tee /etc/sudoers.d/50-papirus-folders > /dev/null
  sudo chmod 440 /etc/sudoers.d/50-papirus-folders
  sudo visudo -c -f /etc/sudoers.d/50-papirus-folders > /dev/null || die "Generated sudoers drop-in is invalid"

  aur_install caelestia-cli
  run caelestia install --noconfirm --aur-helper paru \
    --enable-components "$CAELESTIA_ENABLE" --disable-components "$CAELESTIA_DISABLE"

  sudo rm -f "$SUDOERS_DROPIN"
}

# Personal settings go in the two files the dots promise never to touch;
# everything in ~/.config/hypr is overwritten by `caelestia update`.
configure_caelestia() {
  local dir=$HOME/.config/caelestia
  mkdir -p "$dir"

  { echo '-- Written by arch-setup. Overrides hypr/variables.lua in the dots.'
    echo 'return {'
    local var; for var in "${HYPR_VARS[@]}"; do echo "  $var,"; done
    echo '}'
  } > "$dir/hypr-vars.lua"

  cat > "$dir/hypr-user.lua" <<EOF
-- Written by arch-setup. Your own Hyprland config: monitors, binds, rules...
hl.config({ input = { kb_layout = "$KB_LAYOUT" } })
EOF
  # No real GPU means a VM. VirtualBox's 3D driver is enough for Hyprland,
  # but Quickshell can't create EGL surfaces on it and the shell dies right
  # after loading (EGL error 0x3000). Software GL (llvmpipe) for everything
  # Hyprland launches fixes that; Hyprland itself still renders on the VM GPU.
  if (( ! GPU_SUPPORTED )); then
    cat >> "$dir/hypr-user.lua" <<'EOF'

-- No GPU detected at install (VM): software GL, or the shell can't draw.
hl.env("LIBGL_ALWAYS_SOFTWARE", "1")
EOF
  fi

  # "dynamic" makes the colour scheme follow the wallpaper. Neither command
  # needs the shell running: they write state the shell reads on start. The
  # wallpaper goes first: the dynamic scheme is computed from its thumbnail.
  run caelestia wallpaper -f "$WALLPAPER" || warn "Couldn't set the wallpaper ($WALLPAPER)"
  run caelestia scheme set -n dynamic || warn "Couldn't set the dynamic colour scheme"
}
