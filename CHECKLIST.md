# CHECKLIST.md — Lộ trình `kaze-dots` (Noctalia Shell v5.x Native)

**Mục tiêu cốt lõi:** Desktop **Hyprland 0.57+ (Lua) + Noctalia Shell (C++ v5.x) + Foot + Zsh** gọn nhẹ, sạch sẽ theo thẩm mỹ Omarchy (góc vuông `0px`, viền `2px`, `0` bóng đổ), `0` AUR cho phần lõi, `0` telemetry/polling, và đạt ngân sách **≤ 100 MiB PSS** (`≤ 105 MiB` gồm session services), **≤ 0.20% CPU**, **≤ 8.0 CS/s**, **0 early portals** tại `1920×1080` ([GOAL.md](GOAL.md), [DESIGN.md](DESIGN.md)).

`[x]` đã triển khai & kiểm chứng · `[~]` đã triển khai, còn hạng mục phần cứng/mở rộng · `[ ]` kế hoạch tiếp theo · `[-]` loại dứt khoát khỏi thiết kế mặc định.

---

## 1. Kiến trúc lõi (Noctalia Shell v5.x + Hyprland Lua 0.57+)

| Trạng thái | Hạng mục | Bằng chứng |
|:-:|---|---|
| `[x]` | Hyprland 0.57+ thuần Lua (`hypr/*.lua`) với override cá nhân bảo toàn qua `~/.config/hypr/user.lua` | [hypr/](hypr/), [lua/kaze/hypr_user.lua](lua/kaze/hypr_user.lua), [templates/hypr-user.lua.example](templates/hypr-user.lua.example) |
| `[x]` | Noctalia Shell v5.x bản địa (bar dọc `42px`, `corner_radius_scale = 0.0`, `offline_mode = true`, `telemetry_enabled = false`, tắt weather/calendar/sysmon/dock/desktop_widgets) + built-in app templates (`hyprland`, `foot`, `gtk3`, `gtk4`, `btop`) | [config/noctalia/config.toml](config/noctalia/config.toml), [DESIGN.md](DESIGN.md) |
| `[x]` | Vòng đời phiên systemd tập trung (`kaze-session.target`, `kaze-noctalia.service` tinh chỉnh `MALLOC_CONF`, `foot-server.service/socket` drop-in, `kaze-fcitx5.service`, `kaze-record.service`) | [config/systemd/user/](config/systemd/user/), [bin/kaze-session](bin/kaze-session), [lua/kaze/session.lua](lua/kaze/session.lua) |
| `[x]` | `kaze-footclient` truyền bảng màu Noctalia live cho cửa sổ Foot mới mà không cần restart `foot --server` | [bin/kaze-footclient](bin/kaze-footclient), [config/foot/foot.ini](config/foot/foot.ini) |
| `[x]` | Zsh mặc định với cấu hình module (`~/.zprofile`, `~/.zshrc`, `conf.d/*.zsh`) + prompt Starship 1 dòng thuần ANSI (`0` mã màu hex cứng) | [config/zsh/](config/zsh/), [config/starship/starship.toml](config/starship/starship.toml) |
| `[x]` | Portal on-demand (`xdg-desktop-portal`, `-hyprland`, `-gtk`, `config/hypr/xdph.conf` 60fps + restore token), `0` early portals ở T0 | [config/hypr/xdph.conf](config/hypr/xdph.conf), [bin/kaze-doctor](bin/kaze-doctor) |

---

## 2. Màn hình rời, Trình chiếu & Chia sẻ (`kaze-display`)

