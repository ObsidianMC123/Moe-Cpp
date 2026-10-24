# Moe C++ — Fork of Dev-C++

**Moe C++** is an unofficial community fork of [Embarcadero Dev-C++](https://github.com/Embarcadero/Dev-Cpp), focused on a customizable dark interface and native image/video wallpaper support.

> The underlying editor, compiler integration, and much of the source code are from Dev-C++. This project is not affiliated with or endorsed by Embarcadero. Some in-app names and graphics still use the original Dev-C++ branding.

## What's different?

- Native editor image wallpapers and looping MP4 wallpapers (FFmpeg).
- Optional **Wallpaper across workspace** for the code editor and surrounding panels, including Project/Class and output areas.
- Distinctive green **Moe C++** Windows icon, Welcome logo, app title, and version metadata (v0.2.0).
- Dark UI improvements, video orientation corrections, and reduced repaint flicker when editing, switching tabs, and opening projects.
- Wallpaper settings for opacity, dimming, blur and frame rate, accessible from **Tools → Wallpaper Settings**.
- C/C++ editing, projects, compilation and debugging inherited from Dev-C++.

## Download and run

Go to [Releases](../../releases) and download the **v0.2.0 portable** ZIP. Extract it fully, then run `Start Moe C++.cmd`. The ZIP includes the TDM-GCC toolchain. On first launch, configure your own image or video from **Tools → Wallpaper Settings**.

For MP4 playback, install FFmpeg and make sure `ffmpeg.exe` is available on `PATH`. No personal wallpaper video is bundled.

**Platform:** Windows. The current custom build was tested with Delphi 13 Community Edition as a Win32 application. C/C++ compilation was tested with TDM-GCC 9.2.

## Build from source

1. Install Delphi / RAD Studio 13 with VCL and the Windows 32-bit compiler.
2. Open `Source/devcpp.dproj`.
3. Build for **Win32 / Debug**. The project writes to `custom-bin` and runs `build-resources.ps1` to copy the included UI resources.
4. To run the IDE with C/C++ compilation, place the TDM-GCC toolchain (or another supported GCC toolchain) alongside the built IDE and configure the compiler in Dev-C++.
5. Use a locally installed FFmpeg for MP4 playback.

The Windows 32-bit Delphi build was verified with 0 compilation errors (some warnings and hints). The portable v2 build also passed F11 Compile & Run and 12 minimize/restore test cycles. These checks do **not** establish absence of every display-driver-specific flicker or multi-monitor issue.

## Upstream and license

Originally derived from [Embarcadero/Dev-Cpp](https://github.com/Embarcadero/Dev-Cpp), which builds on Bloodshed Dev-C++ and Orwell Dev-C++. The original project details are preserved in [UPSTREAM_README.md](UPSTREAM_README.md).

The Dev-C++ code is distributed under the **GNU General Public License v2.0**; see [LICENSE](LICENSE) and [COPYING.txt](COPYING.txt). Third-party libraries, fonts and toolchain components retain their own notices and license terms. Please preserve these notices when redistributing binaries.

## Current status

Experimental community fork. Report reproducible crashes or drawing defects with your Windows version, whether **Wallpaper across workspace** is enabled, and the relevant steps to reproduce.
