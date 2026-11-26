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

- `[x]` Gom danh sách gói Arch `[core]`/`[extra]` (24 gói `minimal`, +21 gói `full` = 45 gói, **0 AUR**) về một nguồn sự thật duy nhất tại [scripts/packages.sh](scripts/packages.sh) dùng chung cho [scripts/install.sh](scripts/install.sh) và [scripts/install-packages.sh](scripts/install-packages.sh).
- `[x]` Trình cài đặt TUI tương tác kiểu Omarchy (`--tui` / `--no-tui`) trong [scripts/install.sh](scripts/install.sh), thay `zathura-pdf-mupdf` bằng `zathura-pdf-poppler` (tránh kéo Tesseract/OCR), tự re-exec sang `bash` khi gọi bằng `sh` và hạ quyền `sudo` về `SUDO_USER`.
- `[x]` Backup/reapply/rollback nguyên vẹn trong [scripts/apply.sh](scripts/apply.sh): giữ nguyên chỉnh sửa Noctalia Settings GUI và `hypr/user.lua`, hỗ trợ đường dẫn XDG có khoảng trắng.
- `[x]` [bin/kaze-doctor](bin/kaze-doctor) kiểm tra binary theo profile, symlink, `noctalia config validate`, `foot --check-config`, `zsh -n`, `hyprctl configerrors`, env systemd, portal thụ động, audio, singleton PID, và phát hiện lệch cấu hình Noctalia (`kaze-doctor --diff`) qua [lua/kaze/toml_diff.lua](lua/kaze/toml_diff.lua).
- `[x]` GitHub Actions CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) tự chạy `luac -p`, `lua tests/run.lua`, `unittest tests/vm-idle-test.py`, `bash -n`, `shellcheck`, và dry-run installer trên mọi lần push/PR.

---

## 4. Hạng mục mở & Kế hoạch tiếp theo

- `[~]` **Kiểm chứng phần cứng vật lý thật:** cảm biến gập nắp laptop (`Lid Switch`), tấm nền backlight `/sys/class/backlight`, và cấu hình hybrid GPU (`drm_devices` / `prefer_mesa_egl`) trên máy thật (VM không giả lập cảm biến nắp gập và đèn nền phần cứng).
- `[ ]` **Config mặc định cho bộ app `full`:** tinh chỉnh thẩm mỹ phẳng Omarchy cho `yazi` (Sixel preview trên Foot), `zathura`, `imv`, và `mimeapps.list`.
- `[ ]` **Nâng cấp [bin/kaze-record](bin/kaze-record):** thêm `--menu` chọn nhanh Fullscreen/Region, tùy chọn thu âm (`--audio`), và chỉ báo đang quay trên Noctalia bar.
- `[ ]` **Clamshell Mode (Lid Switch):** nối sự kiện đóng/mở nắp laptop trực tiếp vào `kaze-display` khi đang cắm màn hình rời.
- `[-]` **Loại dứt khoát khỏi mặc định:** Waybar/swaybg/Fuzzel/Fnott/hypridle/hyprlock/cliphist/matugen/swappy (được thay bằng Noctalia v5.x native; lưu lịch sử ở nhánh `legacy-waybar`), `kaze-cast` (GStreamer/C binary), `zathura-pdf-mupdf` (Tesseract/OCR), mọi runtime Qt/QML/Electron/GTK4/Node/Python cho shell nền, và mọi script polling.