- `[x]` Di chuyển toàn bộ điều khiển màn hình sang Hyprland 0.57 native Lua API (`hl.monitor`, `hl.dsp.workspace.move`, `hl.dsp.window.move`), `0` daemon nền.
- `[x]` Tự động bắt sự kiện cắm/rút màn hình rời (`hl.on("monitor.added" / "monitor.removed")`) trong [hypr/execs.lua](hypr/execs.lua) kèm lớp bảo vệ (bỏ qua màn ảo, lockscreen, cửa sổ 5 giây đầu lúc boot, debounce 1 giây, cho phép tắt qua `display_hotplug_menu = false`).
- `[x]` Menu `Super + Shift + P` / `XF86Display` (và nút `[widget.display]` trên Noctalia bar) tinh gọn 4 nhánh:
  1. **Mirror Full Screen** (`mirror` / `mirror-scaled` dùng `wl-mirror`)
  2. **Present Workspace → HDMI** (ẩn bar trên màn ngoài, bật DND có điều kiện, kèm `Ctrl + Super + P` toggle điều khiển trên laptop)
  3. **Virtual Share 1080p** (`kaze-share` tại `9999x0` cho Meet/Discord, `Super + Alt + P` đẩy/kéo cửa sổ, preview nổi `wl-mirror`, tự giải cứu cửa sổ khi tắt/logout)
  4. **Extend / Layout** (`extend-right`, `extend-left`, `extend-up`, `external`, `internal`, `auto`)
- `[x]` Hỗ trợ laptop hybrid GPU tùy chọn (`drm_devices`, `prefer_mesa_egl` trong `user.lua`) và bộ xem 2 màn hình VM độ trễ thấp ([scripts/watch-vm-monitor.sh](scripts/watch-vm-monitor.sh)).

---

## 3. Installer, Chẩn đoán, Đồng bộ & CI

- `[x]` Gom danh sách gói Arch `[core]`/`[extra]` (27 gói `minimal` gồm full PipeWire stack, +24 gói `full` = 51 gói, **0 AUR phần lõi**) về một nguồn sự thật duy nhất tại [scripts/packages.sh](scripts/packages.sh) dùng chung cho [scripts/install.sh](scripts/install.sh) và [scripts/install-packages.sh](scripts/install-packages.sh), kèm Display Manager chính thức (**`noctalia-greeter` qua `greetd`** mặc định với theme & hình nền 4K Kanagawa đóng gói sẵn, 0 Qt/GTK; tùy chọn `--dm ly`, `--dm greetd` cho `tuigreet`, hoặc `--dm none` cho TTY1) và AUR helper mặc định **`yay-bin`** cài sau phần lõi (tùy chọn `--aur paru-bin` hoặc `--aur none`).
- `[x]` Luồng cài đặt 1 chạm bare-Arch đầy đủ Stage 0–6 ([scripts/bootstrap.sh](scripts/bootstrap.sh), [scripts/install-lib.sh](scripts/install-lib.sh), [scripts/install.sh](scripts/install.sh)): `pacman -Syu --needed`, dò GPU/hybrid laptop để tự điền `drm_devices` + `prefer_mesa_egl` khi tạo `user.lua` mới, phát hiện xung đột cứng/mềm, System Setup (NetworkManager có kiểm tra không ghi đè stack cũ, Bluetooth, PipeWire user units, nhóm `video`, `fc-cache`), ghi log sạch ANSI (`~/.local/state/kaze/install-*.log`), giữ phiên `sudo -v`, hậu kiểm `kaze-doctor --offline`, TUI tương tác kiểu Omarchy, tự re-exec sang `bash` khi gọi bằng `sh` và hạ quyền `sudo` về `SUDO_USER`.
- `[x]` Backup/reapply/rollback nguyên vẹn trong [scripts/apply.sh](scripts/apply.sh): giữ nguyên chỉnh sửa Noctalia Settings GUI và `hypr/user.lua`, hỗ trợ đường dẫn XDG có khoảng trắng (kể cả `XDG_CONFIG_HOME` tùy chỉnh cho `foot/themes/noctalia`).
- `[x]` [bin/kaze-doctor](bin/kaze-doctor) kiểm tra binary theo profile, symlink, `noctalia config validate`, `foot --check-config`, `zsh -n`, `hyprctl configerrors`, env systemd, portal thụ động, audio (`pipewire-pulse` + `wireplumber`), singleton PID, và phát hiện lệch cấu hình Noctalia (`kaze-doctor --diff`) qua [lua/kaze/toml_diff.lua](lua/kaze/toml_diff.lua).
- `[x]` [bin/kaze-mirror](bin/kaze-mirror) tối ưu mirror Arch/CachyOS thuần Lua + `curl -Z` (3-stage saturation benchmark, `ParallelDownloads` A/B, commit nguyên tử + rollback bảo vệ ngoài luồng, Omarchy TUI & Noctalia bar widget).
- `[x]` GitHub Actions CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) tự chạy `luac -p`, `lua tests/run.lua` (181 test gồm 8 bộ test mù black-box theo từng module trong `tests/blackbox/`), `unittest tests/vm-idle-test.py`, `bash -n`, `shellcheck`, và dry-run installer trên mọi lần push/PR.

