# USB Restreamer

Portable 64-bit Windows bundle that publishes a USB webcam as an unauthenticated
RTSP stream using FFmpeg and MediaMTX. It runs from an extracted folder and does
not install software or require administrator privileges.

## Run

1. Download `usb-restreamer-windows-x64.zip` from a GitHub Release and extract it.
2. Find the webcam's DirectShow name:

   ```powershell
   .\ffmpeg.exe -list_devices true -f dshow -i dummy
   ```

   FFmpeg prints the device list to the console even though the command reports
   an input error. Copy the exact video device name into `camera_device` in
   `config.json`.
3. If needed, edit `width`, `height`, `framerate`, `pixel_format`, `rtsp_port`,
   and `stream_path` in `config.json`. The defaults request 1920x1080 at 30 fps.
   Leave `pixel_format` empty to let DirectShow choose a supported format.
4. Double-click `start.cmd`. The script starts MediaMTX and FFmpeg together;
   closing the console or pressing Ctrl+C stops both. Logs are written next to
   the scripts.

The local stream is `rtsp://127.0.0.1:8554/webcam` with the default settings.
The launcher prints LAN RTSP URLs for detected IPv4 addresses.

## LAN access and firewall

The RTSP server listens on all IPv4 interfaces and permits anonymous publishing
and reading, using RTSP-over-TCP. Anyone who can reach the PC on the LAN can
view the stream. When the launcher detects an enabled Windows Firewall profile,
it warns that the firewall may block inbound TCP traffic on the configured RTSP
port. It never changes firewall rules. If other devices cannot connect, ask the
PC administrator to allow inbound TCP on that port. Configure RTSP-over-TCP in
the client as well.

## GitHub Actions

Actions builds the Windows x64 ZIP on pushes to `main` and pull requests. Pushing
a `v*` tag also creates a GitHub Release with GitHub-generated release notes and
attaches the ZIP. Each build downloads the latest FFmpeg-Builds and MediaMTX
Windows releases; the bundle includes upstream license files when supplied in
their archives and a file linking to the upstream build/release.