---

## 4. Hạng mục mở & Kế hoạch tiếp theo

- `[x]` Hệ thống 11 visual preset đồng bộ Noctalia + Hyprland (`kaze-style.lua`) + GTK3 (`kaze-style.css`) qua `kaze-style` ([lua/kaze/styles.lua](lua/kaze/styles.lua), [config/noctalia/palettes/](config/noctalia/palettes/)), 8 custom palette Version 2 (`Kaze-Swiss`, `Kaze-Phosphor`, `Kaze-Amber`, `Kaze-Retro90s`, `Kaze-RosePine`, `Kaze-Everforest`, `Kaze-Monochrome`, `Kaze-Sakura` — tổng 16 theme cùng 8 theme built-in), bộ 10 hình nền 4K giấy phép MIT ([assets/wallpapers/](assets/wallpapers/), trích tuyển từ `omacom/omarchy` — liên kết vào `~/Pictures/Wallpapers/` và dùng sẵn cho `noctalia-greeter`), Live Activity trên Dynamic Island (`kaze-record`, `kaze-display`), dual-bar `floating-rail`, auto-hide dock `glass-studio`, và `Super_L` hold-to-peek trên `ghost-zero`.
- `[x]` **Config mặc định cho bộ app `full`:** thẩm mỹ phẳng Omarchy đồng bộ cho Thunar ([config/Thunar/](config/Thunar/), [config/gtk-3.0/](config/gtk-3.0/), [config/xfce4/](config/xfce4/), [bin/kaze-thunar-action](bin/kaze-thunar-action)), `yazi` (Sixel preview trên Foot), `zathura`, `imv`, và [config/mimeapps.list](config/mimeapps.list).
- `[x]` **Nâng cấp [bin/kaze-record](bin/kaze-record):** đã hỗ trợ `--menu` / `--bar` chọn nhanh Fullscreen/Region, thu âm (`--audio=desktop|mic|off`), xuất/chuyển GIF (`--gif`), và chỉ báo đang quay trên Noctalia bar (`[widget.record]`).
- `[~]` **Kiểm chứng phần cứng vật lý thật:** cảm biến gập nắp laptop (`Lid Switch`), tấm nền backlight `/sys/class/backlight`, và cấu hình hybrid GPU (`drm_devices` / `prefer_mesa_egl`) trên máy thật (VM không giả lập cảm biến nắp gập và đèn nền phần cứng).
- `[ ]` **Clamshell Mode (Lid Switch):** nối sự kiện đóng/mở nắp laptop trực tiếp vào `kaze-display` khi đang cắm màn hình rời.
- `[-]` **Loại dứt khoát khỏi mặc định:** Waybar/swaybg/Fuzzel/Fnott/hypridle/hyprlock/cliphist/matugen/swappy (được thay bằng Noctalia v5.x native; lưu lịch sử ở nhánh `legacy-waybar`), `kaze-cast` (GStreamer/C binary), `zathura-pdf-mupdf` (Tesseract/OCR), mọi runtime Qt/QML/Electron/GTK4/Node/Python cho shell nền, và mọi script polling.
